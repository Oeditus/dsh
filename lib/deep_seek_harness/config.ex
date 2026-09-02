defmodule DeepSeekHarness.Config do
  @moduledoc """
  Manages persistent configuration (~/.dsh/config.json) and project rules (.dshrules, .dsh/rules.md).
  """

  @default_config %{
    "model" => "deepseek-chat",
    # "auto_approve" | "ask_confirm"
    "permission_mode" => "ask_confirm",
    # Per-tool overrides: e.g. %{"bash" => "confirm", "read_file" => "allow"}
    "tool_permissions" => %{},
    "sandbox_workspace" => false,
    "temperature" => 0.7,
    "system_prompt_addon" => "",
    "mcp_servers" => %{},
    "prompt_style" => "starship",
    "enable_autosuggestions" => true,
    "enable_syntax_highlighting" => true,
    "enable_context_gauge" => true,
    "enable_file_picker" => true,
    "enable_code_highlighting" => true,
    # Switches the idle status bar's toggleable segment from the token/cost
    # gauge to a compact "id + message count" line (toggle: Ctrl+B or
    # `/config toggle compact_status_bar`).
    "compact_status_bar" => false,
    # Assumed model context window size (tokens) used by the status bar's
    # usage gauge. Override per-workspace if DeepSeek's limits change.
    "max_context_tokens" => 64_000,
    # Model pricing, expressed as USD per 1,000,000 tokens, used to compute
    # the estimated session cost shown by the status bar gauge, /cost, and
    # /stats. Defaults to DeepSeek's published V3 rates (prompt $0.14/1M,
    # completion $0.28/1M). Override globally in ~/.dsh/config.json (or per
    # workspace in .dsh/config.json) when you use a different model/provider
    # (e.g. deepseek-reasoner or an OpenRouter/SiliconFlow route) so the
    # reported cost reflects your actual per-million price.
    "price_per_million_prompt_tokens" => 0.14,
    "price_per_million_completion_tokens" => 0.28,
    # Maximum number of consecutive tool-calling turns a single agent loop
    # will run before pausing to ask the user whether to continue. Override
    # per-workspace (or globally) by adding "max_tool_depth": <n> to
    # .dsh/config.json (or ~/.dsh/config.json).
    "max_tool_depth" => 100
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

  @doc "Persists a per-tool permission policy override in local workspace config (.dsh/config.json)."
  def set_tool_permission(tool_name, policy, cwd \\ ".") do
    current_cfg = load_config(cwd)
    perms = Map.get(current_cfg, "tool_permissions", %{})
    updated_perms = Map.put(perms, tool_name, policy)
    updated_cfg = Map.put(current_cfg, "tool_permissions", updated_perms)
    save_config(updated_cfg, cwd)
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
