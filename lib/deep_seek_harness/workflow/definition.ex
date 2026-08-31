defmodule DeepSeekHarness.Workflow.Definition do
  @moduledoc """
  Loads, validates, and discovers customizable DSH workflow definitions.

  A workflow definition is a small JSON document describing an ordered
  list of typed steps (`branch`, `task_description`, `task_split`,
  `tests_and_docs`, `lint`, `commit`, or a free-form `prompt` step for
  bespoke instructions) plus a few top-level settings. Definitions are
  discovered the same way `DeepSeekHarness.Skill.Manager` discovers
  skills -- a two-tier lookup (workspace `.dsh/workflows/definitions/`,
  then global `~/.dsh/workflows/definitions/`) -- plus a third,
  lowest-priority tier of definitions bundled with DSH itself (currently
  just `elixir`), which are materialized into the workspace tier on first
  use so they are immediately visible and editable, mirroring how
  `DeepSeekHarness.Rules` seeds `@default_rules` into `.dsh/rules.json`.
  """
  require Logger

  alias DeepSeekHarness.Rules
  alias DeepSeekHarness.Workflow.Json

  defstruct [
    :name,
    :description,
    :rules_scope,
    :base_branch_prefixes,
    :steps,
    :source
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          rules_scope: String.t(),
          base_branch_prefixes: [String.t()],
          steps: [map()],
          source: :workspace | :global | :bundled
        }

  # ---------------------------------------------------------------------
  # Bundled default workflows
  # ---------------------------------------------------------------------

  @bundled %{
    "elixir" => %{
      "name" => "elixir",
      "description" =>
        "Branch off main/master, summarize the task, propose a non-clashing split for parallel execution, then require tests + docs, lint, and a comprehensive commit for every change.",
      "rules_scope" => "elixir_workflow",
      "base_branch_prefixes" => ["main", "master"],
      "default_rules" => [
        "Follow idiomatic Elixir/OTP conventions enforced by oeditus_credo, propwise, and credo -- prefer pattern matching over conditionals, keep functions small and well-documented (@doc/@moduledoc), and avoid unnecessary intermediate variables."
      ],
      "steps" => [
        %{"type" => "branch", "branch_prefix" => "dsh/elixir"},
        %{"type" => "task_description"},
        %{"type" => "task_split"},
        %{"type" => "tests_and_docs"},
        %{"type" => "lint", "tools" => "all"},
        %{"type" => "commit"}
      ]
    }
  }

  @doc "Returns the names of workflows bundled with DSH itself."
  def bundled_names, do: Map.keys(@bundled)

  # ---------------------------------------------------------------------
  # Discovery paths
  # ---------------------------------------------------------------------

  @doc "Workspace-local directory holding user/custom workflow definitions."
  def definitions_dir(cwd \\ "."), do: Path.join(cwd, ".dsh/workflows/definitions")

  @doc "Global (cross-project) directory holding user/custom workflow definitions."
  def global_definitions_dir, do: Path.expand("~/.dsh/workflows/definitions")

  # ---------------------------------------------------------------------
  # Loading a single definition by name
  # ---------------------------------------------------------------------

  @doc """
  Loads a workflow definition by name, checking (in priority order) the
  workspace tier, the global tier, and finally the bundled defaults --
  materializing a bundled definition into the workspace tier the first
  time it's used, so it becomes an ordinary, inspectable, editable file.
  """
  def load(name, cwd \\ ".") when is_binary(name) do
    workspace_path = Path.join(definitions_dir(cwd), "#{name}.json")
    global_path = Path.join(global_definitions_dir(), "#{name}.json")

    cond do
      File.exists?(workspace_path) ->
        load_from_file(workspace_path, :workspace)

      File.exists?(global_path) ->
        load_from_file(global_path, :global)

      Map.has_key?(@bundled, name) ->
        materialize_bundled!(name, cwd)

      true ->
        {:error,
         "Unknown workflow '#{name}'. Available: #{Enum.join(list_names(cwd), ", ")}. Use `/workflow init #{name}` to create a custom one."}
    end
  end

  defp load_from_file(path, source) do
    with {:ok, content} <- File.read(path),
         {:ok, raw} <- Json.decode(content) do
      parse(raw, source)
    else
      {:error, reason} ->
        {:error, "Failed to load workflow definition '#{path}': #{inspect(reason)}"}
    end
  end

  defp materialize_bundled!(name, cwd) do
    raw = Map.fetch!(@bundled, name)
    dir = definitions_dir(cwd)
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}.json")

    persisted = Map.drop(raw, ["default_rules"])
    File.write!(path, Json.encode_pretty!(persisted))

    seed_default_rules(raw, cwd)

    Logger.info("[Workflow.Definition] Materialized bundled workflow '#{name}' to #{path}")
    parse(persisted, :bundled)
  end

  # Seeds each of a definition's `default_rules` under its `rules_scope`,
  # skipping any rule whose exact text is already present so re-running
  # `/workflow init` from the same template repeatedly never piles up
  # duplicate rules in `.dsh/rules.json`.
  defp seed_default_rules(%{"default_rules" => rule_texts, "rules_scope" => scope}, cwd)
       when is_list(rule_texts) do
    existing = Rules.load_rules(cwd)

    Enum.each(rule_texts, fn text ->
      already_present? =
        Enum.any?(existing, fn r -> r["scope"] == scope and r["text"] == text end)

      unless already_present? do
        Rules.add_scoped_rule(scope, text, cwd)
      end
    end)
  end

  defp seed_default_rules(_raw, _cwd), do: :ok

  # ---------------------------------------------------------------------
  # Parsing & validation
  # ---------------------------------------------------------------------

  @doc "Validates and parses a raw (string-keyed map) workflow spec into a `%Definition{}`."
  def parse(raw, source \\ :workspace)

  def parse(%{"name" => name, "steps" => steps} = raw, source)
      when is_binary(name) and is_list(steps) do
    with :ok <- validate_steps(steps) do
      {:ok,
       %__MODULE__{
         name: name,
         description: Map.get(raw, "description", ""),
         rules_scope: Map.get(raw, "rules_scope", "all"),
         base_branch_prefixes: Map.get(raw, "base_branch_prefixes", ["main", "master"]),
         steps: steps,
         source: source
       }}
    end
  end

  def parse(_raw, _source) do
    {:error,
     "Invalid workflow definition: expected a JSON object with a string \"name\" and a \"steps\" array."}
  end

  defp validate_steps([]), do: {:error, "Workflow definition must declare at least one step."}

  defp validate_steps(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%{"type" => type}, _idx}, :ok when is_binary(type) ->
        {:cont, :ok}

      {other, idx}, :ok ->
        {:halt, {:error, "Step ##{idx + 1} is missing a string \"type\": #{inspect(other)}"}}
    end)
  end

  # ---------------------------------------------------------------------
  # Listing / scaffolding
  # ---------------------------------------------------------------------

  @doc """
  Lists every discoverable workflow name across all three tiers
  (workspace, global, bundled), deduplicated with workspace taking
  priority over global, and global over bundled.
  """
  def list_names(cwd \\ ".") do
    workspace = list_json_basenames(definitions_dir(cwd))
    global = list_json_basenames(global_definitions_dir())

    (workspace ++ global ++ bundled_names())
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Lists full metadata (name, description, source tier) for every discoverable workflow."
  def list(cwd \\ ".") do
    cwd
    |> list_names()
    |> Enum.map(fn name ->
      case load(name, cwd) do
        {:ok, %__MODULE__{} = def_} ->
          %{name: def_.name, description: def_.description, source: def_.source}

        {:error, _reason} ->
          %{name: name, description: "(failed to load)", source: :unknown}
      end
    end)
  end

  defp list_json_basenames(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.replace_suffix(&1, ".json", ""))

      _ ->
        []
    end
  end

  @doc """
  Scaffolds a new custom workflow definition named `name` into the
  workspace tier, seeded from `template` (default: `"elixir"`). Fails if
  a workspace definition with that name already exists, so this never
  silently clobbers a hand-edited file.
  """
  def init(name, template \\ "elixir", cwd \\ ".") when is_binary(name) do
    target_path = Path.join(definitions_dir(cwd), "#{name}.json")

    cond do
      File.exists?(target_path) ->
        {:error, "Workflow '#{name}' already exists at #{target_path}."}

      not Map.has_key?(@bundled, template) ->
        {:error,
         "Unknown template '#{template}'. Available templates: #{Enum.join(bundled_names(), ", ")}."}

      true ->
        raw = @bundled |> Map.fetch!(template) |> Map.put("name", name)
        File.mkdir_p!(definitions_dir(cwd))
        File.write!(target_path, Json.encode_pretty!(Map.drop(raw, ["default_rules"])))
        seed_default_rules(raw, cwd)
        {:ok, target_path}
    end
  end
end
