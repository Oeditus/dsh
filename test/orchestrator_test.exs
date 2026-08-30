defmodule DeepSeekHarness.TaskEngine.OrchestratorTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.TaskEngine.Orchestrator

  describe "get_lock_resource/2" do
    test "returns a fixed shared key for every ask_question call, regardless of arguments" do
      assert Orchestrator.get_lock_resource("ask_question", %{}) == "tty_interactive"

      assert Orchestrator.get_lock_resource("ask_question", %{"questions" => [%{}]}) ==
               "tty_interactive"

      # Same key across two differently-shaped calls -- this is what
      # actually serializes them via the shared LockRegistry entry.
      assert Orchestrator.get_lock_resource("ask_question", %{"a" => 1}) ==
               Orchestrator.get_lock_resource("ask_question", %{"b" => 2})
    end

    test "returns a per-path file lock key for write/replace tools" do
      key = Orchestrator.get_lock_resource("write_file", %{"path" => "/tmp/foo.txt"})
      assert key == "file_lock:" <> Path.expand("/tmp/foo.txt")
    end

    test "returns nil for tools with no locking requirement" do
      assert Orchestrator.get_lock_resource("read_file", %{"path" => "/tmp/foo.txt"}) == nil
      assert Orchestrator.get_lock_resource("bash", %{"command" => "ls"}) == nil
    end
  end
end
