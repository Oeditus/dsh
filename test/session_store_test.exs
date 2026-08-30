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

  describe "import_session/3" do
    test "imports the native save_session schema and makes it resumable", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "external_export.json")

      File.write!(
        source_path,
        Jason.encode!(%{
          "session_id" => "from_source",
          "model" => "deepseek-reasoner",
          "permission_mode" => "auto_approve",
          "step_count" => 3,
          "total_prompt_tokens" => 100,
          "total_completion_tokens" => 50,
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "snapshots" => []
        })
      )

      assert {:ok, "from_source", file_path} =
               SessionStore.import_session(source_path, [], tmp_dir)

      assert File.exists?(file_path)

      assert {:ok, loaded} = SessionStore.load_session("from_source", tmp_dir)
      assert loaded["model"] == "deepseek-reasoner"
      assert length(loaded["messages"]) == 1
    end

    test "imports a bare {\"messages\": [...]} object, defaulting missing fields", %{
      tmp_dir: tmp_dir
    } do
      source_path = Path.join(tmp_dir, "bare_messages.json")

      File.write!(
        source_path,
        Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "Hi"}]})
      )

      assert {:ok, session_id, _file_path} =
               SessionStore.import_session(source_path, [session_id: "bare_import"], tmp_dir)

      assert session_id == "bare_import"
      assert {:ok, loaded} = SessionStore.load_session("bare_import", tmp_dir)
      assert loaded["model"] == "deepseek-chat"
      assert length(loaded["messages"]) == 1
    end

    test "imports a raw top-level JSON array of messages", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "raw_array.json")

      File.write!(
        source_path,
        Jason.encode!([
          %{"role" => "user", "content" => "Hi"},
          %{"role" => "assistant", "content" => "Hello!"}
        ])
      )

      assert {:ok, session_id, _file_path} =
               SessionStore.import_session(source_path, [session_id: "raw_array_import"], tmp_dir)

      assert {:ok, loaded} = SessionStore.load_session(session_id, tmp_dir)
      assert length(loaded["messages"]) == 2
    end

    test "refuses to overwrite an existing session unless overwrite: true", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "dup.json")

      File.write!(
        source_path,
        Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "Hi"}]})
      )

      assert {:ok, "dup_id", _} =
               SessionStore.import_session(source_path, [session_id: "dup_id"], tmp_dir)

      assert {:error, msg} =
               SessionStore.import_session(source_path, [session_id: "dup_id"], tmp_dir)

      assert msg =~ "already exists"

      assert {:ok, "dup_id", _} =
               SessionStore.import_session(
                 source_path,
                 [session_id: "dup_id", overwrite: true],
                 tmp_dir
               )
    end

    test "returns an error for invalid JSON", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "invalid.json")
      File.write!(source_path, "{not valid json")

      assert {:error, msg} = SessionStore.import_session(source_path, [], tmp_dir)
      assert msg =~ "Invalid JSON"
    end

    test "returns an error when no messages array is present", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "no_messages.json")
      File.write!(source_path, Jason.encode!(%{"session_id" => "whatever"}))

      assert {:error, msg} = SessionStore.import_session(source_path, [], tmp_dir)
      assert msg =~ "messages"
    end

    test "returns an error when the source file does not exist", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               SessionStore.import_session(Path.join(tmp_dir, "missing.json"), [], tmp_dir)

      assert msg =~ "Failed to read"
    end
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
