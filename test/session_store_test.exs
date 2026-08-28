defmodule DeepSeekHarness.Brain.SessionStoreTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Brain.SessionStore

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "session_store_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "saves and loads session state to disk", %{tmp_dir: tmp_dir} do
    session_state = %{
      session_id: "test_sess_1",
      model: "deepseek-chat",
      permission_mode: :ask_confirm,
      step_count: 5,
      total_prompt_tokens: 120,
      total_completion_tokens: 60,
      messages: [%{"role" => "user", "content" => "Hello"}],
      snapshots: [
        %{
          id: "cp_1",
          label: "Snap 1",
          timestamp: "2026-08-17T08:00:00Z",
          model: "deepseek-chat",
          messages: []
        }
      ]
    }

    assert {:ok, file_path} = SessionStore.save_session(session_state, tmp_dir)
    assert File.exists?(file_path)

    assert {:ok, loaded} = SessionStore.load_session("test_sess_1", tmp_dir)
    assert loaded["session_id"] == "test_sess_1"
    assert loaded["model"] == "deepseek-chat"
    assert loaded["step_count"] == 5
    assert length(loaded["messages"]) == 1
    assert length(loaded["snapshots"]) == 1

    sessions = SessionStore.list_sessions(tmp_dir)
    assert "test_sess_1" in sessions
  end

  test "returns error when loading non-existent session", %{tmp_dir: tmp_dir} do
    assert {:error, msg} = SessionStore.load_session("non_existent", tmp_dir)
    assert msg =~ "does not exist"
  end

  test "extracts and truncates first user message title", %{tmp_dir: tmp_dir} do
    long_msg = String.duplicate("A long user prompt ", 10)

    session_state = %{
      session_id: "test_sess_title",
      model: "deepseek-chat",
      permission_mode: :auto_approve,
      step_count: 2,
      total_prompt_tokens: 10,
      total_completion_tokens: 10,
      messages: [
        %{"role" => "system", "content" => "System instructions..."},
        %{"role" => "user", "content" => long_msg}
      ],
      snapshots: []
    }

    {:ok, _} = SessionStore.save_session(session_state, tmp_dir)
    [meta] = SessionStore.list_session_metadata(tmp_dir)

    assert meta.session_id == "test_sess_title"
    assert String.ends_with?(meta.title, "...")
    assert String.length(meta.title) == 60
  end
end
