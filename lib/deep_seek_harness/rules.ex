defmodule DeepSeekHarness.Rules do
  @moduledoc """
  Rule Engine for DeepSeek Harness.
  Manages persistent scoped prompt preamble rules (all, cr, commit, etc.).
  """
  require Logger

  @default_rules [
    %{
      "id" => 1,
      "scope" => "all",
      "text" => "typographic quotes “” mean the exact quote",
      "enabled" => true
    },
    %{
      "id" => 2,
      "scope" => "all",
      "text" => "backticks mean a code quote",
      "enabled" => true
    },
    %{
      "id" => 3,
      "scope" => "cr",
      "text" => "format table cells multiline to fit in 80 symbols width",
      "enabled" => true
    }
  ]

  @doc "Returns the path to local project rules JSON file."
  def rules_file_path(cwd \\ ".") do
    Path.join([cwd, ".dsh", "rules.json"])
  end

  @doc "Loads rules from disk, initializing defaults if rules.json does not exist."
  def load_rules(cwd \\ ".") do
    file_path = rules_file_path(cwd)

    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, rules} when is_list(rules) -> rules
            _ -> @default_rules
          end

        _ ->
          @default_rules
      end
    else
      save_rules(@default_rules, cwd)
      @default_rules
    end
  end

  @doc "Saves rules to local .dsh/rules.json file."
  def save_rules(rules, cwd \\ ".") when is_list(rules) do
    file_path = rules_file_path(cwd)
    file_path |> Path.dirname() |> File.mkdir_p!()

    case Jason.encode(rules, pretty: true) do
      {:ok, json} ->
        File.write(file_path, json)
        {:ok, file_path}

      {:error, err} ->
        Logger.warning("[Rules] Failed to encode rules: #{inspect(err)}")
        {:error, err}
    end
  end

  @doc "Parses and adds a new rule string like 'all: text' or 'cr: text' or 'text'."
  def add_rule(raw_input, cwd \\ ".") when is_binary(raw_input) do
    input = String.trim(raw_input)

    {scope, text} =
      case String.split(input, ":", parts: 2) do
        [s, t] when s in ["all", "cr", "review", "commit", "refactor", "test"] ->
          {String.trim(s), String.trim(t)}

        _ ->
          {"all", input}
      end

    if text == "" do
      {:error, "Rule text cannot be empty."}
    else
      rules = load_rules(cwd)
      max_id = Enum.map(rules, &Map.get(&1, "id", 0)) |> Enum.max(fn -> 0 end)

      new_rule = %{
        "id" => max_id + 1,
        "scope" => scope,
        "text" => text,
        "enabled" => true
      }

      updated_rules = rules ++ [new_rule]
      save_rules(updated_rules, cwd)
      {:ok, new_rule}
    end
  end

  @doc "Deletes rules matching given ID array."
  def delete_rules(ids, cwd \\ ".") when is_list(ids) do
    rules = load_rules(cwd)
    id_set = MapSet.new(Enum.map(ids, &to_integer/1))

    updated = Enum.reject(rules, fn r -> MapSet.member?(id_set, Map.get(r, "id")) end)
    save_rules(updated, cwd)
    {:ok, updated}
  end

  @doc "Toggles rule enabled status by ID."
  def toggle_rule(id, cwd \\ ".") do
    target_id = to_integer(id)
    rules = load_rules(cwd)

    updated =
      Enum.map(rules, fn r ->
        if Map.get(r, "id") == target_id do
          Map.put(r, "enabled", not Map.get(r, "enabled", true))
        else
          r
        end
      end)

    save_rules(updated, cwd)
    {:ok, updated}
  end

  @doc "Builds prompt preamble text for a given command context (e.g. 'cr', 'all', or nil)."
  def build_preamble(cmd_context \\ nil, cwd \\ ".") do
    rules = load_rules(cwd)
    ctx = if cmd_context, do: to_string(cmd_context), else: nil

    applicable =
      Enum.filter(rules, fn r ->
        Map.get(r, "enabled", true) and
          (Map.get(r, "scope") == "all" or Map.get(r, "scope") == ctx)
      end)

    if Enum.empty?(applicable) do
      ""
    else
      rule_lines =
        Enum.map_join(applicable, "\n", fn r ->
          "- #{Map.get(r, "text")}"
        end)

      "=== Prompt & Execution Rules ===\n#{rule_lines}\n===============================\n\n"
    end
  end

  defp to_integer(i) when is_integer(i), do: i

  defp to_integer(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {num, _} -> num
      _ -> 0
    end
  end

  defp to_integer(_), do: 0
end
