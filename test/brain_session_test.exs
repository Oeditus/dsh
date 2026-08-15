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
end
