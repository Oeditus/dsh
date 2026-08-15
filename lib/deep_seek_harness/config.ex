defmodule DeepSeekHarness.Config do
  @moduledoc """
  Manages persistent configuration (~/.dsh/config.json) and project rules (.dshrules, .dsh/rules.md).
  """

  @default_config %{
    "model" => "deepseek-chat",
    # "auto_approve" | "ask_confirm"
    "permission_mode" => "ask_confirm",
    "temperature" => 0.7,
    "system_prompt_addon" => "",
    "mcp_servers" => %{}
  }

  @doc "Loads combined configuration (global + workspace override)."
  def load_config(cwd \\ ".") do
    global_path = Path.expand("~/.dsh/config.json")
    local_path = Path.join(cwd, ".dsh/config.json")

    global_cfg = read_json_config(global_path)
    local_cfg = read_json_config(local_path)

    Map.merge(@default_config, Map.merge(global_cfg, local_cfg))
  end

  @doc "Discovers project rule files (.dshrules, .dsh/rules.md, AGYRULES) in current workspace."
  def discover_project_rules(cwd \\ ".") do
    rule_files = [
      Path.join(cwd, ".dshrules"),
      Path.join(cwd, ".dsh/rules.md"),
      Path.join(cwd, ".dsh/SYSTEM.md"),
      Path.join(cwd, "AGYRULES")
    ]

    rule_files
    |> Enum.filter(&File.exists?/1)
    |> Enum.map_join("\n", fn path ->
      case File.read(path) do
        {:ok, content} -> "=== Project Rule (#{Path.basename(path)}) ===\n#{content}\n"
        _ -> ""
      end
    end)
  end

  def save_global_config(new_config) do
    global_path = Path.expand("~/.dsh/config.json")

    with :ok <- global_path |> Path.dirname() |> File.mkdir_p(),
         {:ok, json} <- Jason.encode(new_config, pretty: true),
         :ok <- File.write(global_path, json) do
      {:ok, global_path}
    else
      err -> {:error, "Failed to save config to #{global_path}: #{inspect(err)}"}
    end
  end

  @doc "Saves workspace local configuration file (.dsh/config.json)."
  def save_config(config, cwd \\ ".") do
    local_path = Path.join(cwd, ".dsh/config.json")

    with :ok <- local_path |> Path.dirname() |> File.mkdir_p(),
         {:ok, json} <- Jason.encode(config, pretty: true),
         :ok <- File.write(local_path, json) do
      :ok
    else
      err -> {:error, "Failed to save local config: #{inspect(err)}"}
    end
  end

  defp read_json_config(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end
end
