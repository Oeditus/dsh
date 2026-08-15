defmodule DeepSeekHarness.CLI.LineEditor do
  @moduledoc """
  2026 Modern TUI Line Editor & Readline Engine for DeepSeek Harness (DSH RAGE).
  Supports persistent history (~/.dsh/history), arrow key history navigation,
  Ctrl+R reverse-i-search, cursor manipulation, and configurable prompts.
  """
  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Config

  @history_file Path.expand("~/.dsh/history")

  @doc "Loads persistent history lines from ~/.dsh/history."
  def load_history do
    if File.exists?(@history_file) do
      @history_file
      |> File.read!()
      |> String.split("\n", trim: true)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Appends a new non-empty command line to persistent history."
  def add_history(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed != "" do
      File.mkdir_p!(Path.dirname(@history_file))
      File.write!(@history_file, "#{trimmed}\n", [:append])
    end
  rescue
    _ -> :ok
  end

  @doc "Formats a configurable prompt string using config template or default."
  def build_prompt(session_id, model, hands_mode \\ "local") do
    config = Config.load_config()
    template = Map.get(config, "prompt_format", "user@{session} [{model}]> ")

    template
    |> String.replace("{session}", session_id)
    |> String.replace("{model}", model)
    |> String.replace("{mode}", to_string(hands_mode))
  end

  @doc "Reads interactive input line with persistent history and key controls."
  def get_line(prompt_text, history \\ []) do
    if tty?() do
      read_tty_line(prompt_text, history)
    else
      IO.gets(prompt_text)
    end
  end

  defp tty? do
    case :io.columns() do
      {:ok, _} -> true
      _ -> false
    end
  end

  # TUI Interactive Line Reader
  defp read_tty_line(prompt_text, history) do
    # Set tty raw mode
    old_opts = set_raw_mode()

    initial_state = %{
      buffer: [],
      cursor: 0,
      history: history,
      hist_idx: -1,
      saved_buffer: [],
      prompt: prompt_text,
      search_mode: false,
      search_query: ""
    }

    try do
      result = raw_loop(initial_state)
      restore_tty_mode(old_opts)
      result
    catch
      _kind, _err ->
        restore_tty_mode(old_opts)
        IO.gets(prompt_text)
    end
  end

  defp set_raw_mode do
    case :io.getopts() do
      {:error, _} -> []
      opts ->
        :io.setopts(binary: true, echo: false)
        opts
    end
  end

  defp restore_tty_mode(old_opts) do
    if old_opts != [] do
      :io.setopts(old_opts)
    else
      :io.setopts(binary: false, echo: true)
    end
  end

  defp raw_loop(state) do
    render_prompt_and_buffer(state)

    case read_key() do
      :enter ->
        IO.write("\n")
        line = List.to_string(state.buffer)
        add_history(line)
        line <> "\n"

      :ctrl_c ->
        IO.write("^C\n")
        ""

      :ctrl_d ->
        if state.buffer == [] do
          :eof
        else
          raw_loop(state)
        end

      :up ->
        new_state = history_navigate(state, :up)
        raw_loop(new_state)

      :down ->
        new_state = history_navigate(state, :down)
        raw_loop(new_state)

      :left ->
        new_cursor = max(0, state.cursor - 1)
        raw_loop(%{state | cursor: new_cursor})

      :right ->
        new_cursor = min(length(state.buffer), state.cursor + 1)
        raw_loop(%{state | cursor: new_cursor})

      :home ->
        raw_loop(%{state | cursor: 0})

      :end ->
        raw_loop(%{state | cursor: length(state.buffer)})

      :backspace ->
        if state.cursor > 0 do
          {left, right} = Enum.split(state.buffer, state.cursor)
          new_left = Enum.drop(left, -1)
          raw_loop(%{state | buffer: new_left ++ right, cursor: state.cursor - 1})
        else
          raw_loop(state)
        end

      :ctrl_u ->
        raw_loop(%{state | buffer: [], cursor: 0})

      :ctrl_r ->
        new_state = toggle_reverse_search(state)
        raw_loop(new_state)

      {:char, char} ->
        {left, right} = Enum.split(state.buffer, state.cursor)
        new_buffer = left ++ [char] ++ right
        raw_loop(%{state | buffer: new_buffer, cursor: state.cursor + 1})

      _ ->
        raw_loop(state)
    end
  end

  defp render_prompt_and_buffer(state) do
    IO.write("\r\e[K")

    if state.search_mode do
      query = List.to_string(state.search_query)
      match = find_in_history(query, state.history)
      IO.write("(reverse-i-search)'#{query}': #{match}")
    else
      buf_str = List.to_string(state.buffer)
      prompt_str = Formatter.format_user_prompt_str(state.prompt)
      IO.write("#{prompt_str}#{buf_str}")

      # Reposition cursor
      tail_len = length(state.buffer) - state.cursor
      if tail_len > 0 do
        IO.write("\e[#{tail_len}D")
      end
    end
  end

  def history_navigate(state, :up) do
    if Enum.empty?(state.history) do
      state
    else
      new_idx = min(length(state.history) - 1, state.hist_idx + 1)
      saved = if state.hist_idx == -1, do: state.buffer, else: state.saved_buffer
      item = Enum.at(state.history, new_idx) || ""
      chars = String.to_charlist(item)
      %{state | buffer: chars, cursor: length(chars), hist_idx: new_idx, saved_buffer: saved}
    end
  end

  def history_navigate(state, :down) do
    case state.hist_idx do
      -1 ->
        state

      0 ->
        chars = state.saved_buffer
        %{state | buffer: chars, cursor: length(chars), hist_idx: -1}

      idx ->
        new_idx = idx - 1
        item = Enum.at(state.history, new_idx) || ""
        chars = String.to_charlist(item)
        %{state | buffer: chars, cursor: length(chars), hist_idx: new_idx}
    end
  end

  def toggle_reverse_search(state) do
    %{state | search_mode: not state.search_mode}
  end

  def find_in_history(query, history) do
    case Enum.find(history, fn item -> String.contains?(item, query) end) do
      nil -> ""
      match -> match
    end
  end

  defp read_key do
    case IO.getn("", 1) do
      "\n" -> :enter
      "\r" -> :enter
      "\x03" -> :ctrl_c
      "\x04" -> :ctrl_d
      "\x15" -> :ctrl_u
      "\x12" -> :ctrl_r
      "\x7f" -> :backspace
      "\x08" -> :backspace
      "\e" -> parse_escape_seq()
      char when is_binary(char) -> {:char, :binary.first(char)}
      _ -> :other
    end
  end

  defp parse_escape_seq do
    case IO.getn("", 1) do
      "[" ->
        case IO.getn("", 1) do
          "A" -> :up
          "B" -> :down
          "C" -> :right
          "D" -> :left
          "H" -> :home
          "F" -> :end
          "1" -> IO.getn("", 1); :home
          "4" -> IO.getn("", 1); :end
          _ -> :other
        end

      "O" ->
        case IO.getn("", 1) do
          "H" -> :home
          "F" -> :end
          _ -> :other
        end

      _ ->
        :escape
    end
  end
end
