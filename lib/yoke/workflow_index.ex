defmodule Yoke.WorkflowIndex do
  @moduledoc """
  YAML Frontmatter parser and derived index generator for the Idea Lifecycle Pipeline.

  Manages stage directories (`thoughts/`, `backlog/`, `active/`, `completed/`, `rejected/`)
  and generates git-ignored `_MAP.md` (thought map summary) and `_DEPS.md` (dependency graph).
  """

  @stages ["thoughts", "backlog", "active", "completed", "rejected"]

  @type item :: %{
          stage: String.t(),
          slug: String.t(),
          filename: String.t(),
          path: String.t(),
          frontmatter: map(),
          body: String.t()
        }

  @doc """
  Ensures stage directory scaffolding exists under `cwd/project/workflow/` or `cwd/.yoke/workflow/`.
  """
  def ensure_scaffold(cwd \\ ".") do
    base_dir = workflow_dir(cwd)
    File.mkdir_p!(base_dir)

    Enum.each(@stages, fn stage ->
      File.mkdir_p!(Path.join(base_dir, stage))
    end)

    gitignore_path = Path.join(base_dir, ".gitignore")

    unless File.exists?(gitignore_path) do
      File.write!(gitignore_path, "# Derived workflow indexes - do not edit\n_MAP.md\n_DEPS.md\n")
    end

    base_dir
  end

  @doc """
  Returns base workflow directory.
  """
  def workflow_dir(cwd \\ ".") do
    project_wf = Path.join(cwd, "project/workflow")

    if File.dir?(Path.join(cwd, "project")) or File.dir?(project_wf) do
      project_wf
    else
      Path.join(cwd, ".yoke/workflow")
    end
  end

  @doc """
  Parses YAML frontmatter and body from a file content string.
  """
  def parse_frontmatter(content) when is_binary(content) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/s, content) do
      [_, yaml_str, body] ->
        frontmatter = parse_simple_yaml(yaml_str)
        {frontmatter, body}

      _ ->
        {%{}, content}
    end
  end

  @doc """
  Simple fallback YAML parser for frontmatter metadata.
  """
  def parse_simple_yaml(yaml_str) do
    yaml_str
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, current_key} ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, "#") ->
          {acc, current_key}

        # Multi-line block scalar start: key: |
        Regex.match?(~r/^(\w+):\s*\|$/, trimmed) ->
          [_, key] = Regex.run(~r/^(\w+):\s*\|$/, trimmed)
          {Map.put(acc, key, ""), key}

        # Continuation line for block scalar
        current_key != nil and String.starts_with?(line, "  ") ->
          val = Map.get(acc, current_key, "")
          new_val = if val == "", do: trimmed, else: val <> "\n" <> trimmed
          {Map.put(acc, current_key, new_val), current_key}

        # List line: - item
        Regex.match?(~r/^\s*-\s+(.+)$/, trimmed) ->
          if current_key do
            [_, item] = Regex.run(~r/^\s*-\s+(.+)$/, trimmed)
            existing = Map.get(acc, current_key, [])
            list = if is_list(existing), do: existing ++ [item], else: [item]
            {Map.put(acc, current_key, list), current_key}
          else
            {acc, nil}
          end

        # Key-value line: key: value or key: [a, b]
        Regex.match?(~r/^(\w+):\s*(.*)$/, trimmed) ->
          [_, key, raw_val] = Regex.run(~r/^(\w+):\s*(.*)$/, trimmed)
          val = parse_yaml_val(raw_val)
          {Map.put(acc, key, val), nil}

        true ->
          {acc, nil}
      end
    end)
    |> elem(0)
  end

  defp parse_yaml_val(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        ""

      String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
        len = String.length(trimmed)
        inner = if len > 2, do: String.slice(trimmed, 1, len - 2), else: ""

        inner
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      true ->
        trimmed
    end
  end

  @doc """
  Collects all workflow items across stages.
  """
  def scan_items(cwd \\ ".") do
    base_dir = ensure_scaffold(cwd)

    Enum.flat_map(@stages, fn stage ->
      stage_dir = Path.join(base_dir, stage)

      case File.ls(stage_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.reject(&String.starts_with?(&1, "_"))
          |> Enum.map(fn filename ->
            path = Path.join(stage_dir, filename)
            slug = derive_slug(filename)
            content = File.read!(path)
            {fm, body} = parse_frontmatter(content)

            %{
              stage: stage,
              slug: slug,
              filename: filename,
              path: path,
              frontmatter: fm,
              body: body
            }
          end)

        _ ->
          []
      end
    end)
  end

  @doc """
  Derives a bare slug from a filename (removes date prefix and .md extension).
  """
  def derive_slug(filename) do
    filename
    |> String.replace_prefix("", "")
    |> String.replace(~r/^\d{8}_?/, "")
    |> String.replace_suffix(".md", "")
  end

  @doc """
  Generates derived index files `_MAP.md` and `_DEPS.md` under `thoughts/`.
  """
  def generate_indexes(cwd \\ ".") do
    base_dir = ensure_scaffold(cwd)
    items = scan_items(cwd)

    thoughts_dir = Path.join(base_dir, "thoughts")
    File.mkdir_p!(thoughts_dir)

    map_path = Path.join(thoughts_dir, "_MAP.md")
    deps_path = Path.join(thoughts_dir, "_DEPS.md")

    map_content = render_map_index(items)
    deps_content = render_deps_index(items)

    File.write!(map_path, map_content)
    File.write!(deps_path, deps_content)

    {:ok, map_path, deps_path}
  end

  defp render_map_index(items) do
    header = """
    # Thought Map Summary (Generated)

    | Stage | Slug | Type | Priority | Summary |
    | :--- | :--- | :--- | :--- | :--- |
    """

    rows =
      Enum.map_join(items, "\n", fn item ->
        stage = item.stage
        slug = item.slug
        type = Map.get(item.frontmatter, "type", "code")
        priority = Map.get(item.frontmatter, "priority", "—")
        summary = Map.get(item.frontmatter, "summary", "No summary scalar provided.")

        single_line_summary =
          summary
          |> String.replace("\n", " ")
          |> String.trim()

        "| `#{stage}` | `#{slug}` | `#{type}` | `#{priority}` | #{single_line_summary} |"
      end)

    header <> rows <> "\n"
  end

  defp render_deps_index(items) do
    header = """
    # Thoughts & Tasks Dependency Graph (Generated)

    | Slug | Stage | Depends On | Required By |
    | :--- | :--- | :--- | :--- |
    """

    rows =
      Enum.map_join(items, "\n", fn item ->
        deps = Map.get(item.frontmatter, "depends_on", [])
        deps_list = if is_list(deps), do: deps, else: [deps]

        deps_str =
          if Enum.empty?(deps_list),
            do: "—",
            else: Enum.map_join(deps_list, ", ", &"`#{&1}`")

        required_by =
          items
          |> Enum.filter(fn other ->
            other_deps = Map.get(other.frontmatter, "depends_on", [])
            other_deps_list = if is_list(other_deps), do: other_deps, else: [other_deps]
            item.slug in other_deps_list
          end)
          |> Enum.map(&"`#{&1.slug}`")

        req_str = if Enum.empty?(required_by), do: "—", else: Enum.join(required_by, ", ")

        "| `#{item.slug}` | `#{item.stage}` | #{deps_str} | #{req_str} |"
      end)

    header <> rows <> "\n"
  end

  @doc """
  Audits thoughts and backlog items for integrity issues (missing summary, invalid stage required fields, broken dependencies).
  """
  def check_items(cwd \\ ".") do
    items = scan_items(cwd)
    all_slugs = MapSet.new(items, & &1.slug)

    errors =
      Enum.flat_map(items, fn item ->
        stage_errs =
          cond do
            item.stage == "thoughts" and Map.get(item.frontmatter, "summary", "") == "" ->
              ["[#{item.path}] Missing required frontmatter scalar `summary:`."]

            item.stage in ["backlog", "active"] and
                Map.get(item.frontmatter, "priority", "") == "" ->
              ["[#{item.path}] Missing required frontmatter field `priority:`."]

            true ->
              []
          end

        deps = Map.get(item.frontmatter, "depends_on", [])
        deps_list = if is_list(deps), do: deps, else: [deps]

        dep_errs =
          deps_list
          |> Enum.reject(&MapSet.member?(all_slugs, &1))
          |> Enum.map(fn missing ->
            "[#{item.path}] Unresolved dependency slug: `#{missing}`"
          end)

        stage_errs ++ dep_errs
      end)

    if Enum.empty?(errors) do
      {:ok, items}
    else
      {:error, errors}
    end
  end

  @doc """
  Creates a new raw thought file under `thoughts/`.
  """
  def create_thought(title, summary, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    base_dir = ensure_scaffold(cwd)

    date_prefix = Calendar.strftime(Date.utc_today(), "%Y%m%d")
    slug = title |> String.downcase() |> String.replace(~r/[^\w]+/, "_") |> String.trim("_")
    filename = "#{date_prefix}_#{slug}.md"
    path = Path.join([base_dir, "thoughts", filename])

    content = """
    ---
    type: code
    summary: |
      #{String.trim(summary)}
    ---

    # #{title}

    | Stage | Date |
    | :--- | :--- |
    | Thought | #{Date.utc_today()} |

    ## #{Date.utc_today()}: Initial thought

    #{summary}
    """

    File.write!(path, content)
    generate_indexes(cwd)
    {:ok, path, slug}
  end

  @doc """
  Promotes an item between stages (e.g. thoughts -> backlog).
  """
  def promote_item(slug, target_stage, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    items = scan_items(cwd)

    case Enum.find(items, &(&1.slug == slug)) do
      nil ->
        {:error, "No item found matching slug `#{slug}`."}

      item ->
        base_dir = ensure_scaffold(cwd)
        dest_dir = Path.join(base_dir, target_stage)

        filename =
          if target_stage == "completed" do
            today = Calendar.strftime(Date.utc_today(), "%Y%m%d")
            "#{today}_#{item.slug}.md"
          else
            item.filename
          end

        dest_path = Path.join(dest_dir, filename)

        priority =
          Keyword.get(opts, :priority, Map.get(item.frontmatter, "priority", "Should Have"))

        type = Keyword.get(opts, :type, Map.get(item.frontmatter, "type", "code"))

        # Update frontmatter with target requirements
        updated_fm =
          item.frontmatter
          |> Map.put("type", type)
          |> Map.put("priority", priority)

        # Write updated content to destination
        new_yaml = encode_yaml(updated_fm)
        new_content = "---\n#{new_yaml}---\n" <> item.body

        File.rm!(item.path)
        File.write!(dest_path, new_content)
        generate_indexes(cwd)

        {:ok, dest_path}
    end
  end

  @doc """
  Finds a backlog or active item matching `slug_or_prompt` and promotes it to `active/` if currently in `backlog/`.
  """
  def find_and_activate(slug_or_prompt, cwd \\ ".") do
    items = scan_items(cwd)
    query = String.downcase(slug_or_prompt)

    match =
      Enum.find(items, fn item ->
        item.slug == query or String.contains?(query, item.slug) or
          String.contains?(item.slug, query)
      end)

    case match do
      %{stage: "backlog"} = item ->
        {:ok, active_path} = promote_item(item.slug, "active", cwd: cwd)
        {:ok, %{item | stage: "active", path: active_path}}

      %{stage: "active"} = item ->
        {:ok, item}

      _ ->
        nil
    end
  end

  @doc """
  Closes out an active item, moving it to `completed/` and appending a close-out lesson entry to `project/lessons.md`.
  """
  def close_out_active(slug, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")

    case promote_item(slug, "completed", cwd: cwd) do
      {:ok, dest_path} ->
        lesson = "Completed workflow task `#{slug}`: verified tests & acceptance criteria."
        Yoke.Lessons.append_lesson(lesson, cwd: cwd)
        {:ok, dest_path}

      err ->
        err
    end
  end

  defp encode_yaml(map) do
    Enum.map_join(map, fn {k, v} ->
      cond do
        is_list(v) ->
          list_str = Enum.map_join(v, ", ", &to_string/1)
          "#{k}: [#{list_str}]\n"

        is_binary(v) and String.contains?(v, "\n") ->
          indented = v |> String.split("\n") |> Enum.map_join("\n", &"  #{&1}")
          "#{k}: |\n#{indented}\n"

        true ->
          "#{k}: #{v}\n"
      end
    end)
  end
end
