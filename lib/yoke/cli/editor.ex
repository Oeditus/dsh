defmodule Yoke.CLI.Editor do
  @moduledoc """
  Unified helper module for launching system text editors ($EDITOR / $VISUAL).
  Provides helpers to edit text buffer strings or files in the user's preferred editor
  while handling TTY mode toggles smoothly.
  """

  alias Yoke.CLI.Formatter

  @doc """
  Returns the editor executable name specified by $EDITOR or $VISUAL,
  or `default` (defaults to nil unless explicit fallback provided).
  """
  def get_editor(default \\ nil) do
    System.get_env("EDITOR") || System.get_env("VISUAL") || default
  end

  @doc "Returns true if an editor ($EDITOR or $VISUAL) is set in the environment."
  def editor_set? do
    get_editor() != nil
  end

  @doc """
  Edits the given `initial_text` in $EDITOR.
  If $EDITOR is set and available, creates a temporary file, opens the editor,
  and returns `{:ok, updated_text}` after saving.
  If $EDITOR is not set, returns `{:fallback, initial_text}`.

  Options:
    - `:on_before` - Zero-arity function called before launching editor (e.g. restoring TTY mode).
    - `:on_after` - Zero-arity function called after editor closes (e.g. setting raw mode).
    - `:ext` - Temporary file extension (default: ".txt").
    - `:fallback` - Default editor if $EDITOR is unset (e.g. "nano" or "vi").
  """
  def edit_text(initial_text, opts \\ []) do
    editor = get_editor(opts[:fallback])

    if editor && executable_exists?(editor) do
      ext = opts[:ext] || ".txt"

      tmp_file =
        Path.join(System.tmp_dir!(), "yoke_edit_#{System.unique_integer([:positive])}#{ext}")

      File.write!(tmp_file, initial_text || "")

      on_before = opts[:on_before]
      on_after = opts[:on_after]

      if is_function(on_before, 0), do: on_before.()

      result =
        try do
          case System.cmd(editor, [tmp_file], into: IO.stream(:stdio, :line)) do
            {_, 0} ->
              updated = File.read!(tmp_file) |> String.trim()
              {:ok, updated}

            {_, code} ->
              {:error, "Editor exited with status code #{code}"}
          end
        rescue
          e -> {:error, "Failed to run editor '#{editor}': #{Exception.message(e)}"}
        after
          File.rm(tmp_file)
          if is_function(on_after, 0), do: on_after.()
        end

      result
    else
      {:fallback, initial_text}
    end
  end

  @doc """
  Opens the file at `file_path` in $EDITOR (or fallback editor).
  """
  def edit_file(file_path, opts \\ []) do
    editor = get_editor(opts[:fallback] || "nano")

    if executable_exists?(editor) do
      on_before = opts[:on_before]
      on_after = opts[:on_after]

      if is_function(on_before, 0), do: on_before.()

      IO.puts(Formatter.format_info("Opening #{file_path} in #{editor}…"))

      try do
        case System.cmd(editor, [file_path], into: IO.stream(:stdio, :line)) do
          {_, 0} ->
            IO.puts(Formatter.format_success("Closed #{Path.basename(file_path)}."))
            {:ok, file_path}

          {_, code} ->
            IO.puts(Formatter.format_error("Editor exited with status #{code}."))
            {:error, "Exit code #{code}"}
        end
      rescue
        e ->
          IO.puts(
            Formatter.format_error("Failed to run editor '#{editor}': #{Exception.message(e)}")
          )

          {:error, Exception.message(e)}
      after
        if is_function(on_after, 0), do: on_after.()
      end
    else
      IO.puts(
        Formatter.format_error(
          "No $EDITOR executable ('#{editor}') found. Please edit #{file_path} directly."
        )
      )

      {:error, :no_editor}
    end
  end

  defp executable_exists?(cmd) when is_binary(cmd) do
    binary = cmd |> String.split() |> List.first()
    System.find_executable(binary) != nil
  end

  defp executable_exists?(_), do: false
end
