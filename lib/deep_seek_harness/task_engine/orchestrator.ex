defmodule DeepSeekHarness.TaskEngine.Orchestrator do
  @moduledoc """
  Main orchestrator process for executing tool call batches concurrently.
  Spawns worker subprocesses under TaskEngine.TaskSupervisor, manages resource locking
  via TaskEngine.LockRegistry, handles timeouts, and aggregates results.
  """
  alias DeepSeekHarness.Hands.Executor, as: HandsExecutor
  alias DeepSeekHarness.TaskEngine.TaskSupervisor

  @doc """
  Executes a list of tool call structs concurrently in separate processes.
  Returns a list of tuples `{tool_call, execution_result}` in original order.
  """
  def execute_batch(tool_calls, session_state, opts \\ []) when is_list(tool_calls) do
    timeout = opts[:timeout] || 60_000

    # Pair each tool call with an index to preserve original order
    indexed_calls = Enum.with_index(tool_calls)

    tasks =
      Enum.map(indexed_calls, fn {tc, idx} ->
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            result = run_single_tool(tc, session_state)
            {idx, tc, result}
          end)

        {task, idx, tc}
      end)

    # Wait for all subprocesses concurrently
    task_structs = Enum.map(tasks, fn {task, _idx, _tc} -> task end)

    yielded_map =
      task_structs
      |> Task.yield_many(timeout)
      |> Enum.into(%{})

    # Collect and sort results by original index
    results =
      Enum.map(tasks, fn {task, idx, tc} ->
        res =
          case Map.get(yielded_map, task) do
            {:ok, {_idx, _tc, exec_result}} ->
              exec_result

            nil ->
              Task.shutdown(task, :brutal_kill)
              {:error, "Tool execution timed out after #{timeout}ms"}

            {:exit, reason} ->
              {:error, "Tool process crashed: #{inspect(reason)}"}
          end

        {idx, tc, res}
      end)

    results
    |> Enum.sort_by(fn {idx, _tc, _res} -> idx end)
    |> Enum.map(fn {_idx, tc, res} -> {tc, res} end)
  end

  defp run_single_tool(tc, session_state) do
    summary = format_short_summary(tc.name, tc.arguments)

    task_info = %{
      id: tc.id,
      name: tc.name,
      summary: summary,
      started_at: System.system_time(:second)
    }

    # Register task for real-time tracking while process is alive
    Registry.register(DeepSeekHarness.TaskEngine.TaskRegistry, "active_task", task_info)

    lock_key = get_lock_resource(tc.name, tc.arguments)

    if lock_key do
      acquire_lock(lock_key)
    end

    try do
      HandsExecutor.execute(session_state.hands, tc.name, tc.arguments)
    after
      if lock_key do
        release_lock(lock_key)
      end
    end
  end

  @doc "Formats a short human-readable summary of a tool call for real-time status display."
  def format_short_summary(tool_name, args) when is_map(args) do
    target =
      Map.get(args, "target_file") ||
        Map.get(args, "path") ||
        Map.get(args, "TargetFile") ||
        Map.get(args, "query") ||
        Map.get(args, "command") ||
        ""

    cleaned_target =
      target
      |> to_string()
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.trim()

    truncated =
      if String.length(cleaned_target) > 25 do
        String.slice(cleaned_target, 0, 22) <> "..."
      else
        cleaned_target
      end

    if truncated != "" do
      "#{tool_name}(\"#{truncated}\")"
    else
      tool_name
    end
  end

  def format_short_summary(tool_name, _), do: tool_name

  # The model can emit more than one `ask_question` tool call in a single
  # turn (e.g. one per question, instead of batching them into a single
  # call's `questions` list). Since `DeepSeekHarness.CLI.QuestionPrompt`
  # reads raw keystrokes directly from `:user`, running two of its modals
  # concurrently would let a keystroke intended for one resolve the other
  # instead. A fixed lock key -- shared across every `ask_question` call
  # regardless of arguments -- guarantees only one such modal ever holds
  # the terminal at a time; additional calls simply wait (before ever
  # touching the TTY) until the current one fully returns.
  @doc false
  def get_lock_resource("ask_question", _args), do: "tty_interactive"

  def get_lock_resource(tool_name, args) when is_map(args) do
    if tool_name in ["write_file", "replace_file", "write_to_file", "replace_file_content"] do
      path = Map.get(args, "target_file") || Map.get(args, "path") || Map.get(args, "TargetFile")
      if is_binary(path), do: "file_lock:" <> Path.expand(path)
    else
      nil
    end
  end

  def get_lock_resource(_, _), do: nil

  defp acquire_lock(resource_key) when is_binary(resource_key) do
    case Registry.register(DeepSeekHarness.TaskEngine.LockRegistry, resource_key, :locked) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        Process.sleep(10)
        acquire_lock(resource_key)
    end
  end

  defp release_lock(resource_key) when is_binary(resource_key) do
    Registry.unregister(DeepSeekHarness.TaskEngine.LockRegistry, resource_key)
  rescue
    _ -> :ok
  end
end
