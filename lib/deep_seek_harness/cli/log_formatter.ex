defmodule DeepSeekHarness.CLI.LogFormatter do
  @moduledoc """
  Custom Erlang/Elixir Logger formatter producing clean, compact agy-style status lines.
  Formats log events with colored geometric circles (blue/yellow/red) without timestamp clutter.
  Suppresses noisy low-level socket transport chatter and handles raw mode CRLF formatting.
  """

  alias DeepSeekHarness.CLI.LineEditor
  alias DeepSeekHarness.CLI.Spinner
  alias DeepSeekHarness.CLI.TerminalOwner

  @noisy_patterns ~r/(\[HANDLER\]|\[ACCEPT LOOP\]|Client connected|Client disconnected|Client connection|connection timeout|Waiting for data|Processing message|Sending response|Response sent|AI Cache)/i

  @doc "Formats Erlang/Elixir log events into agy-style single lines."
  def format(%{level: level, msg: msg}, _config) do
    formatted_msg = format_message(msg) |> String.trim()

    if noisy_log?(formatted_msg) do
      ""
    else
      circle =
        case level do
          :error -> IO.ANSI.red() <> "●" <> IO.ANSI.reset()
          :warning -> IO.ANSI.yellow() <> "●" <> IO.ANSI.reset()
          :warn -> IO.ANSI.yellow() <> "●" <> IO.ANSI.reset()
          :info -> IO.ANSI.blue() <> "●" <> IO.ANSI.reset()
          :debug -> IO.ANSI.blue() <> "●" <> IO.ANSI.reset()
          _ -> IO.ANSI.blue() <> "●" <> IO.ANSI.reset()
        end

      base_line =
        if String.starts_with?(formatted_msg, "\e") or String.starts_with?(formatted_msg, "●") or
             String.starts_with?(formatted_msg, "⚡") or String.starts_with?(formatted_msg, "󱐋") do
          "#{formatted_msg}\r\n"
        else
          "#{circle} #{formatted_msg}\r\n"
        end
        |> truncate_to_terminal()

      cond do
        # Spinner is running its own periodic single-line redraw right now --
        # clear that line, print the log, then restore the spinner frame.
        # `paused?` matters because the spinner process stays "active" (i.e.
        # alive) while paused (see `Spinner.with_paused/1`, used by every
        # `QuestionPrompt` call site), but during that window it isn't the
        # thing occupying the terminal -- treating it as if it were would
        # clear/redraw only one line of a multi-line question modal instead.
        Spinner.active?() and not Spinner.paused?() ->
          current_spinner = Spinner.current_line()
          "\r\e[2K" <> base_line <> "\r" <> current_spinner

        # A registered CLI surface (idle prompt, question modal) owns the
        # terminal right now -- erase it, print the log line above it, then
        # have it redraw itself intact. This does the actual terminal I/O
        # itself (since redrawing a surface is more than returning a
        # string), so the formatter contract is satisfied by returning "".
        TerminalOwner.active?() ->
          TerminalOwner.interject(base_line)
          ""

        true ->
          base_line
      end
    end
  rescue
    _ -> ""
  end

  @doc "Installs the custom LogFormatter on standard Erlang/Elixir logger handler."
  def install do
    :logger.set_handler_config(:default, :formatter, {__MODULE__, %{}})
  rescue
    _ -> :error
  end

  # A tool-call preview line (e.g. a `bash` command echoing a long shell
  # pipeline) or any other verbose log message can easily exceed the
  # terminal width, wrapping onto extra rows and desyncing the row-count
  # bookkeeping every `TerminalOwner`-registered surface relies on to
  # erase/redraw itself correctly. Truncate each visual line of the
  # message to `terminal width - 2` columns, appending an ellipsis only
  # when a line actually got cut, so a long line always fits on-screen
  # without corrupting whatever redraws around it.
  defp truncate_to_terminal(line) do
    content = String.trim_trailing(line, "\r\n")
    budget = max(terminal_cols() - 2, 1)

    content
    |> String.split("\n")
    |> Enum.map_join("\n", &LineEditor.truncate_to_width(&1, budget))
    |> Kernel.<>("\r\n")
  end

  defp terminal_cols do
    case :io.columns() do
      {:ok, c} when is_integer(c) and c > 10 -> c
      _ -> 120
    end
  end

  defp noisy_log?(msg) when is_binary(msg) do
    Regex.match?(@noisy_patterns, msg)
  end

  defp format_message({:string, chardata}), do: to_string(chardata)
  defp format_message({:report, report}), do: inspect(report)

  defp format_message({format, args}) when is_list(format) or is_binary(format) do
    :io_lib.format(format, args) |> to_string()
  rescue
    _ -> inspect({format, args})
  end

  defp format_message(msg) when is_binary(msg), do: msg
  defp format_message(msg), do: inspect(msg)
end
