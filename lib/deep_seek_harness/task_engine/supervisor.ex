defmodule DeepSeekHarness.TaskEngine.Supervisor do
  @moduledoc """
  OTP Supervisor for the TaskEngine subsystem in DeepSeek Harness.
  Supervises the Task.Supervisor for concurrent worker processes,
  the LockRegistry for mutating resource locks, and the TaskRegistry
  for real-time active task tracking.
  """
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Task.Supervisor, name: DeepSeekHarness.TaskEngine.TaskSupervisor},
      {Registry, keys: :unique, name: DeepSeekHarness.TaskEngine.LockRegistry},
      {Registry, keys: :duplicate, name: DeepSeekHarness.TaskEngine.TaskRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Lists all currently active parallel tasks registered in TaskRegistry."
  def list_active_tasks do
    case Registry.lookup(DeepSeekHarness.TaskEngine.TaskRegistry, "active_task") do
      entries when is_list(entries) ->
        Enum.map(entries, fn {_pid, info} -> info end)

      _ ->
        []
    end
  rescue
    _ -> []
  end
end
