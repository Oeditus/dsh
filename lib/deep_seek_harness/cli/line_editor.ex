defmodule DeepSeekHarness.CLI.LineEditor do
  @moduledoc """
  Modern TUI Line Editor & Readline Engine for DeepSeek Harness (DSH RAGE).
  Features:
    - Fixed bottom command bar with horizontal ruler (agy style)
    - Full keyboard cursor navigation (Left/Right, Home/End, Backspace/Delete)
    - Persistent history navigation (Up/Down arrows) with ~/.dsh/history
    - Reverse incremental search (Ctrl+R)
    - Tab auto-completion for slash commands
    - Emacs shortcuts (Ctrl+A, Ctrl+E, Ctrl+U, Ctrl+K, Ctrl+W, Ctrl+C, Ctrl+D)
  """
  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Config

  @history_file Path.expand("~/.dsh/history")

  @slash_commands [
    "/cb",
    "/clipboard",
    "/checkpoint",
    "/clear",
    "/commit ",
    "/compact",
    "/cost",
    "/diff",
    "/exit",
    "/help",
    "/mcp",
    "/mcp add ",
    "/mcp list",
    "/mcp load",
    "/model ",
    "/mode ",
    "/nodes",
    "/permissions ",
    "/plugins",
    "/plugins reload",
    "/quit",
    "/ragex",
    "/review ",
    "/session",
    "/skills",
    "/subagent "
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
    render_bar(state)

    case read_key() do
      :enter ->
        if state.search_mode do
          query_str = Enum.join(state.search_query)
          match = find_in_history(query_str, state.history)
          chars = String.graphemes(match)

          raw_loop(%{
            state
            | buffer: chars,
              cursor: length(chars),
              search_mode: false,
              search_query: []
          })
        else
          IO.write("\r\n")
          line = Enum.join(state.buffer)
          add_history(line)
          line <> "\n"
        end

      :tab ->
        buf_str = Enum.join(state.buffer)

        case tab_complete(buf_str) do
          {:ok, completed} ->
            chars = String.graphemes(completed)
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

      :ctrl_u ->
        {_left, right} = Enum.split(state.buffer, state.cursor)
        raw_loop(%{state | buffer: right, cursor: 0})

      :ctrl_k ->
        {left, _right} = Enum.split(state.buffer, state.cursor)
        raw_loop(%{state | buffer: left})

      :ctrl_w ->
        {left, right} = Enum.split(state.buffer, state.cursor)
        left_str = Enum.join(left)
        new_left_str = Regex.replace(~r/\S+\s*$/, left_str, "")
        new_left = String.graphemes(new_left_str)
        raw_loop(%{state | buffer: new_left ++ right, cursor: length(new_left)})

      :ctrl_r ->
        if state.search_mode do
          raw_loop(state)
        else
          raw_loop(%{state | search_mode: true, search_query: []})
        end

      :backspace ->
        if state.search_mode do
          new_q = Enum.drop(state.search_query, -1)
          raw_loop(%{state | search_query: new_q})
        else
          if state.cursor > 0 do
            {left, right} = Enum.split(state.buffer, state.cursor)
            new_left = Enum.drop(left, -1)
            raw_loop(%{state | buffer: new_left ++ right, cursor: state.cursor - 1})
          else
            raw_loop(state)
          end
        end

      :delete ->
        {left, right} = Enum.split(state.buffer, state.cursor)

        if right != [] do
          new_right = Enum.drop(right, 1)
          raw_loop(%{state | buffer: left ++ new_right})
        else
          raw_loop(state)
        end

      {:char, char_code} ->
        char = <<char_code::utf8>>

        if state.search_mode do
          new_q = state.search_query ++ [char]
          raw_loop(%{state | search_query: new_q})
        else
          {left, right} = Enum.split(state.buffer, state.cursor)
          raw_loop(%{state | buffer: left ++ [char] ++ right, cursor: state.cursor + 1})
        end

      _ ->
        raw_loop(state)
    end
  end

  defp render_bar(state) do
    cols =
      case :io.columns() do
        {:ok, c} when c > 10 -> c
        _ -> 80
      end

    ruler = Formatter.dim() <> String.duplicate("─", max(10, cols - 1)) <> Formatter.reset()

    {displayed_prompt, displayed_text, cursor_pos} =
      if state.search_mode do
        q = Enum.join(state.search_query)
        match = find_in_history(q, state.history)
        p = "(reverse-i-search)'#{q}': "
        {p, match, length(String.graphemes(p)) + length(String.graphemes(match))}
      else
        prompt_str = Formatter.format_user_prompt_str(state.prompt)
        text_str = Enum.join(state.buffer)
        p_visible_len = strip_ansi_length(prompt_str)

        buffer_prefix_len =
          Enum.take(state.buffer, state.cursor) |> Enum.join() |> String.length()

        {prompt_str, text_str, p_visible_len + buffer_prefix_len}
      end

    # Clear line, output ruler and prompt text
    output = "\r\e[K" <> ruler <> "\r\n\r\e[K" <> displayed_prompt <> displayed_text
    IO.write(output)

    # Position cursor at exact position
    if cursor_pos > 0 do
      IO.write("\r\e[#{cursor_pos}C")
    else
      IO.write("\r")
    end
  end

  defp strip_ansi_length(str) do
    str
    |> String.replace(~r/\e\[[0-9;]*[mGKH]/, "")
    |> String.length()
  end

  defp history_navigate(state, direction) do
    case direction do
      :up ->
        if state.hist_idx < length(state.history) - 1 do
          new_idx = state.hist_idx + 1
          saved = if state.hist_idx == -1, do: state.buffer, else: state.saved_buffer
          line = Enum.at(state.history, new_idx, "")
          chars = String.graphemes(line)
          %{state | hist_idx: new_idx, saved_buffer: saved, buffer: chars, cursor: length(chars)}
        else
          state
        end

      :down ->
        if state.hist_idx > 0 do
          new_idx = state.hist_idx - 1
          line = Enum.at(state.history, new_idx, "")
          chars = String.graphemes(line)
          %{state | hist_idx: new_idx, buffer: chars, cursor: length(chars)}
        else
          if state.hist_idx == 0 do
            chars = state.saved_buffer
            %{state | hist_idx: -1, buffer: chars, cursor: length(chars)}
          else
            state
          end
        end
    end
  end

  defp find_in_history(query, history) do
    if query == "" do
      ""
    else
      Enum.find(history, "", fn h -> String.contains?(h, query) end)
    end
  end

  defp tab_complete(input) do
    if String.starts_with?(input, "/") do
      matches = Enum.filter(@slash_commands, &String.starts_with?(&1, input))

      case matches do
        [single] ->
          {:ok, single}

        [_ | _] = multiple ->
          prefix = common_prefix(multiple)

          if prefix != "" and String.length(prefix) > String.length(input) do
            {:ok, prefix}
          else
            IO.write(
              "\r\n" <>
                Formatter.dim() <>
                "Completions: " <> Enum.join(matches, "  ") <> Formatter.reset() <> "\r\n"
            )

            {:ok, input}
          end

        [] ->
          :error
      end
    else
      :error
    end
  end

  defp common_prefix([head | tail]) do
    Enum.reduce(tail, head, fn str, prefix ->
      prefix
      |> String.graphemes()
      |> Enum.zip(String.graphemes(str))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map_join("", &elem(&1, 0))
    end)
  end

  defp read_key do
    match_key(get_raw_input_chunk())
  end

  defp match_key("\e[A"), do: :up
  defp match_key("\e[B"), do: :down
  defp match_key("\e[C"), do: :right
  defp match_key("\e[D"), do: :left
  defp match_key("\eOA"), do: :up
  defp match_key("\eOB"), do: :down
  defp match_key("\eOC"), do: :right
  defp match_key("\eOD"), do: :left
  defp match_key("\e[H"), do: :home
  defp match_key("\e[F"), do: :end
  defp match_key("\e[1~"), do: :home
  defp match_key("\e[4~"), do: :end
  defp match_key("\e[3~"), do: :delete
  defp match_key("\r"), do: :enter
  defp match_key("\n"), do: :enter
  defp match_key("\r\n"), do: :enter
  defp match_key("\t"), do: :tab
  defp match_key("\x01"), do: :ctrl_a
  defp match_key("\x03"), do: :ctrl_c
  defp match_key("\x04"), do: :ctrl_d
  defp match_key("\x05"), do: :ctrl_e
  defp match_key("\x0b"), do: :ctrl_k
  defp match_key("\x0c"), do: :ctrl_l
  defp match_key("\x12"), do: :ctrl_r
  defp match_key("\x15"), do: :ctrl_u
  defp match_key("\x17"), do: :ctrl_w
  defp match_key("\x7f"), do: :backspace
  defp match_key("\x08"), do: :backspace
  defp match_key("\e"), do: :escape

  defp match_key(other) when is_binary(other) do
    cond do
      String.contains?(other, "[A") or String.contains?(other, "OA") ->
        :up

      String.contains?(other, "[B") or String.contains?(other, "OB") ->
        :down

      String.contains?(other, "[C") or String.contains?(other, "OC") ->
        :right

      String.contains?(other, "[D") or String.contains?(other, "OD") ->
        :left

      true ->
        case String.to_charlist(other) do
          [c | _] -> {:char, c}
          _ -> :other
        end
    end
  end

  defp get_raw_input_chunk do
    case IO.getn("", 1) do
      "\e" ->
        seq = read_available_escape_bytes("", 3)
        "\e" <> seq

      :eof ->
        "\x04"

      char when is_binary(char) ->
        char

      _ ->
        ""
    end
  end

  defp read_available_escape_bytes(acc, count) when count > 0 do
    case IO.getn("", 1) do
      char when is_binary(char) and char != "" ->
        new_acc = acc <> char

        if char in ["A", "B", "C", "D", "H", "F", "~"] do
          new_acc
        else
          read_available_escape_bytes(new_acc, count - 1)
        end

      _ ->
        acc
    end
  end

  defp read_available_escape_bytes(acc, _count), do: acc
end
