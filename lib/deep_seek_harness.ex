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
end
