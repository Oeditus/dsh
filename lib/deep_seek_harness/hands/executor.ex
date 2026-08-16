defmodule DeepSeekHarness.Hands.Executor do
  @moduledoc """
  The "Hands" component of DeepSeek Harness.
  Executes tools and sandbox operations across local system, isolated Erlang nodes, or Docker containers.
  Provides temporal side-effect tracking for undo and crash recovery.
  """
  require Logger

  defstruct [
    # :local | :remote | :docker
    mode: :local,
    # e.g., :"hands@127.0.0.1"
    remote_node: nil,
    # e.g., "dsh_sandbox_1"
    docker_container: nil
  ]

  @type execution_mode :: :local | :remote | :docker

  @doc "Executes a tool call under the configured sandbox target."
  def execute(%__MODULE__{mode: :local}, tool_name, args) do
    Logger.info("[Hands.Executor] [local] Executing #{tool_name} with args: #{inspect(args)}")

    case DeepSeekHarness.Plugin.Loader.execute_tool(tool_name, args, :infinity) do
      {:ok, result} -> {:ok, format_output(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%__MODULE__{mode: :remote, remote_node: node}, tool_name, args)
      when not is_nil(node) do
    Logger.info(
      "[Hands.Executor] [remote:#{node}] Executing #{tool_name} via Distributed Erlang RPC"
    )

    case :rpc.call(
           node,
           DeepSeekHarness.Plugin.Loader,
           :execute_tool,
           [tool_name, args, :infinity],
           :infinity
         ) do
      {:ok, result} ->
        {:ok, format_output(result)}

      {:error, reason} ->
        {:error, "Remote node execution error: #{inspect(reason)}"}

      {:badrpc, nodedown_reason} ->
        {:error, "Remote node unreachable (#{node}): #{inspect(nodedown_reason)}"}
    end
  end

  def execute(%__MODULE__{mode: :docker, docker_container: container}, tool_name, args)
      when not is_nil(container) do
    Logger.info("[Hands.Executor] [docker:#{container}] Executing tool via Docker sandbox")

    case tool_name do
      "bash" ->
        cmd = Map.get(args, "command", "")
        docker_cmd = "docker exec #{container} sh -c #{shell_quote(cmd)}"

        case System.cmd("sh", ["-c", docker_cmd], stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, "Docker exec exited with status #{code}:\n#{out}"}
        end

      _ ->
        # Fallback to local RPC execution inside docker if node is shared or standard local
        execute(%__MODULE__{mode: :local}, tool_name, args)
    end
  end

  def execute(config, tool_name, args) do
    {:error,
     "Invalid Hands configuration: #{inspect(config)} for tool #{tool_name} (#{inspect(args)})"}
  end

  defp format_output(output) when is_binary(output), do: output
  defp format_output(output), do: inspect(output, pretty: true)

  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
