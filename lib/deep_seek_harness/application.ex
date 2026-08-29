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
      # OTP Task Subsystem (Task.Supervisor & LockRegistry)
      DeepSeekHarness.TaskEngine.Supervisor,
      # Supervisor for session actors ("Brains")
      DeepSeekHarness.Brain.SessionSupervisor
    ]

    opts = [strategy: :one_for_all, name: DeepSeekHarness.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        install_sigterm_trap()
        Logger.info("[DeepSeekHarness] Application started successfully.")
        {:ok, pid}

      error ->
        error
    end
  end

  # Terminal/process-manager shutdowns (e.g. `kill`, closing the terminal tab)
  # commonly deliver SIGTERM rather than going through the REPL's `/exit`
  # path. Without this, the per-project Ragex/dllb OS process is left
  # running as an orphan, so the next launch can't reliably reuse its
  # on-disk cache and ends up doing a full re-index every time.
  defp install_sigterm_trap do
    System.trap_signal(:sigterm, :dsh_graceful_shutdown, fn ->
      try do
        DeepSeekHarness.MCP.ServerManager.stop_ragex()
      catch
        _, _ -> :ok
      end

      :ok
    end)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
