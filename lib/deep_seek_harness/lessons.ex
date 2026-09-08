defmodule DeepSeekHarness.Lessons do
  @moduledoc """
  Manages operational lessons learned (`project/lessons.md` or `.dsh/lessons.md`).

  Holds gotchas, debugging stories, runtime pitfalls, and architectural
  retrospectives so agents avoid repeating mistakes.
  """

  alias DeepSeekHarness.CLI.Formatter

  @doc """
  Returns the active lessons file path for `cwd`.
  Prefers `project/lessons.md` if `project/` directory exists or file exists;
  otherwise defaults to `.dsh/lessons.md`.
  """
  def lessons_file_path(cwd \\ ".") do
    project_lessons = Path.join(cwd, "project/lessons.md")
    dsh_lessons = Path.join(cwd, ".dsh/lessons.md")

    cond do
      File.exists?(project_lessons) ->
        project_lessons

      File.dir?(Path.join(cwd, "project")) ->
        project_lessons

      true ->
        dsh_lessons
    end
  end

  @doc """
  Loads the current lessons learned text.
  """
  def load_lessons(cwd \\ ".") do
    path = lessons_file_path(cwd)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, content, path}
        {:error, reason} -> {:error, "Failed to read lessons file: #{inspect(reason)}"}
      end
    else
      {:ok, "", path}
    end
  end

  @doc """
  Appends a lesson to `project/lessons.md`.
  """
  def append_lesson(lesson, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    path = lessons_file_path(cwd)

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")

    entry = """

    ### [#{timestamp}] Lesson
    #{String.trim(lesson)}
    """

    header_needed? = not File.exists?(path) or File.stat!(path).size == 0

    header =
      if header_needed? do
        "# Lessons Learned\n\nOperational gotchas, debugging findings, and architectural principles.\n"
      else
        ""
      end

    File.write!(path, header <> entry, [:append])
    {:ok, path}
  end

  @doc """
  Builds a prompt preamble string containing lessons learned for context injection.
  """
  def build_preamble(cwd \\ ".") do
    case load_lessons(cwd) do
      {:ok, content, _path} when is_binary(content) and byte_size(content) > 0 ->
        trimmed = String.trim(content)

        if trimmed != "" and not String.contains?(trimmed, "(No lessons recorded yet)") do
          """

          ### Project Lessons Learned & Gotchas (project/lessons.md)
          The following lessons were previously learned in this project. Adhere strictly to them to avoid regressions:

          #{trimmed}

          """
        else
          ""
        end

      _ ->
        ""
    end
  end

  @doc """
  Formats lessons for CLI rendering.
  """
  def format_lessons(content, path) do
    if String.trim(content) == "" do
      "#{Formatter.bold()}=== Lessons Learned (#{path}) ===#{Formatter.reset()}\n\n(No lessons recorded yet. Append lessons using `/lessons add <text>` or editing `#{path}`.)"
    else
      "#{Formatter.bold()}=== Lessons Learned (#{path}) ===#{Formatter.reset()}\n\n" <> content
    end
  end
end
