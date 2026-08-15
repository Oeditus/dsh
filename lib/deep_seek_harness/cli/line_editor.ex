defmodule DeepSeekHarness.CLI.LineEditor do
  @moduledoc """
  2026 Modern TUI Line Editor & Readline Engine for DeepSeek Harness (DSH RAGE).
  Features:
    - Real-time raw TTY key handling via stty raw -echo < /dev/tty
    - Up / Down Arrow history navigation through ~/.dsh/history
    - Left / Right Arrow cursor positioning
    - Ctrl+R Reverse-i-Search history matching
    - Emacs & Vim keybindings (Ctrl+A, Ctrl+E, Ctrl+K, Ctrl+W, Ctrl+U, Ctrl+L)
    - Tab auto-completion for slash commands
    - Configurable prompt templates
  """
  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Config

  @history_file Path.expand("~/.dsh/history")

  @slash_commands [
    "/help",
    "/mcp",
    "/mcp list",
    "/mcp load",
    "/mcp add ",
    "/ragex",
    "/plugins",
    "/plugins reload",
    "/skills",
    "/skill ",
    "/compact",
    "/diff",
    "/review",
    "/commit ",
    "/cost",
    "/permissions auto",
    "/permissions ask",
    "/subagent ",
    "/checkpoint",
    "/undo",
    "/session",
    "/nodes",
    "/clear",
    "/exit",
    "/quit"
  ]

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

  @doc "Reads interactive input line with persistent history and TUI key controls."
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

  # TUI Interactive Line Reader with stty raw mode targeting /dev/tty
  defp read_tty_line(prompt_text, history) do
    set_raw_mode()

    initial_state = %{
      buffer: [],
      cursor: 0,
      history: history,
      hist_idx: -1,
      saved_buffer: [],
      prompt: prompt_text,
      search_mode: false,
      search_query: []
    }

    try do
      result = raw_loop(initial_state)
      restore_tty_mode()
      result
    catch
      _kind, _err ->
        restore_tty_mode()
        IO.gets(prompt_text)
    end
  end

  defp set_raw_mode do
    System.cmd("sh", ["-c", "stty raw -echo < /dev/tty"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    System.cmd("sh", ["-c", "stty sane < /dev/tty"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp raw_loop(state) do
    render_prompt_and_buffer(state)

    case read_key() do
      :enter ->
        if state.search_mode do
          match = find_in_history(List.to_string(state.search_query), state.history)
          chars = String.to_charlist(match)
          raw_loop(%{state | buffer: chars, cursor: length(chars), search_mode: false})
        else
          IO.write("\r\n")
          line = List.to_string(state.buffer)
          add_history(line)
          line <> "\n"
        end

      :tab ->
        buf_str = List.to_string(state.buffer)
        case tab_complete(buf_str) do
          {:ok, completed} ->
            chars = String.to_charlist(completed)
            raw_loop(%{state | buffer: chars, cursor: length(chars)})
          _ ->
            raw_loop(state)
        end

      :ctrl_c ->
        IO.write("^C\r\n")
        ""

      :ctrl_d ->
        if state.buffer == [] do
          IO.write("\r\n")
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

      :ctrl_a ->
        raw_loop(%{state | cursor: 0})

      :ctrl_e ->
        raw_loop(%{state | cursor: length(state.buffer)})

      :ctrl_k ->
        {left, _right} = Enum.split(state.buffer, state.cursor)
        raw_loop(%{state | buffer: left})

      :ctrl_w ->
        {left, right} = Enum.split(state.buffer, state.cursor)
        words = left |> List.to_string() |> String.split(~r/\s+/, trim: false)
        new_left_str = Enum.drop(words, -1) |> Enum.join(" ")
        new_left = String.to_charlist(new_left_str)
        raw_loop(%{state | buffer: new_left ++ right, cursor: length(new_left)})

      :ctrl_l ->
        IO.write("\e[H\e[2J")
        raw_loop(state)

      :backspace ->
        if state.search_mode do
          new_query = Enum.drop(state.search_query, -1)
          raw_loop(%{state | search_query: new_query})
        else
          if state.cursor > 0 do
            {left, right} = Enum.split(state.buffer, state.cursor)
            new_left = Enum.drop(left, -1)
            raw_loop(%{state | buffer: new_left ++ right, cursor: state.cursor - 1})
          else
            raw_loop(state)
          end
        end

      :ctrl_u ->
        raw_loop(%{state | buffer: [], cursor: 0})

      :ctrl_r ->
        new_state = toggle_reverse_search(state)
        raw_loop(new_state)

      {:char, char} ->
        if state.search_mode do
          raw_loop(%{state | search_query: state.search_query ++ [char]})
        else
          {left, right} = Enum.split(state.buffer, state.cursor)
          new_buffer = left ++ [char] ++ right
          raw_loop(%{state | buffer: new_buffer, cursor: state.cursor + 1})
        end

      _ ->
        raw_loop(state)
    end
  end

  defp render_prompt_and_buffer(state) do
    IO.write("\r\e[K")

    if state.search_mode do
      query = List.to_string(state.search_query)
      match = find_in_history(query, state.history)
      IO.write("#{Formatter.cyan()}(reverse-i-search)'#{query}':#{Formatter.reset()} #{match}")
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
    %{state | search_mode: not state.search_mode, search_query: []}
  end

  def find_in_history(query, history) do
    case Enum.find(history, fn item -> String.contains?(item, query) end) do
      nil -> ""
      match -> match
    end
  end

  def tab_complete(input) do
    if String.starts_with?(input, "/") do
      matches = Enum.filter(@slash_commands, fn cmd -> String.starts_with?(cmd, input) end)

      case matches do
        [single] -> {:ok, single}
        [_first | _] -> {:ok, common_prefix(matches)}
        [] -> :none
      end
    else
      :none
    end
  end

  defp common_prefix([head | tail]) do
    Enum.reduce(tail, head, fn str, prefix ->
      prefix
      |> String.graphemes()
      |> Enum.zip(String.graphemes(str))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.join()
    end)
  end

  defp read_key do
    case IO.getn("", 1) do
      "\r" -> :enter
      "\n" -> :enter
      "\t" -> :tab
      "\x01" -> :ctrl_a
      "\x03" -> :ctrl_c
      "\x04" -> :ctrl_d
      "\x05" -> :ctrl_e
      "\x0b" -> :ctrl_k
      "\x0c" -> :ctrl_l
      "\x12" -> :ctrl_r
      "\x15" -> :ctrl_u
      "\x17" -> :ctrl_w
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
          "1" ->
            case IO.getn("", 1) do
              "~" -> :home
              _ -> :home
            end
          "4" ->
            case IO.getn("", 1) do
              "~" -> :end
              _ -> :end
            end
          "3" ->
            case IO.getn("", 1) do
              "~" -> :delete
              _ -> :delete
            end
          _ -> :other
        end

      "O" ->
        case IO.getn("", 1) do
          "A" -> :up
          "B" -> :down
          "C" -> :right
          "D" -> :left
          "H" -> :home
          "F" -> :end
          _ -> :other
        end

      _ ->
        :escape
    end
  end
end
