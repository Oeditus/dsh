defmodule DeepSeekHarness.Skill.Manager do
  @moduledoc """
  Manages discovery and loading of skills (instruction folders containing SKILL.md).
  """

  defstruct [:name, :description, :path, :content]

  @doc "Discovers all skills available in local workspace (.dsh/skills/*) and global user home (~/.dsh/skills/*)."
  def discover_skills(cwd \\ ".") do
    [
      Path.join(cwd, ".dsh/skills"),
      Path.join(cwd, ".gemini/antigravity-cli/builtin/skills"),
      Path.expand("~/.dsh/skills")
    ]
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&discover_skills_in_dir/1)
    |> Enum.uniq_by(& &1.name)
  end

  defp discover_skills_in_dir(base_dir) do
    case File.ls(base_dir) do
      {:ok, entries} -> Enum.flat_map(entries, &load_skill_entry(base_dir, &1))
      _ -> []
    end
  end

  defp load_skill_entry(base_dir, entry) do
    skill_md = Path.join([base_dir, entry, "SKILL.md"])

    if File.exists?(skill_md) do
      case parse_skill_file(skill_md, entry) do
        {:ok, skill} -> [skill]
        _ -> []
      end
    else
      []
    end
  end

  @doc "Parses a single SKILL.md file and extracts name, description, and markdown body."
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

  defp extract_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [frontmatter, body] ->
        parsed = parse_simple_yaml(frontmatter)
        {parsed, body}

      _ ->
        {%{}, rest}
    end
  end

  defp extract_frontmatter(content), do: {%{}, content}

  defp parse_simple_yaml(yaml_str) do
    yaml_str
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, val] -> Map.put(acc, String.trim(key), String.trim(val))
        _ -> acc
      end
    end)
  end
end
