defmodule DeepSeekHarness.Application do
  @moduledoc """
  OTP Application supervision tree for DeepSeek Harness (DSH).
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    DeepSeekHarness.CLI.LogFormatter.install()

    children = [
      # Unique registry for process naming via tuple
      {Registry, keys: :unique, name: DeepSeekHarness.Registry},
      # Duplicate registry for session broadcasting (pubsub)
      {Registry, keys: :duplicate, name: DeepSeekHarness.PubSubRegistry},
      # Dynamic plugin hot-reloader & tool registry
      DeepSeekHarness.Plugin.Loader,
      # MCP Server Manager
      DeepSeekHarness.MCP.ServerManager,
      # Supervisor for session actors ("Brains")
      DeepSeekHarness.Brain.SessionSupervisor
    ]

    opts = [strategy: :one_for_all, name: DeepSeekHarness.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("[DeepSeekHarness] Application started successfully.")
        {:ok, pid}

      error ->
        error
    end
  end
end
