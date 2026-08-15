defmodule DeepSeekHarness.Brain.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for managing agentic session actors ("Brains").
  Allows spawning multiple concurrent session processes on demand.
  """
  use DynamicSupervisor

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts a new session actor with given options."
  def start_session(opts \\ []) do
    spec = {DeepSeekHarness.Brain.Session, opts}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Terminates a session process."
  def stop_session(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
