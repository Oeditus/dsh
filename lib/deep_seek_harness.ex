defmodule DeepSeekHarness do
  @moduledoc """
  Top-level module for DeepSeek Harness (DSH).
  Exposes public API helper methods to interact with sessions, plugins, and distribution.
  """

  alias DeepSeekHarness.Brain.Session
  alias DeepSeekHarness.Brain.SessionSupervisor
  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader

  @doc "Starts a new session actor with given options."
  def start_session(opts \\ []) do
    SessionSupervisor.start_session(opts)
  end

  @doc "Sends a message to an active session actor."
  def send_message(session_pid, text) do
    Session.send_user_message(session_pid, text)
  end

  @doc "Loads a plugin file dynamically."
  def load_plugin(path) do
    PluginLoader.load_file(path)
  end

  @doc "Reloads all loaded plugins dynamically without dropping state."
  def reload_plugins do
    PluginLoader.reload_all()
  end

  @doc "Returns total number of BEAM processes currently serving across the system."
  def serving_process_count do
    length(Process.list())
  end

  @doc "Returns structured process status map reporting current serving processes and task workers."
  def process_status do
    active_task_workers =
      case Process.whereis(DeepSeekHarness.TaskEngine.TaskSupervisor) do
        nil -> 0
        sup -> length(Task.Supervisor.children(sup))
      end

    active_sessions =
      if Process.whereis(DeepSeekHarness.Registry) != nil do
        Registry.count(DeepSeekHarness.Registry)
      else
        0
      end

    %{
      total_serving_processes: length(Process.list()),
      active_task_workers: active_task_workers,
      active_sessions: active_sessions,
      schedulers_online: System.schedulers_online()
    }
  end

  @doc "Returns a human-readable status banner of serving processes."
  def report_serving_processes do
    status = process_status()
    "⚡ #{status.total_serving_processes} BEAM processes serving (#{status.active_task_workers} parallel task workers, #{status.active_sessions} session actors, #{status.schedulers_online} online schedulers)"
  end
end
