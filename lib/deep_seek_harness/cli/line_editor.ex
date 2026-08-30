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
    - Live status bar hotkeys: Ctrl+P (permission mode), Ctrl+G (sandbox),
      Ctrl+B (status bar gauge/compact toggle)

  The module is split into pure state-transition functions (safe to unit
  test without a real TTY) and the impure raw-mode read/render loop that
  drives them.
  """
  alias DeepSeekHarness.Brain.Session
  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Config

  @slash_commands [
    "/cb",
    "/checkpoint",
    "/clear",
    "/clipboard",
    "/commit",
    "/compact",
    "/config",
    "/cost",
    "/cr",
    "/diff",
    "/exit",
    "/help",
    "/lint",
    "/linter",
    "/mcp",
    "/mode",
    "/model",
    "/nodes",
    "/permissions",
    "/plugins",
    "/quit",
    "/ragex",
    "/resume",
    "/review",
    "/rules",
    "/session",
    "/skill",
    "/skills",
    "/subagent",
    "/undo",
    "/update"
  ]

  # ---------------------------------------------------------------------
  # History persistence
  # ---------------------------------------------------------------------

  @doc "Loads persistent history lines from the history file, most recent first."
  def load_history do
    path = history_file()

    if File.exists?(path) do
      path
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
      path = history_file()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#{trimmed}\n", [:append])
    end
  rescue
    _ -> :ok
  end

  @doc """
  Resolves the persistent history file path. Defaults to `~/.dsh/history`,
  but can be overridden via the `:history_file` application environment key
  (used by tests so they never read from or write to the real user history).
  """
  def history_file do
    Application.get_env(:deep_seek_harness, :history_file) || Path.expand("~/.dsh/history")
  end

  @doc """
  Formats a configurable prompt string using config template or default.

  `sandbox_override` (optional 5th arg), when a boolean, reflects the live
  session's actual sandbox state (as set via `/sandbox` or the Ctrl+G
  hotkey) instead of the static `sandbox_workspace` config file value, so
  the prompt's sandbox indicator matches reality. Omit it (or pass `nil`) to
  fall back to the config-file value, e.g. from tests or one-shot contexts
  with no live session.
  """
  def build_prompt(session_id, model, hands_mode \\ "local", cwd \\ ".", sandbox_override \\ nil) do
    config = Config.load_config(cwd)
    style = Map.get(config, "prompt_style", "starship")

    sandbox? =
      if is_boolean(sandbox_override),
        do: sandbox_override,
        else: Map.get(config, "sandbox_workspace", false)

    case style do
      "starship" ->
        build_starship_prompt(session_id, model, hands_mode, cwd, sandbox?)

      "extended" ->
        build_extended_prompt(session_id, model, hands_mode, cwd, sandbox?)

      "compact" ->
        build_compact_prompt(session_id, model, cwd)

      "minimal" ->
        "#{Formatter.cyan()}❯#{Formatter.reset()} "

      _ ->
        template = Map.get(config, "prompt_format", "user@{session} [{model}]> ")
        active_tasks = DeepSeekHarness.TaskEngine.Supervisor.list_active_tasks()
        task_count = length(active_tasks)
        task_str = if task_count > 0, do: "󱐋#{task_count} running", else: "idle"

        template
        |> String.replace("{session}", session_id)
        |> String.replace("{model}", model)
        |> String.replace("{mode}", to_string(hands_mode))
        |> String.replace("{tasks}", task_str)
    end
  end

  defp build_starship_prompt(_session_id, model, hands_mode, cwd, sandbox?) do
    folder = Path.basename(Path.expand(cwd))
    branch = DeepSeekHarness.Git.current_branch(cwd)
    branch_str = if branch != "", do: " 󰘬 #{branch}", else: ""
    sandbox = if sandbox?, do: " 󰌾 sandbox", else: ""

    active_tasks = DeepSeekHarness.TaskEngine.Supervisor.list_active_tasks()
    task_count = length(active_tasks)

    task_badge =
      if task_count > 0 do
        " #{Formatter.yellow()}⚡#{task_count} running#{Formatter.reset()}"
      else
        ""
      end

    model_icon =
      case model do
        "deepseek-reasoner" -> "󰧑"
        "deepseek-coder" -> "󰘦"
        _ -> "󰚩"
      end

    mode_badge =
      case to_string(hands_mode) do
        "local" -> ""
        other -> " 󰖟 #{other}"
      end

    line =
      "#{Formatter.cyan()}󰉋 #{folder}#{Formatter.reset()}" <>
        "#{Formatter.magenta()}#{branch_str}#{Formatter.reset()}" <>
        " #{Formatter.green()}#{model_icon} #{model}#{Formatter.reset()}" <>
        "#{Formatter.yellow()}#{sandbox}#{mode_badge}#{Formatter.reset()}" <>
        task_badge

    "#{line} #{Formatter.cyan()}❯#{Formatter.reset()} "
  end

  defp build_extended_prompt(session_id, model, hands_mode, cwd, sandbox?) do
    folder = Path.basename(Path.expand(cwd))
    branch = DeepSeekHarness.Git.current_branch(cwd)
    branch_str = if branch != "", do: " 󰘬 #{branch}", else: ""
    sandbox = if sandbox?, do: " 󰌾 sandbox", else: ""

    active_tasks = DeepSeekHarness.TaskEngine.Supervisor.list_active_tasks()
    task_count = length(active_tasks)

    task_badge =
      if task_count > 0 do
        " #{Formatter.yellow()}⚡#{task_count} running#{Formatter.reset()}"
      else
        ""
      end

    mode_badge =
      case to_string(hands_mode) do
        "local" -> ""
        other -> " 󰖟 #{other}"
      end

    short_id = String.slice(session_id, 0, 8)

    line =
      "#{Formatter.cyan()}󰉋 #{folder}#{Formatter.reset()}" <>
        "#{Formatter.magenta()}#{branch_str}#{Formatter.reset()}" <>
        " #{Formatter.green()}󰚩 #{model}#{Formatter.reset()}" <>
        "#{Formatter.dim()} [id:#{short_id}]#{Formatter.reset()}" <>
        "#{Formatter.yellow()}#{sandbox}#{mode_badge}#{Formatter.reset()}" <>
        task_badge

    "#{line} #{Formatter.cyan()}❯#{Formatter.reset()} "
  end

  defp build_compact_prompt(_session_id, model, cwd) do
    folder = Path.basename(Path.expand(cwd))
    branch = DeepSeekHarness.Git.current_branch(cwd)
    branch_str = if branch != "", do: "  #{branch}", else: ""

    "#{Formatter.cyan()}#{folder}#{Formatter.magenta()}#{branch_str}#{Formatter.reset()} [#{model}] #{Formatter.cyan()}❯#{Formatter.reset()} "
  end

  # ---------------------------------------------------------------------
  # Pure state helpers (unit-testable without a TTY)
  # ---------------------------------------------------------------------

  @doc "Builds a fresh editor state for a new input line."
  def new_state(prompt_text, history \\ [], context \\ %{}) do
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
      first_render: true,
      # Total terminal rows the last-drawn ruler+prompt block occupied,
      # including any wrapping caused by a long typed line or ghost
      # suggestion. Needed so `erase_prefix/1` erases exactly what was
      # drawn instead of assuming a fixed 2-row block.
      last_rows: 0,
      context: context
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

  @doc """
  Reads interactive input line with persistent history and TUI key controls.

  `context` optionally carries live session stats (e.g. `:total_tokens`,
  `:estimated_cost_usd`, `:model`) used to render the status bar's context
  usage gauge above the prompt when no background tasks are active.
  """
  def get_line(prompt_text, history \\ [], context \\ %{}) do
    if tty?() do
      read_tty_line(prompt_text, history, context)
    else
      IO.gets(prompt_text)
    end
  end

  defp tty? do
    if (function_exported?(Mix, :env, 0) and Mix.env() == :test) or
         System.get_env("CI") != nil or
         Application.get_env(:deep_seek_harness, :non_interactive, false) do
      false
    else
      case :io.columns() do
        {:ok, _} -> true
        _ -> false
      end
    end
  end

  # Raw keystrokes are read via OTP 28+'s native `shell:start_interactive/1`
  # noshell "raw" submode (see the "Creating a terminal application" guide in
  # the stdlib docs). This reads keystrokes as they happen with echo disabled
  # directly through BEAM's own terminal handling, instead of shelling out to
  # `stty`/depending on a resolvable `/dev/tty` path, both of which are
  # unreliable across the different ways this CLI can be launched (mix run,
  # escript, iex, a release) and can fight with BEAM's own terminal driver.
  defp read_tty_line(prompt_text, history, context) do
    set_raw_mode()

    try do
      result = raw_loop(new_state(prompt_text, history, context))
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
      :right -> raw_loop(edit_unless_searching(state, &accept_ghost_suggestion/1))
      :home -> raw_loop(edit_unless_searching(state, &move_to_start/1))
      :end -> raw_loop(edit_unless_searching(state, &accept_ghost_suggestion/1))
      :ctrl_a -> raw_loop(edit_unless_searching(state, &move_to_start/1))
      :ctrl_e -> raw_loop(edit_unless_searching(state, &accept_ghost_suggestion/1))
      :ctrl_u -> raw_loop(edit_unless_searching(state, &kill_to_start/1))
      :ctrl_k -> raw_loop(edit_unless_searching(state, &kill_to_end/1))
      :ctrl_w -> raw_loop(edit_unless_searching(state, &delete_word_backward/1))
      :ctrl_p -> raw_loop(edit_unless_searching(state, &toggle_permission_mode/1))
      :ctrl_g -> raw_loop(edit_unless_searching(state, &toggle_sandbox_mode/1))
      :ctrl_b -> raw_loop(edit_unless_searching(state, &toggle_status_bar_mode/1))
      :ctrl_r -> raw_loop(handle_ctrl_r(state))
      :backspace -> raw_loop(handle_backspace(state))
      :delete -> raw_loop(edit_unless_searching(state, &delete_forward/1))
      {:char, 64} -> raw_loop(file_picker_modal(state))
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
    line = Enum.join(state.buffer)

    if multiline_continuation?(line) do
      render_final(state)
      clean_current = String.trim_trailing(line, "\\")
      next_line = read_tty_line("... > ", state.history, Map.get(state, :context, %{}))
      full_line = clean_current <> "\n" <> next_line
      add_history(full_line)
      full_line
    else
      render_final(state)
      add_history(line)
      line <> "\n"
    end
  end

  defp multiline_continuation?(line) when is_binary(line) do
    String.ends_with?(line, "\\") or
      (String.contains?(line, "\"\"\"") and count_occurrences(line, "\"\"\"") |> rem(2) == 1)
  end

  defp count_occurrences(str, sub) do
    length(String.split(str, sub)) - 1
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

  # ---------------------------------------------------------------------
  # Status bar hotkey toggles (Ctrl+P / Ctrl+G / Ctrl+B)
  #
  # These mutate the live session (permission mode, sandbox bounds) or
  # persisted config (status bar display mode) and update the in-memory
  # `state.context` so the ruler redraws immediately with the new value.
  # They are best-effort: if there's no live session_pid in context (e.g.
  # a bare `get_line/1,2` call with no context), they no-op safely.
  # ---------------------------------------------------------------------

  defp toggle_permission_mode(state) do
    context = Map.get(state, :context, %{})

    case Map.get(context, :session_pid) do
      pid when is_pid(pid) ->
        current = Map.get(context, :permission_mode, :ask_confirm)
        new_mode = if current == :auto_approve, do: :ask_confirm, else: :auto_approve

        case Session.set_permission_mode(pid, new_mode) do
          {:ok, applied} ->
            %{state | context: Map.put(context, :permission_mode, applied)}

          _ ->
            state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  catch
    _, _ -> state
  end

  defp toggle_sandbox_mode(state) do
    context = Map.get(state, :context, %{})

    case Map.get(context, :session_pid) do
      pid when is_pid(pid) ->
        current = Map.get(context, :sandbox_workspace, false)

        case Session.set_sandbox_mode(pid, not current) do
          {:ok, applied} ->
            %{state | context: Map.put(context, :sandbox_workspace, applied)}

          _ ->
            state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  catch
    _, _ -> state
  end

  defp toggle_status_bar_mode(state) do
    context = Map.get(state, :context, %{})
    new_val = not Map.get(context, :compact_status_bar?, false)

    persist_compact_status_bar(new_val)
    %{state | context: Map.put(context, :compact_status_bar?, new_val)}
  end

  defp persist_compact_status_bar(value) do
    cfg = Config.load_config()
    Config.save_config(Map.put(cfg, "compact_status_bar", value))
  rescue
    _ -> :ok
  end

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
    cols = terminal_cols()
    ruler = ruler_line(Map.get(state, :context, %{}))
    {prompt_str, text_str, cursor_col} = compute_display(state)

    ruler_rows = rows_for(display_width(ruler), cols)
    content_rows = rows_for(display_width(prompt_str) + display_width(text_str), cols)

    IO.write(erase_prefix(state) <> ruler <> "\r\n" <> prompt_str <> text_str)
    position_cursor(cursor_col, content_rows, cols)

    %{state | first_render: false, last_rows: ruler_rows + content_rows}
  end

  defp render_final(state) do
    {prompt_str, text_str, _cursor_col} = compute_display(%{state | search_mode: false})
    IO.write(erase_prefix(state) <> prompt_str <> text_str <> "\r\n")
  end

  # Erases the previously drawn ruler+prompt block in place, however many
  # terminal rows it actually spanned (tracked in `state.last_rows`), or
  # emits nothing on the very first render (when nothing has been drawn
  # yet). A long typed line or a long fish-style ghost suggestion can wrap
  # the prompt row across multiple terminal rows, so this must move the
  # cursor up by `last_rows - 1` (not a hardcoded 1) before clearing,
  # otherwise stale wrapped lines are left behind and subsequent redraws
  # drift down the screen.
  defp erase_prefix(%{first_render: true}), do: ""

  defp erase_prefix(state) do
    case Map.get(state, :last_rows, 2) - 1 do
      up when up > 0 -> "\e[#{up}A\r\e[J"
      _ -> "\r\e[J"
    end
  end

  # Positions the cursor within a (possibly wrapped) prompt+text block that
  # was just written. `cursor_col` is the absolute visible-character offset
  # of the cursor from the start of that block; `content_rows` is how many
  # terminal rows the block spans. The terminal's real cursor is currently
  # at the end of everything written (the last wrapped row), so this moves
  # up to the row containing `cursor_col` and over to the right column.
  defp position_cursor(cursor_col, content_rows, cols) do
    cols = max(cols, 1)
    last_row_index = max(content_rows - 1, 0)
    target_row = min(div(cursor_col, cols), last_row_index)
    col_in_row = cursor_col - target_row * cols
    rows_up = last_row_index - target_row

    if rows_up > 0, do: IO.write("\e[#{rows_up}A")
    IO.write("\r")
    if col_in_row > 0, do: IO.write("\e[#{col_in_row}C")
  end

  defp terminal_cols do
    case :io.columns() do
      {:ok, c} when c > 10 -> c
      _ -> 80
    end
  end

  # Ceiling-divides a visible character width by the terminal width to get
  # the number of terminal rows it occupies, with a floor of 1 row (even
  # empty content still occupies the row it's written on).
  defp rows_for(width, _cols) when width <= 0, do: 1

  defp rows_for(width, cols) do
    cols = max(cols, 1)
    div(width - 1, cols) + 1
  end

  # Renders the fixed status bar ruler above the prompt. Priority order:
  #   1. Active parallel task badge (highest priority -- surfaces background
  #      work tracked by the OTP TaskEngine in real time)
  #   2. Idle status bar: an ambient segment (permission mode, sandbox state,
  #      MCP/tool counts, git dirty indicator) plus a toggleable segment
  #      (token/cost gauge, or a compact session summary -- Ctrl+B/
  #      `/config toggle compact_status_bar` to switch)
  #   3. A plain dim divider, when the status bar is disabled entirely
  defp ruler_line(context) do
    cols = terminal_cols()
    active_tasks = DeepSeekHarness.TaskEngine.Supervisor.list_active_tasks()

    cond do
      not Enum.empty?(active_tasks) ->
        task_badge_ruler(cols, active_tasks)

      context_gauge_enabled?() and is_map(context) and map_size(context) > 0 ->
        idle_status_ruler(cols, context)

      true ->
        plain_ruler(cols)
    end
  end

  defp plain_ruler(cols) do
    Formatter.dim() <> String.duplicate("─", max(10, cols - 1)) <> Formatter.reset()
  end

  defp task_badge_ruler(cols, active_tasks) do
    count = length(active_tasks)
    summaries = Enum.map_join(active_tasks, ", ", fn t -> t.summary end)
    raw_badge = " 󱐋 #{count} running: #{summaries} "

    max_allowed = max(10, cols - 12)

    truncated =
      if String.length(raw_badge) > max_allowed do
        String.slice(raw_badge, 0, max_allowed - 3) <> "... "
      else
        raw_badge
      end

    badge_fmt =
      "#{Formatter.cyan()}[#{Formatter.yellow()}#{Formatter.bold()}#{truncated}#{Formatter.reset()}#{Formatter.cyan()}]#{Formatter.reset()}"

    center_in_ruler(cols, badge_fmt, String.length(truncated) + 2)
  end

  # Combines the always-on ambient segment with the toggleable gauge/compact
  # segment. Falls back to the toggle segment alone on narrow terminals.
  defp idle_status_ruler(cols, context) do
    ambient = ambient_segment(context)
    toggle_part = toggle_segment(context)
    separator = " #{Formatter.dim()}│#{Formatter.reset()} "
    combined = ambient <> separator <> toggle_part
    combined_len = display_width(combined)

    if combined_len > cols - 4 do
      center_in_ruler(cols, toggle_part, display_width(toggle_part))
    else
      center_in_ruler(cols, combined, combined_len)
    end
  end

  # Ambient "what's up internally" icons: permission mode, sandbox bounds,
  # connected MCP server count, registered tool count, and (only when the
  # workspace has uncommitted changes) a small dirty-state dot.
  defp ambient_segment(context) do
    permission_mode = Map.get(context, :permission_mode, :ask_confirm)
    perm_label = if permission_mode == :auto_approve, do: "auto", else: "ask"
    sandbox? = Map.get(context, :sandbox_workspace, false)
    mcp_count = Map.get(context, :mcp_servers_count, 0)
    tools_count = Map.get(context, :tools_count, 0)
    dot = " #{Formatter.dim()}•#{Formatter.reset()} "

    perm_str = "#{Formatter.magenta()}󰈤 #{perm_label}#{Formatter.reset()}"
    sandbox_str = "#{Formatter.blue()}#{if sandbox?, do: "󰌾", else: "󰌿"}#{Formatter.reset()}"
    mcp_str = "#{Formatter.cyan()}🔌 #{mcp_count}#{Formatter.reset()}"
    tools_str = "#{Formatter.cyan()}󰒓 #{tools_count}#{Formatter.reset()}"

    parts = [perm_str, sandbox_str, mcp_str, tools_str]

    parts =
      if Map.get(context, :git_dirty?, false) do
        parts ++ ["#{Formatter.yellow()}●#{Formatter.reset()}"]
      else
        parts
      end

    Enum.join(parts, dot)
  end

  defp toggle_segment(context) do
    if Map.get(context, :compact_status_bar?, false) do
      compact_session_content(context)
    else
      gauge_content(context)
    end
  end

  defp gauge_content(context) do
    total_tokens = Map.get(context, :total_tokens, 0)
    cost_usd = Map.get(context, :estimated_cost_usd, 0.0)
    delta = Map.get(context, :last_turn_tokens, 0)
    max_tokens = context_window_tokens(Map.get(context, :model))
    serving_procs = Map.get(context, :serving_processes, length(Process.list()))

    Formatter.format_context_gauge(total_tokens, max_tokens, cost_usd, delta, serving_procs)
  end

  defp compact_session_content(context) do
    short_id = context |> Map.get(:session_id, "") |> to_string() |> String.slice(0, 8)
    msg_count = Map.get(context, :message_count, 0)
    serving_procs = Map.get(context, :serving_processes, length(Process.list()))

    "#{Formatter.cyan()}id:#{short_id}#{Formatter.reset()} #{Formatter.dim()}•#{Formatter.reset()} #{msg_count} msgs #{Formatter.dim()}•#{Formatter.reset()} ⚡ #{serving_procs} procs"
  end

  defp context_gauge_enabled? do
    Map.get(Config.load_config(), "enable_context_gauge", true)
  end

  # DeepSeek's chat/reasoner models currently expose a 64K-token context
  # window. This is overridable per-workspace by setting "max_context_tokens"
  # in .dsh/config.json (or ~/.dsh/config.json), in case that limit changes.
  defp context_window_tokens(_model) do
    Map.get(Config.load_config(), "max_context_tokens", 64_000)
  end

  defp center_in_ruler(cols, content_str, content_visible_len) do
    left_len = max(2, div(cols - content_visible_len, 2))
    right_len = max(2, cols - left_len - content_visible_len - 1)

    Formatter.dim() <>
      String.duplicate("─", left_len) <>
      Formatter.reset() <>
      content_str <>
      Formatter.dim() <>
      String.duplicate("─", right_len) <>
      Formatter.reset()
  end

  defp compute_display(%{search_mode: true} = state) do
    query = Enum.join(state.search_query)
    match = find_in_history(query, state.history, state.search_offset)
    prompt = "(reverse-i-search)'#{query}': "
    {prompt, match, String.length(prompt) + String.length(match)}
  end

  defp compute_display(state) do
    config = Config.load_config()
    prompt_str = Formatter.format_user_prompt_str(state.prompt)
    raw_text = Enum.join(state.buffer)
    highlighted_text = highlight_input(raw_text, config)

    suggestion = get_ghost_suggestion(raw_text, state.history, config)

    ghost_str =
      if suggestion != "",
        do: "#{Formatter.gray()}#{suggestion}#{Formatter.reset()}",
        else: ""

    prompt_visible_len = strip_ansi_length(prompt_str)

    buffer_prefix_len =
      state.buffer |> Enum.take(state.cursor) |> Enum.join() |> String.length()

    {prompt_str, highlighted_text <> ghost_str, prompt_visible_len + buffer_prefix_len}
  end

  def accept_ghost_suggestion(%{cursor: cursor, buffer: buffer, history: history} = state) do
    if cursor == length(buffer) do
      raw_text = Enum.join(buffer)
      config = Config.load_config()
      suggestion = get_ghost_suggestion(raw_text, history, config)

      if suggestion != "" do
        new_chars = String.graphemes(raw_text <> suggestion)
        %{state | buffer: new_chars, cursor: length(new_chars)}
      else
        move_right(state)
      end
    else
      move_right(state)
    end
  end

  def get_ghost_suggestion(buffer_text, history, config) do
    if Map.get(config, "enable_autosuggestions", true) and buffer_text != "" do
      match =
        Enum.find(history, fn line ->
          String.starts_with?(line, buffer_text) and line != buffer_text
        end)

      if match do
        len = String.length(buffer_text)
        String.slice(match, len..-1//1)
      else
        ""
      end
    else
      ""
    end
  end

  def highlight_input(input, config) do
    if Map.get(config, "enable_syntax_highlighting", true) do
      cond do
        String.starts_with?(input, "/") ->
          parts = String.split(input, " ", parts: 2)

          case parts do
            [cmd, rest] ->
              "#{Formatter.cyan()}#{cmd}#{Formatter.reset()} #{rest}"

            [cmd] ->
              "#{Formatter.cyan()}#{cmd}#{Formatter.reset()}"
          end

        String.starts_with?(input, "!") ->
          "#{Formatter.yellow()}#{input}#{Formatter.reset()}"

        true ->
          input
      end
    else
      input
    end
  end

  def file_picker_modal(state) do
    config = Config.load_config()

    if Map.get(config, "enable_file_picker", true) do
      files =
        list_workspace_files()
        |> Enum.take(30)

      opts =
        Enum.map(files, fn f ->
          icon = if File.dir?(f), do: "󰉋", else: "󰈔"
          "#{icon} #{f}"
        end)

      if opts == [] do
        insert_char(state, "@")
      else
        ans =
          DeepSeekHarness.CLI.Spinner.with_paused(fn ->
            DeepSeekHarness.CLI.QuestionPrompt.ask_single_question(
              "Select file context to attach:",
              opts,
              false,
              false
            )
          end)

        case ans do
          %{selected: [sel]} ->
            clean_path = sel |> String.split(" ", parts: 2) |> List.last()
            inserted = "@" <> clean_path
            chars = String.graphemes(inserted)
            {left, right} = Enum.split(state.buffer, state.cursor)

            %{
              state
              | buffer: left ++ chars ++ right,
                cursor: state.cursor + length(chars),
                first_render: true
            }

          _ ->
            st = insert_char(state, "@")
            %{st | first_render: true}
        end
      end
    else
      st = insert_char(state, "@")
      %{st | first_render: true}
    end
  end

  defp list_workspace_files do
    raw_files =
      case System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard"],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          String.split(out, "\n", trim: true)

        _ ->
          fallback_wildcard_files()
      end

    raw_files
    |> Enum.reject(fn path ->
      String.starts_with?(path, ".git") or
        String.starts_with?(path, "_build") or
        String.contains?(path, "/_build/") or
        String.starts_with?(path, "deps") or
        String.contains?(path, "/deps/") or
        String.starts_with?(path, ".elixir_ls") or
        String.contains?(path, "/.elixir_ls/") or
        String.starts_with?(path, "node_modules") or
        String.contains?(path, "/node_modules/") or
        String.starts_with?(path, "dist") or
        String.contains?(path, "/dist/") or
        String.starts_with?(path, "build") or
        String.contains?(path, "/build/")
    end)
  rescue
    _ -> fallback_wildcard_files()
  end

  defp fallback_wildcard_files do
    Path.wildcard("**/*")
    |> Enum.reject(fn path ->
      String.starts_with?(path, ".git") or
        String.starts_with?(path, "_build") or
        String.contains?(path, "/_build/") or
        String.starts_with?(path, "deps") or
        String.contains?(path, "/deps/") or
        String.starts_with?(path, ".elixir_ls") or
        String.contains?(path, "/.elixir_ls/") or
        String.starts_with?(path, "node_modules") or
        String.contains?(path, "/node_modules/") or
        String.starts_with?(path, "dist") or
        String.contains?(path, "/dist/") or
        String.starts_with?(path, "build") or
        String.contains?(path, "/build/")
    end)
  end

  def display_width(str) when is_binary(str) do
    clean = String.replace(str, ~r/\e\[[0-9;]*[mGKH]/, "")

    try do
      Owl.Data.length(clean)
    rescue
      _ -> String.length(clean)
    end
  end

  defp strip_ansi_length(str), do: display_width(str)

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
  defp match_key("\x02"), do: :ctrl_b
  defp match_key("\x03"), do: :ctrl_c
  defp match_key("\x04"), do: :ctrl_d
  defp match_key("\x05"), do: :ctrl_e
  defp match_key("\x07"), do: :ctrl_g
  defp match_key("\x0b"), do: :ctrl_k
  defp match_key("\x0c"), do: :ctrl_l
  defp match_key("\x10"), do: :ctrl_p
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
