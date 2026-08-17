defmodule DeepSeekHarness.CLI.LogFormatter do
  @moduledoc """
  Custom Erlang/Elixir Logger formatter producing clean, compact agy-style status lines.
  Formats log events with colored geometric circles (blue/yellow/red) without timestamp clutter.
  Suppresses noisy low-level socket transport chatter and handles raw mode CRLF formatting.
  """

  alias DeepSeekHarness.CLI.Spinner

  @noisy_patterns ~r/(\[HANDLER\]|\[ACCEPT LOOP\]|Client connected|Client disconnected|Waiting for data|Processing message|Sending response|Response sent)/i

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
        if String.starts_with?(formatted_msg, "⚡") do
          "#{formatted_msg}\r\n"
        else
          "#{circle} #{formatted_msg}\r\n"
        end

      if Spinner.active?() do
        current_spinner = Spinner.current_line()
        "\r\e[2K" <> base_line <> "\r" <> current_spinner
      else
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

  defp noisy_log?(msg) when is_binary(msg) do
    Regex.match?(@noisy_patterns, msg)
  end

  defp noisy_log?(_), do: false

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
