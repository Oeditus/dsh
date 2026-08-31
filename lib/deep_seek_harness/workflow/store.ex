defmodule DeepSeekHarness.Workflow.Store do
  @moduledoc """
  Disk persistence for workflow runs, mirroring the conventions already
  established by `DeepSeekHarness.Brain.SessionStore`: one directory per
  run under `.dsh/workflows/runs/<run_id>/`, a resumable `state.json`
  checkpoint, and an append-only `transcript.jsonl` capturing every
  prompt, model response, user confirmation, and command run during the
  workflow -- so the *entire* run (not just its final outcome) is
  inspectable on disk afterwards.
  """
  require Logger

  alias DeepSeekHarness.Workflow.Definition
  alias DeepSeekHarness.Workflow.Json

  @doc "Root directory holding every workflow run in this workspace."
  def runs_dir(cwd \\ "."), do: Path.join(cwd, ".dsh/workflows/runs")

  @doc "Directory for a specific run."
  def run_dir(run_id, cwd \\ "."), do: Path.join(runs_dir(cwd), run_id)

  @doc "Directory for a specific accepted subtask within a run's parallel split."
  def subtask_dir(run_id, subtask_id, cwd \\ ".") do
    Path.join([run_dir(run_id, cwd), "subtasks", subtask_id])
  end

  @doc """
  Generates a new, filesystem- and branch-name-safe run ID from a
  workflow name: `<workflow>-<unix_timestamp>-<short_random_suffix>`.
  """
  def new_run_id(workflow_name) do
    slug = slugify(workflow_name)
    timestamp = System.system_time(:second)
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{slug}-#{timestamp}-#{suffix}"
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Initializes a new run directory: writes the resolved `workflow.json`
  snapshot (so later edits to the source definition never reinterpret
  this run's history) and an initial `state.json` checkpoint.
  """
  def init_run!(run_id, %Definition{} = definition, cwd \\ ".") do
    dir = run_dir(run_id, cwd)
    File.mkdir_p!(Path.join(dir, "subtasks"))
    File.mkdir_p!(Path.join(dir, "artifacts"))

    snapshot = %{
      "name" => definition.name,
      "description" => definition.description,
      "rules_scope" => definition.rules_scope,
      "base_branch_prefixes" => definition.base_branch_prefixes,
      "steps" => definition.steps
    }

    File.write!(Path.join(dir, "workflow.json"), Json.encode_pretty!(snapshot))

    now = iso_now()

    state = %{
      "run_id" => run_id,
      "workflow" => definition.name,
      "status" => "pending",
      "step_index" => 0,
      "branch" => nil,
      "base_branch" => nil,
      "created_at" => now,
      "updated_at" => now
    }

    save_state!(run_id, state, cwd)
    {:ok, dir}
  end

  @doc "Persists (overwriting) the run's `state.json` checkpoint, stamping `updated_at`."
  def save_state!(run_id, state, cwd \\ ".") when is_map(state) do
    dir = run_dir(run_id, cwd)
    File.mkdir_p!(dir)
    stamped = Map.put(state, "updated_at", iso_now())
    File.write!(Path.join(dir, "state.json"), Json.encode_pretty!(stamped))
    stamped
  end

  @doc "Loads a run's `state.json` checkpoint."
  def load_state(run_id, cwd \\ ".") do
    path = Path.join(run_dir(run_id, cwd), "state.json")

    with true <- File.exists?(path) || {:error, "No such workflow run: '#{run_id}'."},
         {:ok, content} <- File.read(path),
         {:ok, state} <- Json.decode(content) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Loads the resolved `workflow.json` step-spec snapshot a run was started with."
  def load_snapshot(run_id, cwd \\ ".") do
    path = Path.join(run_dir(run_id, cwd), "workflow.json")

    with {:ok, content} <- File.read(path),
         {:ok, snapshot} <- Json.decode(content) do
      {:ok, snapshot}
    else
      _ -> {:error, "Failed to load workflow snapshot for run '#{run_id}'."}
    end
  end

  @doc """
  Appends one event to the run's `transcript.jsonl` -- the same
  `{timestamp, type, payload}` shape `SessionStore.append_transcript/4`
  already uses, so every prompt sent, model response received, user
  confirmation + answer, and command executed during the run is
  reconstructable afterwards.
  """
  def append_transcript(run_id, event_type, payload, cwd \\ ".") do
    dir = run_dir(run_id, cwd)
    File.mkdir_p!(dir)

    entry = %{
      "timestamp" => iso_now(),
      "type" => to_string(event_type),
      "payload" => payload
    }

    line = Json.encode!(entry) <> "\n"
    File.write!(Path.join(dir, "transcript.jsonl"), line, [:append])
  rescue
    e ->
      Logger.warning(
        "[Workflow.Store] Failed to append transcript for '#{run_id}': #{inspect(e)}"
      )

      :ok
  end

  @doc "Writes the step-② summarized task description."
  def write_task_description!(run_id, text, cwd \\ ".") when is_binary(text) do
    dir = run_dir(run_id, cwd)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "task_description.md"), text)
  end

  @doc "Reads back the step-② task description, or `nil` if not yet written."
  def read_task_description(run_id, cwd \\ ".") do
    path = Path.join(run_dir(run_id, cwd), "task_description.md")
    if File.exists?(path), do: File.read!(path), else: nil
  end

  @doc "Writes the step-③ proposed (and accepted/rejected) task split plan."
  def write_split_plan!(run_id, plan, cwd \\ ".") when is_map(plan) do
    dir = run_dir(run_id, cwd)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "split_plan.json"), Json.encode_pretty!(plan))
  end

  @doc "Reads back the step-③ split plan, or `nil` if not yet written."
  def read_split_plan(run_id, cwd \\ ".") do
    path = Path.join(run_dir(run_id, cwd), "split_plan.json")

    case File.exists?(path) && File.read(path) do
      {:ok, content} -> Json.decode!(content)
      _ -> nil
    end
  end

  @doc "Persists a small text field (session id, worktree path, branch name) for one accepted subtask."
  def write_subtask_field!(run_id, subtask_id, field, value, cwd \\ ".")
      when field in ["session_id", "worktree", "branch"] do
    dir = subtask_dir(run_id, subtask_id, cwd)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{field}.txt"), to_string(value))
  end

  @doc "Writes a subtask's final result/outcome summary."
  def write_subtask_result!(run_id, subtask_id, markdown, cwd \\ ".") do
    dir = subtask_dir(run_id, subtask_id, cwd)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "result.md"), markdown)
  end

  @doc "Writes a named artifact (lint output, test output, ...) for a run."
  def write_artifact!(run_id, name, content, cwd \\ ".") do
    dir = Path.join(run_dir(run_id, cwd), "artifacts")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), content)
  end

  @doc "Lists metadata for every run in the workspace, most-recently-updated first."
  def list_runs(cwd \\ ".") do
    dir = runs_dir(cwd)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&run_metadata(&1, cwd))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.updated_at, :desc)

      _ ->
        []
    end
  end

  defp run_metadata(run_id, cwd) do
    case load_state(run_id, cwd) do
      {:ok, state} ->
        %{
          run_id: run_id,
          workflow: state["workflow"],
          status: state["status"],
          step_index: state["step_index"],
          branch: state["branch"],
          updated_at: state["updated_at"] || ""
        }

      _ ->
        nil
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
