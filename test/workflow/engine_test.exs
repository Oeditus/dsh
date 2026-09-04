defmodule DeepSeekHarness.Workflow.EngineTest do
  # Not async: tests capture global :user IO device output
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias DeepSeekHarness.Workflow.Definition
  alias DeepSeekHarness.Workflow.Engine
  alias DeepSeekHarness.Workflow.Store

  setup do
    cwd =
      Path.join(System.tmp_dir!(), "dsh_workflow_engine_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: cwd)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: cwd)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: cwd)
    File.write!(Path.join(cwd, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: cwd)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial"], cd: cwd)

    on_exit(fn -> File.rm_rf(cwd) end)
    %{cwd: cwd}
  end

  defp define!(name, steps, cwd) do
    dir = Definition.definitions_dir(cwd)
    File.mkdir_p!(dir)
    raw = %{"name" => name, "steps" => steps}
    File.write!(Path.join(dir, "#{name}.json"), DeepSeekHarness.Workflow.Json.encode_pretty!(raw))
  end

  describe "run/2 with a single branch step" do
    test "creates the branch and completes when already on a base branch", %{cwd: cwd} do
      define!("just-branch", [%{"type" => "branch"}], cwd)

      assert {:ok, context} = Engine.run("just-branch", cwd: cwd, seed_prompt: "do the thing")
      assert context.branch =~ "dsh/just-branch/"
      assert DeepSeekHarness.Git.current_branch(cwd) == context.branch

      assert {:ok, state} = Engine.status(context.run_id, cwd)
      assert state["status"] == "completed"
      assert state["step_index"] == 1
      assert state["branch"] == context.branch
    end

    test "halts (does not raise) when the current branch isn't a base branch and the user declines",
         %{cwd: cwd} do
      define!("just-branch-2", [%{"type" => "branch"}], cwd)
      {:ok, _} = DeepSeekHarness.Git.create_branch("some-feature", cwd)

      test_pid = self()

      # The branch step's confirmation prompt reads from the `:user` IO
      # device via `IO.gets/2` when not attached to a real TTY (always the
      # case under ExUnit). Feeding it deterministic input here (rather
      # than relying on stdin happening to already be at EOF) avoids a
      # real, environment-dependent block on live stdin -- which, run
      # outside this specific capture, previously hung for the full 60s
      # test timeout when the suite's own stdin was still open.
      capture_io(:user, "2\n", fn ->
        result = Engine.run("just-branch-2", cwd: cwd, seed_prompt: "x")
        send(test_pid, {:workflow_result, result})
      end)

      assert_received {:workflow_result, {:halt, reason}}
      assert reason =~ "Workflow aborted before branching"

      [run_meta] = Store.list_runs(cwd)
      assert {:ok, state} = Engine.status(run_meta.run_id, cwd)
      assert state["status"] == "halted"
      # The branch step never actually created a branch on the halt path.
      assert DeepSeekHarness.Git.current_branch(cwd) == "some-feature"
    end
  end

  describe "unknown step types" do
    test "fails cleanly instead of crashing" do
      cwd =
        Path.join(
          System.tmp_dir!(),
          "dsh_workflow_engine_bad_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)
      define!("bad", [%{"type" => "not_a_real_step"}], cwd)

      assert {:error, reason} = Engine.run("bad", cwd: cwd)
      assert reason =~ "Unknown workflow step type"
    end
  end

  describe "status/2, abort/2, and resume/2" do
    test "a run that fails partway through can be inspected, aborted, and refuses to resume afterward",
         %{
           cwd: cwd
         } do
      # `commit` will fail here since there is nothing to commit after just
      # branching -- a realistic, deterministic failure to exercise the
      # failed -> abort -> resume-refused path without needing to fabricate
      # a file change.
      define!("branch-then-commit", [%{"type" => "branch"}, %{"type" => "commit"}], cwd)

      assert {:error, _reason} = Engine.run("branch-then-commit", cwd: cwd, seed_prompt: "x")

      [run_meta] = Store.list_runs(cwd)
      run_id = run_meta.run_id

      assert {:ok, state} = Engine.status(run_id, cwd)
      assert state["status"] == "failed"
      assert state["step_index"] == 1

      # Resuming a failed (not aborted/completed) run re-attempts from the
      # same step and fails again for the same underlying reason.
      assert {:error, _reason} = Engine.resume(run_id, cwd)

      assert {:ok, _} = Engine.abort(run_id, cwd)
      assert {:ok, %{"status" => "aborted"}} = Engine.status(run_id, cwd)
      assert {:error, msg} = Engine.resume(run_id, cwd)
      assert msg =~ "aborted"
    end

    test "status/2 reports an error for a run id that was never created", %{cwd: cwd} do
      assert {:error, _reason} = Engine.status("no-such-run", cwd)
    end
  end
end
