defmodule DeepSeekHarness.TaskEngine.Supervisor do
  @moduledoc """
  OTP Supervisor for the TaskEngine subsystem in DeepSeek Harness.
  Supervises the Task.Supervisor for concurrent worker processes and
  the LockRegistry for mutating resource locks.
  """
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Task.Supervisor, name: DeepSeekHarness.TaskEngine.TaskSupervisor},
      {Registry, keys: :unique, name: DeepSeekHarness.TaskEngine.LockRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
