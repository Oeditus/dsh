defmodule DeepSeekHarness.Scrap do
  @moduledoc """
  Manages transient scratch notes (`project/scrap.md` or `.dsh/scrap.md`).

  Used to capture unfiled thoughts, notes, and raw ideas mid-flow
  without interrupting agent velocity or context focus.
  """

  alias DeepSeekHarness.CLI.Formatter

  @doc """
  Returns the active scrap file path for `cwd`.
  Prefers `project/scrap.md` if `project/` directory exists or file exists;
  otherwise defaults to `.dsh/scrap.md`.
  """
  def scrap_file_path(cwd \\ ".") do
    project_scrap = Path.join(cwd, "project/scrap.md")
    dsh_scrap = Path.join(cwd, ".dsh/scrap.md")

    cond do
      File.exists?(project_scrap) ->
        project_scrap

      File.dir?(Path.join(cwd, "project")) ->
        project_scrap

      true ->
        dsh_scrap
    end
  end

  @doc """
  Appends a timestamped note to the scrap file.
  """
  def append_note(note, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    path = scrap_file_path(cwd)

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M")
    entry = "- [#{timestamp}] #{String.trim(note)}\n"

    header_needed? = not File.exists?(path) or File.stat!(path).size == 0

    header =
      if header_needed? do
        "# Scrap Notes\n\nTransient unfiled notes caught mid-flow. Triage with `/process-scrap`.\n\n"
      else
        ""
      end

    File.write!(path, header <> entry, [:append])
    {:ok, path}
  end

  @doc """
  Reads the current scrap notes.
  """
  def read_scrap(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    path = scrap_file_path(cwd)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, content, path}
        {:error, reason} -> {:error, "Failed to read scrap file #{path}: #{inspect(reason)}"}
      end
    else
      {:ok, "# Scrap Notes\n\n(No scrap notes recorded yet.)", path}
    end
  end

  @doc """
  Clears the scrap notes file.
  """
  def clear_scrap(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    path = scrap_file_path(cwd)

    if File.exists?(path) do
      File.rm!(path)
    end

    :ok
  end

  @doc """
  Formats scrap notes for CLI rendering.
  """
  def format_scrap(content, path) do
    "#{Formatter.bold()}=== Scrap Notes (#{path}) ===#{Formatter.reset()}\n\n" <> content
  end
end
