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

  describe "interactive_tool?/1" do
    test "only ask_question is treated as an interactive, non-expiring tool" do
      assert Orchestrator.interactive_tool?("ask_question")
      refute Orchestrator.interactive_tool?("bash")
      refute Orchestrator.interactive_tool?("read_file")
    end
  end

  describe "execute_batch/3" do
    test "ask_question tool calls are never cut off by the batch execution timeout" do
      session_state = %{hands: %DeepSeekHarness.Hands.Executor{mode: :local}}

      tool_calls = [
        # Invalid arguments resolve near-instantly via a fast error path,
        # without ever touching the TTY -- safe to run in a unit test.
        %{id: "1", name: "ask_question", arguments: %{}},
        %{id: "2", name: "bash", arguments: %{"command" => "sleep 1"}}
      ]

      # An absurdly small timeout: any tool call subject to it is
      # guaranteed to be reported as timed out / killed.
      results = Orchestrator.execute_batch(tool_calls, session_state, timeout: 1)

      {_ask_tc, ask_res} = Enum.find(results, fn {tc, _res} -> tc.id == "1" end)
      {_bash_tc, bash_res} = Enum.find(results, fn {tc, _res} -> tc.id == "2" end)

      # The ask_question call completed on its own terms (its real "invalid
      # arguments" error), proving it was awaited with :infinity rather
      # than being force-killed by the 1ms batch timeout.
      assert {:error, ask_msg} = ask_res
      assert ask_msg =~ "Invalid arguments"
      refute ask_msg =~ "timed out"

      # Meanwhile a normal (non-interactive) tool call is still subject to
      # the batch timeout as before.
      assert {:error, bash_msg} = bash_res
      assert bash_msg =~ "timed out"
    end
  end
end
