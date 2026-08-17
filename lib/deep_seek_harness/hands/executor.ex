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
    Logger.info("⚡#{tool_icon(tool_name)} #{format_tool_call(tool_name, args)}")

    case DeepSeekHarness.Plugin.Loader.execute_tool(tool_name, args, :infinity) do
      {:ok, result} -> {:ok, format_output(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%__MODULE__{mode: :remote, remote_node: node}, tool_name, args)
      when not is_nil(node) do
    Logger.info("⚡[remote:#{node}]#{tool_icon(tool_name)} #{format_tool_call(tool_name, args)}")

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
    Logger.info(
      "⚡[docker:#{container}]#{tool_icon(tool_name)} #{format_tool_call(tool_name, args)}"
    )

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

  @icon_map %{
    "read_file" => "📖",
    "view_file" => "📖",
    "file_read" => "📖",
    "read_contents" => "📖",
    "get_file" => "📖",
    "write_file" => "📝",
    "write_to_file" => "📝",
    "replace_file_content" => "📝",
    "replace_file" => "📝",
    "edit_file" => "📝",
    "create_file" => "📝",
    "save_file" => "📝",
    "bash" => "🖥️",
    "cmd" => "🖥️",
    "run_command" => "🖥️",
    "shell" => "🖥️",
    "exec" => "🖥️",
    "execute_command" => "🖥️",
    "grep_search" => "🔍",
    "grep" => "🔍",
    "search_files" => "🔍",
    "file_search" => "🔍",
    "ripgrep" => "🔍",
    "search" => "🔍",
    "list_dir" => "📁",
    "ls" => "📁",
    "dir_list" => "📁",
    "list_directory" => "📁",
    "find_by_name" => "📁",
    "git" => "🌿",
    "git_status" => "🌿",
    "git_diff" => "🌿",
    "git_commit" => "🌿",
    "git_log" => "🌿",
    "http" => "🌐",
    "req" => "🌐",
    "fetch_url" => "🌐",
    "web_search" => "🌐",
    "read_url" => "🌐",
    "subagent" => "🤖",
    "spawn_subagent" => "🤖",
    "agent" => "🤖",
    "ask_question" => "❓",
    "ask" => "❓",
    "question" => "❓",
    "user_input" => "❓"
  }

  @doc "Returns an icon emoji for a known tool."
  def tool_icon(name) when is_binary(name) do
    cond do
      icon = Map.get(@icon_map, String.downcase(name)) -> icon
      String.starts_with?(name, "mcp_") or name == "ragex" -> "🔌"
      true -> "🛠️"
    end
  end

  def tool_icon(_), do: "🛠️"

  @doc "Formats a tool call into a user-friendly string: tool_name(key: val, ...)"
  def format_tool_call(tool_name, %{} = args) when map_size(args) == 0,
    do: "#{tool_name}()"

  def format_tool_call(tool_name, args) when is_map(args) do
    formatted_args =
      Enum.map_join(args, ", ", fn
        {k, v} when is_binary(k) -> "#{k}: #{format_arg_val(v)}"
        {k, v} -> "#{inspect(k)}: #{format_arg_val(v)}"
      end)

    "#{tool_name}(#{formatted_args})"
  end

  def format_tool_call(tool_name, args) do
    "#{tool_name}(#{inspect(args)})"
  end

  defp format_arg_val(val) when is_binary(val) do
    if String.contains?(val, "\n") or String.length(val) > 80 do
      trimmed = val |> String.slice(0, 60) |> String.replace("\n", "\\n")
      inspect(trimmed <> "…")
    else
      inspect(val)
    end
  end

  defp format_arg_val(val), do: inspect(val)

  defp format_output(output) when is_binary(output), do: output
  defp format_output(output), do: inspect(output, pretty: true)

  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
