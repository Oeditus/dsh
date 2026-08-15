defmodule DeepSeekHarness.Distribution.NodeManager do
  @moduledoc """
  Manages Distributed Erlang node clustering for DeepSeek Harness (DSH).
  Enables decoupling Brains (Session Actors) from Hands (Sandbox Workers).
  """
  require Logger

  @doc "Starts local distribution on current node."
  def start_node(name \\ "dsh_brain", type \\ :shortnames) do
    if Node.alive?() do
      {:ok, Node.self()}
    else
      full_name = String.to_atom(name)

      case Node.start(full_name, type) do
        {:ok, _pid} ->
          Logger.info("[Distribution] Started Erlang node: #{Node.self()}")
          {:ok, Node.self()}

        {:error, reason} ->
          {:error, "Failed to start node #{name}: #{inspect(reason)}"}
      end
    end
  end

  @doc "Connects to a remote target node."
  def connect(remote_node_str) do
    remote_atom = String.to_atom(remote_node_str)

    if Node.connect(remote_atom) do
      Logger.info("[Distribution] Successfully connected to remote node: #{remote_atom}")
      {:ok, remote_atom}
    else
      {:error, "Could not connect to node: #{remote_node_str}"}
    end
  end

  @doc "Lists all connected distributed nodes."
  def list_nodes do
    %{
      self: Node.self(),
      alive?: Node.alive?(),
      connected: Node.list()
    }
  end

  @doc "Executes a function remotely on a target node."
  def rpc_call(node, module, fun, args, timeout \\ 15_000) do
    case :rpc.call(node, module, fun, args, timeout) do
      {:badrpc, reason} -> {:error, "RPC failed on node #{node}: #{inspect(reason)}"}
      result -> {:ok, result}
    end
  end
end
