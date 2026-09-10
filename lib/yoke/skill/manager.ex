defmodule Yoke.Skill.Manager do
  @moduledoc """
  Manages discovery and loading of skills.

  A *skill* is an instruction folder containing a `SKILL.md` file. Skills are
  discovered from three roots, in decreasing order of precedence:

    1. `./.yoke/skills/<name>/SKILL.md`              (scope `:project`)
    2. `./.gemini/antigravity-cli/builtin/skills/...` (scope `:builtin`)
    3. `~/.yoke/skills/<name>/SKILL.md`               (scope `:global`)

  When two roots define a skill with the same `name`, the higher-precedence
  root wins and the shadowed definition is recorded (see `discover_skills/1`
  and `shadowed/1`) so the CLI can warn about it.

  Discovery results are cached in a named ETS table keyed by the resolved root
  directories and their mtimes, so repeated `/skills` invocations do not
  re-stat the filesystem. Call `invalidate_cache/0` to force a rescan.
  """

  defstruct [
    :name,
    :description,
    :path,
    :content,
    :scope,
    :root,
    :error,
    :shadowed_by
  ]

  @type scope :: :project | :builtin | :global

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: String.t() | nil,
          content: String.t(),
          scope: scope() | nil,
          root: String.t() | nil,
          error: String.t() | nil,
          shadowed_by: String.t() | nil
        }

  @table :yoke_skill_cache

  # ---------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------

  @doc """
  Discovers all skills available in the local workspace, the bundled builtin
  directory, and the global user home.

  Results are de-duplicated by `name`, with earlier roots taking precedence.
  Skills whose `SKILL.md` fails to parse are still returned, but carry an
  `:error` field describing the problem (rather than being silently dropped).

  Pass `opts` to override behaviour:

    * `:cwd`  - workspace root (defaults to `"."`)
    * `:cache` - set to `false` to bypass the mtime cache
  """
  @spec discover_skills(keyword() | String.t()) :: [t()]
  def discover_skills(opts \\ [])

  def discover_skills(cwd) when is_binary(cwd), do: discover_skills(cwd: cwd)

  def discover_skills(opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, ".")
    use_cache? = Keyword.get(opts, :cache, true)

    roots = roots(cwd)

    if use_cache? do
      case cached(roots) do
        {:ok, skills} -> skills
        :miss -> load_and_cache(roots)
      end
    else
      load_roots(roots)
    end
  end

  @doc "Returns the list of `{scope, root_dir}` tuples that are searched, in precedence order."
  @spec roots(String.t()) :: [{scope(), String.t()}]
  def roots(cwd \\ ".") do
    [
      {:project, Path.join(cwd, ".yoke/skills")},
      {:builtin, Path.join(cwd, ".gemini/antigravity-cli/builtin/skills")},
      {:global, Path.expand("~/.yoke/skills")}
    ]
  end

  @doc "Clears the discovery cache, forcing the next `discover_skills/1` to rescan."
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc """
  Returns the names of skills that were discovered but shadowed by a
  higher-precedence definition, as `{name, winning_scope, losing_scope}` tuples.
  """
  @spec shadowed([t()]) :: [{String.t(), scope(), scope()}]
  def shadowed(skills) do
    skills
    |> Enum.filter(& &1.shadowed_by)
    |> Enum.map(fn s -> {s.name, s.shadowed_by, s.scope} end)
  end

  # ---------------------------------------------------------------------
  # Lookup / fuzzy matching
  # ---------------------------------------------------------------------

  @doc """
  Finds a skill by name using progressively looser matching: exact match,
  then case-insensitive match, then unique prefix match. Returns
  `{:ok, skill}` or `{:error, :not_found}`.
  """
  @spec find_skill([t()], String.t()) :: {:ok, t()} | {:error, :not_found}
  def find_skill(skills, name) do
    name = String.trim(name)

    cond do
      skill = Enum.find(skills, &(&1.name == name)) ->
        {:ok, skill}

      skill = Enum.find(skills, &(String.downcase(&1.name) == String.downcase(name))) ->
        {:ok, skill}

      true ->
        unique_prefix_match(skills, name)
    end
  end

  defp unique_prefix_match(skills, name) do
    case Enum.filter(skills, &String.starts_with?(&1.name, name)) do
      [skill] -> {:ok, skill}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns up to `limit` skill names closest to `name`, ranked by edit distance,
  for building a "did you mean ...?" suggestion.
  """
  @spec suggestions([t()], String.t(), pos_integer()) :: [String.t()]
  def suggestions(skills, name, limit \\ 3) do
    name = String.downcase(String.trim(name))

    skills
    |> Enum.map(& &1.name)
    |> Enum.map(fn candidate ->
      {candidate, levenshtein(String.downcase(candidate), name)}
    end)
    |> Enum.filter(fn {_candidate, dist} -> dist <= max(3, div(String.length(name), 2) + 1) end)
    |> Enum.sort_by(fn {_candidate, dist} -> dist end)
    |> Enum.take(limit)
    |> Enum.map(fn {candidate, _dist} -> candidate end)
  end

  # ---------------------------------------------------------------------
  # Rendering / scaffolding
  # ---------------------------------------------------------------------

  @doc """
  Renders a skill body for execution, substituting argument placeholders.

  Supported placeholders:

    * `{{arg}}` / `{{ args }}` - replaced by `args` (joined with spaces)
    * `$ARGUMENTS`             - replaced by `args`

  When `args` is empty, `{{arg}}`/`$ARGUMENTS` are replaced with an empty
  string.
  """
  @spec render(t(), String.t()) :: String.t()
  def render(%__MODULE__{content: content}, args \\ "") do
    args = String.trim(args || "")

    content
    |> String.replace(~r/\{\{\s*arg(?:uments)?\s*\}\}/, args)
    |> String.replace("$ARGUMENTS", args)
  end

  @doc """
  Scaffolds a new skill folder with a template `SKILL.md` under the given root.

  Returns `{:ok, path}` or `{:error, reason}`. Refuses to overwrite an
  existing skill file.
  """
  @spec scaffold(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def scaffold(name, root, opts \\ []) do
    description = Keyword.get(opts, :description, "TODO: describe when to use this skill")

    if name == "" or String.contains?(name, ["/", "\\", ".."]) do
      {:error, "Invalid skill name '#{name}'."}
    else
      dir = Path.join(root, name)
      path = Path.join(dir, "SKILL.md")

      if File.exists?(path) do
        {:error, "Skill '#{name}' already exists at #{path}."}
      else
        File.mkdir_p!(dir)
        File.write!(path, scaffold_template(name, description))
        {:ok, path}
      end
    end
  rescue
    e -> {:error, "Failed to scaffold skill '#{name}': #{Exception.message(e)}"}
  end

  defp scaffold_template(name, description) do
    """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{name}

    Describe the guidance, steps, or checks this skill should apply.

    1. First instruction.
    2. Second instruction.

    You may reference arguments passed on invocation with `{{arg}}` (or
    `$ARGUMENTS`).
    """
  end

  # ---------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------

  @doc "Parses a single SKILL.md file and extracts name, description, and markdown body."
  @spec parse_skill_file(String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_skill_file(path, fallback_name \\ "unnamed") do
    case File.read(path) do
      {:ok, raw_content} ->
        {meta, body} = extract_frontmatter(raw_content)

        name = meta["name"] || fallback_name
        desc = meta["description"] || "Skill loaded from #{path}"

        {:ok, %__MODULE__{name: name, description: desc, path: path, content: String.trim(body)}}

      {:error, reason} ->
        {:error, "Failed to read skill file #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Parses a `SKILL.md` file into a skill tagged with its `scope`/`root`.

  Unlike `parse_skill_file/2`, a malformed file yields a skill struct with the
  `:error` field populated (and the fallback name) rather than an error tuple,
  so it can still be surfaced in listings.
  """
  @spec parse_with_context(String.t(), String.t(), scope(), String.t()) :: t()
  def parse_with_context(path, fallback_name, scope, root) do
    case parse_skill_file(path, fallback_name) do
      {:ok, skill} ->
        %{skill | scope: scope, root: root}

      {:error, reason} ->
        %__MODULE__{
          name: fallback_name,
          description: "(unreadable skill)",
          path: path,
          content: "",
          scope: scope,
          root: root,
          error: reason
        }
    end
  end

  # ---------------------------------------------------------------------
  # Internal: caching
  # ---------------------------------------------------------------------

  defp load_and_cache(roots) do
    skills = load_roots(roots)
    put_cache(roots, skills)
    skills
  end

  defp load_roots(roots) do
    roots
    |> Enum.flat_map(fn {scope, dir} -> discover_skills_in_dir(dir, scope) end)
    |> dedupe_by_precedence()
  end

  # Keeps the first occurrence of each name (roots are already in precedence
  # order) and annotates later duplicates with the winning scope.
  defp dedupe_by_precedence(skills) do
    {kept, _seen} =
      Enum.reduce(skills, {[], MapSet.new()}, fn skill, acc ->
        {kept, seen} = acc

        if MapSet.member?(seen, skill.name) do
          {mark_shadowed(kept, skill), seen}
        else
          {kept ++ [skill], MapSet.put(seen, skill.name)}
        end
      end)

    kept
  end

  defp mark_shadowed(kept, shadowed) do
    Enum.map(kept, fn
      %{name: name} = s when name == shadowed.name -> %{s | shadowed_by: s.scope}
      s -> s
    end)
  end

  defp discover_skills_in_dir(base_dir, scope) do
    if File.dir?(base_dir) do
      case File.ls(base_dir) do
        {:ok, entries} -> Enum.flat_map(entries, &load_skill_entry(base_dir, &1, scope))
        _ -> []
      end
    else
      []
    end
  end

  defp load_skill_entry(base_dir, entry, scope) do
    skill_md = Path.join([base_dir, entry, "SKILL.md"])

    if File.exists?(skill_md) do
      [parse_with_context(skill_md, entry, scope, base_dir)]
    else
      []
    end
  end

  defp cached(roots) do
    ensure_table()

    key = cache_key(roots)

    case :ets.lookup(@table, key) do
      [{^key, skills}] -> {:ok, skills}
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  defp put_cache(roots, skills) do
    ensure_table()
    :ets.insert(@table, {cache_key(roots), skills})
    :ok
  rescue
    _ -> :ok
  end

  defp cache_key(roots) do
    roots
    |> Enum.map(fn {scope, dir} -> {scope, dir, dir_mtime(dir)} end)
    |> :erlang.term_to_binary()
  end

  defp dir_mtime(dir) do
    case File.stat(dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> :missing
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------
  # Internal: frontmatter parsing
  # ---------------------------------------------------------------------

  defp extract_frontmatter("---\n" <> rest) do
    case String.split(rest, ~r/^---\s*$/m, parts: 2) do
      [frontmatter, body] ->
        {parse_frontmatter(frontmatter), body}

      _ ->
        {%{}, rest}
    end
  end

  defp extract_frontmatter(content), do: {%{}, content}

  # A small, forgiving YAML-frontmatter parser: handles `key: value` pairs,
  # quoted values, and values containing colons. Nested structures are not
  # supported (skills only need flat string metadata).
  defp parse_frontmatter(yaml_str) do
    yaml_str
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" ->
          acc

        String.starts_with?(trimmed, "#") ->
          acc

        # Continuation of an indented block: ignore for flat metadata.
        line != trimmed and String.starts_with?(line, " ") ->
          acc

        true ->
          case String.split(trimmed, ":", parts: 2) do
            [key, val] -> Map.put(acc, String.trim(key), unquote_value(String.trim(val)))
            _ -> acc
          end
      end
    end)
  end

  defp unquote_value(<<q, rest::binary>>) when q in [?", ?'] do
    case String.split(rest, <<q>>, parts: 2) do
      [inner, _trailing] -> inner
      _ -> rest
    end
  end

  defp unquote_value(val), do: val

  # ---------------------------------------------------------------------
  # Internal: string distance
  # ---------------------------------------------------------------------

  defp levenshtein(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)

    Enum.reduce(a_chars, Enum.to_list(0..length(b_chars)), fn a_char, prev_row ->
      {row, _} =
        b_chars
        |> Enum.with_index(1)
        |> Enum.reduce({[hd(prev_row)], 0}, fn {b_char, j}, {row, _i} ->
          cost = if a_char == b_char, do: 0, else: 1
          left = hd(row) + 1
          up = Enum.at(prev_row, j) + 1
          diag = Enum.at(prev_row, j - 1) + cost
          {[min(min(left, up), diag) | row], j}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end
end
