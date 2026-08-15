defmodule DeepSeekHarness.Skill.Manager do
  @moduledoc """
  Manages discovery and loading of skills (instruction folders containing SKILL.md).
  """

  defstruct [:name, :description, :path, :content]

  @doc "Discovers all skills available in local workspace (.dsh/skills/*) and global user home (~/.dsh/skills/*)."
  def discover_skills(cwd \\ ".") do
    search_paths = [
      Path.join(cwd, ".dsh/skills"),
      Path.join(cwd, ".gemini/antigravity-cli/builtin/skills"),
      Path.expand("~/.dsh/skills")
    ]

    search_paths
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn base_dir ->
      case File.ls(base_dir) do
        {:ok, entries} ->
          Enum.flat_map(entries, fn entry ->
            skill_dir = Path.join(base_dir, entry)
            skill_md = Path.join(skill_dir, "SKILL.md")

            if File.exists?(skill_md) do
              case parse_skill_file(skill_md, entry) do
                {:ok, skill} -> [skill]
                _ -> []
              end
            else
              []
            end
          end)

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.name)
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
