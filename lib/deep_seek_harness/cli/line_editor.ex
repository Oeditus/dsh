defmodule DeepSeekHarness.CLI.LineEditor do
  @moduledoc """
  Modern TUI Line Editor & Readline Engine for DeepSeek Harness (DSH RAGE).

  Features:
    - Fixed bottom command bar with horizontal ruler (agy style), redrawn in
      place on every keystroke instead of scrolling the terminal
    - Buffer managed as a list of Unicode graphemes with an explicit
      0-indexed cursor position, so combining marks and multi-byte
      characters never corrupt navigation or editing
    - Full keyboard cursor navigation (Left/Right, Home/End, Backspace/Delete)
    - Persistent history navigation (Up/Down arrows) with ~/.dsh/history
    - Reverse incremental search (Ctrl+R)
    - Tab auto-completion for slash commands
    - Emacs shortcuts (Ctrl+A, Ctrl+E, Ctrl+U, Ctrl+K, Ctrl+W, Ctrl+C, Ctrl+D)

  The module is split into pure state-transition functions (safe to unit
  test without a real TTY) and the impure raw-mode read/render loop that
  drives them.
  """
  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Config

  @history_file Path.expand("~/.dsh/history")

  @slash_commands [
    "/cb",
    "/checkpoint",
    "/clear",
    "/clipboard",
    "/commit",
    "/compact",
    "/cost",
    "/diff",
    "/exit",
    "/help",
    "/mcp",
    "/mode",
    "/model",
    "/nodes",
    "/permissions",
    "/plugins",
    "/quit",
    "/ragex",
    "/review",
    "/session",
    "/skill",
    "/skills",
    "/subagent",
    "/undo"
  ]

  # ---------------------------------------------------------------------
  # History persistence
  # ---------------------------------------------------------------------

  @doc "Loads persistent history lines from ~/.dsh/history, most recent first."
  def load_history do
    if File.exists?(@history_file) do
      @history_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reverse()
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

  # ---------------------------------------------------------------------
  # Pure state helpers (unit-testable without a TTY)
  # ---------------------------------------------------------------------

  @doc "Builds a fresh editor state for a new input line."
  def new_state(prompt_text, history \\ []) do
    %{
      buffer: [],
      cursor: 0,
      history: history,
      hist_idx: -1,
      saved_buffer: [],
      prompt: prompt_text,
      search_mode: false,
      search_query: [],
      search_offset: 0,
      first_render: true
    }
  end

  @doc "Moves the cursor one grapheme to the left, clamped at 0."
  def move_left(%{cursor: cursor} = state), do: %{state | cursor: max(cursor - 1, 0)}

  @doc "Moves the cursor one grapheme to the right, clamped at buffer length."
  def move_right(%{cursor: cursor, buffer: buffer} = state) do
    %{state | cursor: min(cursor + 1, length(buffer))}
  end

  @doc "Jumps the cursor to the start of the line (Home / Ctrl+A)."
  def move_to_start(state), do: %{state | cursor: 0}

  @doc "Jumps the cursor to the end of the line (End / Ctrl+E)."
  def move_to_end(%{buffer: buffer} = state), do: %{state | cursor: length(buffer)}

  @doc "Deletes the grapheme left of the cursor (Backspace)."
  def delete_backward(%{cursor: 0} = state), do: state

  def delete_backward(%{buffer: buffer, cursor: cursor} = state) do
    {left, right} = Enum.split(buffer, cursor)
    new_left = Enum.drop(left, -1)
    %{state | buffer: new_left ++ right, cursor: cursor - 1}
  end

  @doc "Deletes the grapheme at the cursor (Delete / \\e[3~)."
  def delete_forward(%{buffer: buffer, cursor: cursor} = state) do
    {left, right} = Enum.split(buffer, cursor)

    case right do
      [] -> state
      [_ | rest] -> %{state | buffer: left ++ rest}
    end
  end

  @doc "Clears the line left of the cursor (Ctrl+U)."
  def kill_to_start(%{buffer: buffer, cursor: cursor} = state) do
    {_left, right} = Enum.split(buffer, cursor)
    %{state | buffer: right, cursor: 0}
  end

  @doc "Clears the line right of the cursor (Ctrl+K)."
  def kill_to_end(%{buffer: buffer, cursor: cursor} = state) do
    {left, _right} = Enum.split(buffer, cursor)
    %{state | buffer: left}
  end

  @doc "Deletes the word behind the cursor (Ctrl+W)."
  def delete_word_backward(%{buffer: buffer, cursor: cursor} = state) do
    {left, right} = Enum.split(buffer, cursor)
    left_str = Enum.join(left)
    new_left_str = Regex.replace(~r/\S+\s*$/, left_str, "")
    new_left = String.graphemes(new_left_str)
    %{state | buffer: new_left ++ right, cursor: length(new_left)}
  end

  @doc """
  Inserts `char` at the cursor position, re-splitting the prefix into
  graphemes so that combining marks merge correctly with the previous
  character regardless of how they were typed.
  """
  def insert_char(%{buffer: buffer, cursor: cursor} = state, char) when is_binary(char) do
    {left, right} = Enum.split(buffer, cursor)
    new_prefix = String.graphemes(Enum.join(left) <> char)
    %{state | buffer: new_prefix ++ right, cursor: length(new_prefix)}
  end

  @doc """
  Navigates history up (older) or down (newer), preserving uncommitted
  input when entering navigation and restoring it when returning to -1.
  """
  def history_navigate(%{history: history, hist_idx: hist_idx} = state, :up) do
    if hist_idx < length(history) - 1 do
      new_idx = hist_idx + 1
      saved = if hist_idx == -1, do: state.buffer, else: state.saved_buffer
      chars = String.graphemes(Enum.at(history, new_idx, ""))
      %{state | hist_idx: new_idx, saved_buffer: saved, buffer: chars, cursor: length(chars)}
    else
      state
    end
  end

  def history_navigate(%{history: history, hist_idx: hist_idx} = state, :down) do
    cond do
      hist_idx > 0 ->
        new_idx = hist_idx - 1
        chars = String.graphemes(Enum.at(history, new_idx, ""))
        %{state | hist_idx: new_idx, buffer: chars, cursor: length(chars)}

      hist_idx == 0 ->
        chars = state.saved_buffer
        %{state | hist_idx: -1, buffer: chars, cursor: length(chars)}

      true ->
        state
    end
  end

  @doc "Finds the most recent history entry containing `query`."
  def find_in_history(query, history), do: find_in_history(query, history, 0)

  @doc "Finds the (offset + 1)-th most recent history entry containing `query`."
  def find_in_history("", _history, _offset), do: ""

  def find_in_history(query, history, offset) do
    history
    |> Enum.filter(&String.contains?(&1, query))
    |> Enum.at(offset, "")
  end

  @doc "Enters reverse-incremental-search mode (Ctrl+R)."
  def toggle_reverse_search(%{search_mode: false} = state) do
    %{
      state
      | search_mode: true,
        search_query: [],
        search_offset: Map.get(state, :search_offset, 0)
    }
  end

  def toggle_reverse_search(%{search_mode: true} = state), do: state

  @doc """
  Auto-completes a slash-command prefix.

  Returns `{:ok, completed}` when the prefix uniquely resolves or extends to
  a longer common prefix, `{:ambiguous, matches}` when multiple candidates
  share no longer common prefix, and `:none` when nothing matches.
  """
  def tab_complete(input) when is_binary(input) do
    if String.starts_with?(input, "/") do
      case Enum.filter(@slash_commands, &String.starts_with?(&1, input)) do
        [] ->
          :none

        [single] ->
          {:ok, single}

        multiple ->
          prefix = common_prefix(multiple)

          if String.length(prefix) > String.length(input) do
            {:ok, prefix}
          else
            {:ambiguous, multiple}
          end
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
      |> Enum.map_join("", &elem(&1, 0))
    end)
  end

  # ---------------------------------------------------------------------
  # Impure entry point & raw-mode loop
  # ---------------------------------------------------------------------

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

  # Raw keystrokes are read via OTP 28+'s native `shell:start_interactive/1`
  # noshell "raw" submode (see the "Creating a terminal application" guide in
  # the stdlib docs). This reads keystrokes as they happen with echo disabled
  # directly through BEAM's own terminal handling, instead of shelling out to
  # `stty`/depending on a resolvable `/dev/tty` path, both of which are
  # unreliable across the different ways this CLI can be launched (mix run,
  # escript, iex, a release) and can fight with BEAM's own terminal driver.
  defp read_tty_line(prompt_text, history) do
    set_raw_mode()

    try do
      result = raw_loop(new_state(prompt_text, history))
      restore_tty_mode()
      result
    catch
      _kind, _err ->
        restore_tty_mode()
        IO.gets(prompt_text)
    end
  end

  defp set_raw_mode do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp raw_loop(state) do
    state = render_bar(state)

    case read_key() do
      :enter -> handle_enter(state)
      :tab -> handle_tab(state)
      :ctrl_c -> handle_interrupt(state)
      :ctrl_d -> handle_eof(state)
      :up -> raw_loop(navigate_unless_searching(state, :up))
      :down -> raw_loop(navigate_unless_searching(state, :down))
      :left -> raw_loop(edit_unless_searching(state, &move_left/1))
      :right -> raw_loop(edit_unless_searching(state, &move_right/1))
      :home -> raw_loop(edit_unless_searching(state, &move_to_start/1))
      :end -> raw_loop(edit_unless_searching(state, &move_to_end/1))
      :ctrl_a -> raw_loop(edit_unless_searching(state, &move_to_start/1))
      :ctrl_e -> raw_loop(edit_unless_searching(state, &move_to_end/1))
      :ctrl_u -> raw_loop(edit_unless_searching(state, &kill_to_start/1))
      :ctrl_k -> raw_loop(edit_unless_searching(state, &kill_to_end/1))
      :ctrl_w -> raw_loop(edit_unless_searching(state, &delete_word_backward/1))
      :ctrl_r -> raw_loop(handle_ctrl_r(state))
      :backspace -> raw_loop(handle_backspace(state))
      :delete -> raw_loop(edit_unless_searching(state, &delete_forward/1))
      {:char, char_code} -> raw_loop(handle_char(state, <<char_code::utf8>>))
      _ -> raw_loop(state)
    end
  end

  defp navigate_unless_searching(%{search_mode: true} = state, _direction), do: state
  defp navigate_unless_searching(state, direction), do: history_navigate(state, direction)

  defp edit_unless_searching(%{search_mode: true} = state, _fun), do: state
  defp edit_unless_searching(state, fun), do: fun.(state)

  defp handle_enter(%{search_mode: true} = state) do
    query = Enum.join(state.search_query)
    match = find_in_history(query, state.history, state.search_offset)
    chars = String.graphemes(match)

    raw_loop(%{
      state
      | buffer: chars,
        cursor: length(chars),
        search_mode: false,
        search_query: [],
        search_offset: 0
    })
  end

  defp handle_enter(state) do
    render_final(state)
    line = Enum.join(state.buffer)
    add_history(line)
    line <> "\n"
  end

  defp handle_tab(%{search_mode: true} = state), do: raw_loop(state)

  defp handle_tab(state) do
    buf_str = Enum.join(state.buffer)

    case tab_complete(buf_str) do
      {:ok, completed} ->
        chars = String.graphemes(completed)
        raw_loop(%{state | buffer: chars, cursor: length(chars)})

      {:ambiguous, matches} ->
        show_completions(matches)
        raw_loop(%{state | first_render: true})

      :none ->
        raw_loop(state)
    end
  end

  defp handle_ctrl_r(%{search_mode: false} = state) do
    %{state | search_mode: true, search_query: [], search_offset: 0}
  end

  defp handle_ctrl_r(state), do: %{state | search_offset: state.search_offset + 1}

  defp handle_backspace(%{search_mode: true} = state) do
    %{state | search_query: Enum.drop(state.search_query, -1), search_offset: 0}
  end

  defp handle_backspace(state), do: delete_backward(state)

  defp handle_char(%{search_mode: true} = state, char) do
    %{state | search_query: state.search_query ++ [char], search_offset: 0}
  end

  defp handle_char(state, char), do: insert_char(state, char)

  defp handle_interrupt(state) do
    redraw_prefix = erase_prefix(state)
    IO.write(redraw_prefix <> "^C\r\n")
    ""
  end

  defp handle_eof(%{buffer: [], search_mode: false} = state) do
    render_final(state)
    :eof
  end

  defp handle_eof(state), do: raw_loop(state)

  # ---------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------

  defp render_bar(state) do
    ruler = ruler_line()
    {prompt_str, text_str, cursor_col} = compute_display(state)

    IO.write(erase_prefix(state) <> ruler <> "\r\n" <> prompt_str <> text_str)
    position_cursor(cursor_col)

    %{state | first_render: false}
  end

  defp render_final(state) do
    {prompt_str, text_str, _cursor_col} = compute_display(%{state | search_mode: false})
    IO.write(erase_prefix(state) <> prompt_str <> text_str <> "\r\n")
  end

  # Erases the previously drawn 2-line ruler+prompt block in place, or emits
  # nothing on the very first render (when nothing has been drawn yet).
  defp erase_prefix(%{first_render: true}), do: ""
  defp erase_prefix(_state), do: "\e[1A\r\e[J"

  defp position_cursor(cursor_col) do
    IO.write("\r")
    if cursor_col > 0, do: IO.write("\e[#{cursor_col}C")
  end

  defp ruler_line do
    cols =
      case :io.columns() do
        {:ok, c} when c > 10 -> c
        _ -> 80
      end

    Formatter.dim() <> String.duplicate("─", max(10, cols - 1)) <> Formatter.reset()
  end

  defp compute_display(%{search_mode: true} = state) do
    query = Enum.join(state.search_query)
    match = find_in_history(query, state.history, state.search_offset)
    prompt = "(reverse-i-search)'#{query}': "
    {prompt, match, String.length(prompt) + String.length(match)}
  end

  defp compute_display(state) do
    prompt_str = Formatter.format_user_prompt_str(state.prompt)
    text_str = Enum.join(state.buffer)
    prompt_visible_len = strip_ansi_length(prompt_str)

    buffer_prefix_len =
      state.buffer |> Enum.take(state.cursor) |> Enum.join() |> String.length()

    {prompt_str, text_str, prompt_visible_len + buffer_prefix_len}
  end

  defp strip_ansi_length(str) do
    str
    |> String.replace(~r/\e\[[0-9;]*[mGKH]/, "")
    |> String.length()
  end

  defp show_completions(matches) do
    IO.write(
      "\r\n" <>
        Formatter.dim() <>
        "Completions: " <> Enum.join(matches, "  ") <> Formatter.reset() <> "\r\n"
    )
  end

  # ---------------------------------------------------------------------
  # Raw key reading
  # ---------------------------------------------------------------------

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

  # Reads exactly one character via OTP's native raw-mode stdin handling
  # (see `set_raw_mode/0`). `:io.get_chars/2` returns as soon as data is
  # available, so this behaves like a blocking single-keystroke read.
  defp get_raw_input_chunk do
    case read_char() do
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
    case read_char() do
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

  defp read_char do
    case :io.get_chars("", 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      char when is_binary(char) -> char
      char when is_list(char) -> IO.iodata_to_binary(char)
      _ -> ""
    end
  end
end
