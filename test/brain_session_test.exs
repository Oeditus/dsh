defmodule DeepSeekHarness.BrainSessionTest do
  use ExUnit.Case, async: false

  alias DeepSeekHarness.Brain.Session
  alias DeepSeekHarness.Brain.SessionSupervisor
  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader

  setup do
    session_id = "test_session_#{System.unique_integer([:positive])}"
    {:ok, pid} = SessionSupervisor.start_session(session_id: session_id, model: "deepseek-chat")
    %{session_id: session_id, pid: pid}
  end

  test "session actor initializes with default state", %{pid: pid, session_id: session_id} do
    info = Session.get_info(pid)
    assert info.session_id == session_id
    assert info.model == "deepseek-chat"
    assert info.hands_mode == :local
    assert info.tools_count > 0
  end

  test "model selection switching", %{pid: pid} do
    assert {:ok, "deepseek-reasoner"} = Session.set_model(pid, "deepseek-reasoner")
    info = Session.get_info(pid)
    assert info.model == "deepseek-reasoner"
  end

  test "temporal state checkpoints and undo", %{pid: pid} do
    # Create manual checkpoint
    {:ok, cp1} = Session.checkpoint(pid, "Checkpoint 1")
    assert cp1.label == "Checkpoint 1"

    # Send a message to mutate history
    {:ok, _response} = Session.send_user_message(pid, "Hello world")
    info_after = Session.get_info(pid)
    assert info_after.message_count > 1

    # Rollback via undo
    assert {:ok, msg} = Session.undo(pid)
    assert msg =~ "Pre-turn #1"
  end

  test "hot code reloading updates tools live without dropping state", %{pid: pid} do
    initial_info = Session.get_info(pid)

    # Trigger hot-code reload broadcast
    {:ok, _tools} = PluginLoader.reload_all()

    # Verify session received broadcast and preserved its state/pid
    info_after = Session.get_info(pid)
    assert info_after.pid == initial_info.pid
    assert info_after.session_id == initial_info.session_id
  end

  test "configures hands execution mode", %{pid: pid} do
    assert {:ok, %{mode: :remote}} = Session.set_hands_mode(pid, :remote, "hands@127.0.0.1")
    info = Session.get_info(pid)
    assert info.hands_mode == :remote
    assert info.hands_target == "hands@127.0.0.1"
  end

  test "spawns subagent actor and calculates token stats", %{pid: pid} do
    stats = Session.get_token_stats(pid)
    assert is_integer(stats.total_tokens)

    assert {:ok, result} = Session.spawn_subagent(pid, "Research quantum computing")
    assert is_binary(result)
  end

  test "compresses context via session actor", %{pid: pid} do
    assert {:ok, summary} = Session.compact_context(pid)
    assert is_binary(summary)
  end

  test "retrieves latest assistant response", %{pid: pid} do
    assert match?({:ok, _}, Session.send_user_message(pid, "Hello agent"))
    assert {:ok, response} = Session.get_latest_response(pid)
    assert is_binary(response)
  end

  test "image attachment builds structured content array for vision model" do
    # Minimal valid 1x1 transparent PNG (base64-encoded)
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      )

    img_path = Path.join(System.tmp_dir!(), "sess_img_#{System.unique_integer([:positive])}.png")
    File.write!(img_path, png)

    # Run the vision model in offline/mock mode (no API key) so the test is
    # deterministic and never hits the network. The multimodal `content` array
    # flows through ContextExpander -> Session -> DeepSeekAPI, which extracts
    # the text part for the mock reply.
    sess_id = "vision_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SessionSupervisor.start_session(
        session_id: sess_id,
        model: "deepseek-v4-flash-vision-exp",
        api_key: ""
      )

    assert {:ok, %{content: resp}} = Session.send_user_message(pid, "Describe @#{img_path}")
    assert is_binary(resp)

    File.rm(img_path)
  end

  test "toggles sandbox bounds, retrieves stats dashboard, turn tokens, and exports session", %{
    pid: pid
  } do
    assert {:ok, true} = Session.set_sandbox_mode(pid, true)
    stats = Session.get_stats(pid)
    assert stats.sandbox_workspace == true
    assert is_map(stats)

    turns = Session.get_turn_tokens(pid)
    assert is_list(turns)

    assert {:ok, md_path} = Session.export_session(pid, :markdown)
    assert File.exists?(md_path)
    assert String.ends_with?(md_path, ".md")

    assert {:ok, json_path} = Session.export_session(pid, :json)
    assert File.exists?(json_path)
    assert String.ends_with?(json_path, ".json")

    File.rm(md_path)
    File.rm(json_path)
  end

  test "sanitizes message sequence to enforce tool_calls followed by tool responses" do
    invalid_messages = [
      %{"role" => "user", "content" => "Run tools"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [%{"id" => "call_123", "function" => %{"name" => "bash"}}]
      },
      %{"role" => "user", "content" => "SYSTEM NOTICE: Duplicate tool call"}
    ]

    sanitized = Session.sanitize_messages(invalid_messages)
    assert length(sanitized) == 4

    [user1, assistant, tool, user2] = sanitized
    assert user1["role"] == "user"
    assert assistant["role"] == "assistant"
    assert tool["role"] == "tool"
    assert tool["tool_call_id"] == "call_123"
    assert user2["role"] == "user"
  end

  test "defaults max_tool_depth to 100 and honors an explicit override", %{pid: pid} do
    stats = Session.get_stats(pid)
    assert stats.max_tool_depth == 100

    sess_id = "depth_override_test_#{System.unique_integer([:positive])}"

    {:ok, override_pid} =
      SessionSupervisor.start_session(
        session_id: sess_id,
        model: "deepseek-chat",
        max_tool_depth: 7
      )

    assert Session.get_stats(override_pid).max_tool_depth == 7
  end

  test "whitelists all ragex tools automatically without asking for user confirmation" do
    # Verify that ragex tool names starting with mcp_ragex_, ragex_, or ragex are permitted
    state = %{
      cwd: File.cwd!(),
      sandbox_workspace: false,
      permission_mode: :ask_confirm,
      session_tool_permissions: %{}
    }

    assert {:allow, _} = Session.tool_permitted?("mcp_ragex_search_code", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("mcp_ragex_ast_search", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("ragex_symbol_location", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("ragex", %{}, state)
  end
end
