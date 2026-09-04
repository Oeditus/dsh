defmodule DeepSeekHarness.CLIReplTest do
  use ExUnit.Case, async: false

  alias DeepSeekHarness.Brain.SessionSupervisor
  alias DeepSeekHarness.CLI.Repl

  setup do
    session_id = "repl_test_#{System.unique_integer([:positive])}"
    {:ok, session_pid} = SessionSupervisor.start_session(session_id: session_id)
    {:ok, session_pid: session_pid, session_id: session_id}
  end

  test "handles standard slash commands", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/help", pid, id)
    assert :continue = Repl.handle_input("/clear", pid, id)
    assert :continue = Repl.handle_input("/reset", pid, id)
    assert :continue = Repl.handle_input("/cost", pid, id)
    assert :continue = Repl.handle_input("/session", pid, id)
    assert :continue = Repl.handle_input("/nodes", pid, id)
    assert :continue = Repl.handle_input("/skills", pid, id)
    assert :continue = Repl.handle_input("/plugins", pid, id)
    assert :continue = Repl.handle_input("/mcp", pid, id)
    assert :continue = Repl.handle_input("/mcp list", pid, id)
    assert :continue = Repl.handle_input("/mcp ls", pid, id)
  end

  test "handles permission and model switching", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/permissions auto", pid, id)
    assert :continue = Repl.handle_input("/permissions ask", pid, id)
    assert :continue = Repl.handle_input("/model reasoner", pid, id)
    assert :continue = Repl.handle_input("/model chat", pid, id)
    assert :continue = Repl.handle_input("/model vision", pid, id)
    assert :continue = Repl.handle_input("/model v4", pid, id)
  end

  test "handles hands execution mode settings", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/mode local", pid, id)
    assert :continue = Repl.handle_input("/mode remote hands@127.0.0.1", pid, id)
    assert :continue = Repl.handle_input("/mode docker dsh_box", pid, id)
  end

  test "handles checkpoint and undo operations", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/checkpoint test_snap", pid, id)
    assert :continue = Repl.handle_input("/undo", pid, id)
  end

  test "handles shell command shortcut and unknown commands", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("!echo 'test_shell'", pid, id)
    assert :continue = Repl.handle_input("/unknown_command", pid, id)
  end

  test "handles the !! pure console mode flip-flop", %{session_pid: pid, session_id: id} do
    assert :toggle_console = Repl.handle_input("!!", pid, id)
    assert :toggle_console = Repl.handle_input("!!", pid, id)
  end

  test "handles exit and quit commands", %{session_pid: pid, session_id: id} do
    assert :exit = Repl.handle_input("/exit", pid, id)
    assert :exit = Repl.handle_input("/quit", pid, id)
  end

  test "handles session switch and resume commands", %{session_pid: pid, session_id: id} do
    target_id = "target_test_session"

    assert {:switch_session, ^target_id, new_pid} =
             Repl.handle_input("/session switch " <> target_id, pid, id)

    assert is_pid(new_pid)

    assert {:switch_session, ^target_id, _} = Repl.handle_input("/resume " <> target_id, pid, id)

    assert {:switch_session, ^target_id, _} =
             Repl.handle_input("/session resume " <> target_id, pid, id)
  end

  test "handles /plan slash commands without writing to the repo config", %{
    session_pid: pid,
    session_id: id
  } do
    # The /plan on|off handlers persist to the workspace .dsh/config.json
    # (cwd "."), which would pollute the repo. Back up any existing file and
    # restore it afterwards to keep the workspace clean.
    cfg_path = Path.join(File.cwd!(), ".dsh/config.json")
    backup_path = cfg_path <> ".repl_test_backup"

    existed? = File.exists?(cfg_path)

    if existed? do
      File.cp!(cfg_path, backup_path)
    end

    on_exit(fn ->
      if existed? do
        if File.exists?(backup_path) do
          File.rm(cfg_path)
          File.rename!(backup_path, cfg_path)
        end
      else
        File.rm(cfg_path)
      end
    end)

    assert :continue = Repl.handle_input("/plan status", pid, id)
    assert :continue = Repl.handle_input("/plan", pid, id)
    assert :continue = Repl.handle_input("/plan on", pid, id)
    assert :continue = Repl.handle_input("/plan off", pid, id)
    assert :continue = Repl.handle_input("/plan foo", pid, id)
  end
end
