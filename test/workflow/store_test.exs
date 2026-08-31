defmodule DeepSeekHarness.Workflow.StoreTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Workflow.Definition
  alias DeepSeekHarness.Workflow.Store

  setup do
    cwd = Path.join(System.tmp_dir!(), "dsh_workflow_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    {:ok, definition} =
      Definition.parse(%{
        "name" => "elixir",
        "description" => "d",
        "steps" => [%{"type" => "commit"}]
      })

    %{cwd: cwd, definition: definition}
  end

  test "new_run_id/1 produces unique, filesystem-safe ids" do
    id_a = Store.new_run_id("elixir")
    id_b = Store.new_run_id("elixir")

    assert id_a != id_b
    assert id_a =~ ~r/^elixir-\d+-[0-9a-f]+$/
  end

  test "init_run! writes a resolved workflow.json snapshot and initial state", %{
    cwd: cwd,
    definition: definition
  } do
    run_id = Store.new_run_id("elixir")
    assert {:ok, dir} = Store.init_run!(run_id, definition, cwd)
    assert File.dir?(dir)

    assert {:ok, snapshot} = Store.load_snapshot(run_id, cwd)
    assert snapshot["name"] == "elixir"
    assert snapshot["steps"] == [%{"type" => "commit"}]

    assert {:ok, state} = Store.load_state(run_id, cwd)
    assert state["status"] == "pending"
    assert state["step_index"] == 0
  end

  test "save_state!/3 round-trips and stamps updated_at", %{cwd: cwd, definition: definition} do
    run_id = Store.new_run_id("elixir")
    {:ok, _} = Store.init_run!(run_id, definition, cwd)

    updated = Store.save_state!(run_id, %{"status" => "running", "step_index" => 2}, cwd)
    assert updated["status"] == "running"
    assert is_binary(updated["updated_at"])

    assert {:ok, reloaded} = Store.load_state(run_id, cwd)
    assert reloaded["status"] == "running"
    assert reloaded["step_index"] == 2
  end

  test "load_state/2 errors for a run that doesn't exist", %{cwd: cwd} do
    assert {:error, msg} = Store.load_state("no-such-run", cwd)
    assert msg =~ "No such workflow run"
  end

  test "append_transcript/4 appends one JSON line per call", %{cwd: cwd, definition: definition} do
    run_id = Store.new_run_id("elixir")
    {:ok, _} = Store.init_run!(run_id, definition, cwd)

    Store.append_transcript(run_id, :prompt, %{"text" => "hello"}, cwd)
    Store.append_transcript(run_id, :response, %{"text" => "world"}, cwd)

    path = Path.join(Store.run_dir(run_id, cwd), "transcript.jsonl")
    lines = path |> File.read!() |> String.split("\n", trim: true)

    assert length(lines) == 2
    assert Enum.at(lines, 0) =~ "\"type\":\"prompt\""
    assert Enum.at(lines, 1) =~ "\"text\":\"world\""
  end

  test "task description and split plan round-trip", %{cwd: cwd, definition: definition} do
    run_id = Store.new_run_id("elixir")
    {:ok, _} = Store.init_run!(run_id, definition, cwd)

    assert Store.read_task_description(run_id, cwd) == nil
    Store.write_task_description!(run_id, "Do the thing.", cwd)
    assert Store.read_task_description(run_id, cwd) == "Do the thing."

    assert Store.read_split_plan(run_id, cwd) == nil
    plan = %{"accepted" => true, "subtasks" => [%{"id" => "a", "summary" => "part A"}]}
    Store.write_split_plan!(run_id, plan, cwd)
    assert Store.read_split_plan(run_id, cwd) == plan
  end

  test "subtask fields and results are written under subtasks/<id>/", %{
    cwd: cwd,
    definition: definition
  } do
    run_id = Store.new_run_id("elixir")
    {:ok, _} = Store.init_run!(run_id, definition, cwd)

    Store.write_subtask_field!(run_id, "a", "branch", "dsh/elixir/subtask-a", cwd)
    Store.write_subtask_field!(run_id, "a", "worktree", "/tmp/worktree-a", cwd)
    Store.write_subtask_result!(run_id, "a", "## Done\nAll good.", cwd)

    dir = Store.subtask_dir(run_id, "a", cwd)
    assert File.read!(Path.join(dir, "branch.txt")) == "dsh/elixir/subtask-a"
    assert File.read!(Path.join(dir, "worktree.txt")) == "/tmp/worktree-a"
    assert File.read!(Path.join(dir, "result.md")) =~ "All good."
  end

  test "list_runs/1 returns metadata for every run, most recently updated first", %{
    cwd: cwd,
    definition: definition
  } do
    run_id_1 = Store.new_run_id("elixir")
    {:ok, _} = Store.init_run!(run_id_1, definition, cwd)
    # Ensure a strictly later timestamp for deterministic ordering (ISO8601
    # timestamps here carry microsecond precision, so a tiny sleep suffices).
    Process.sleep(5)
    run_id_2 = Store.new_run_id("elixir")
    {:ok, _} = Store.init_run!(run_id_2, definition, cwd)

    [most_recent, oldest] = Store.list_runs(cwd)
    assert most_recent.run_id == run_id_2
    assert oldest.run_id == run_id_1
  end
end
