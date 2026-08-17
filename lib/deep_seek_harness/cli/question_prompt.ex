defmodule DeepSeekHarness.CLI.QuestionPrompt do
  @moduledoc """
  Interactive TUI Question Modal & User Feedback UI for DeepSeek Harness.

  Renders Warp / AGY styled terminal menus for asking single-choice or
  multi-choice questions to the user during agent execution.
  """
  alias DeepSeekHarness.CLI.Formatter

  @doc """
  Main entry point to ask a list of questions to the user and return formatted answers.
  """
  def ask(questions) when is_list(questions) do
    answers =
      Enum.map(questions, fn q ->
        question_text = Map.get(q, "question") || Map.get(q, :question, "")
        options = Map.get(q, "options") || Map.get(q, :options, [])
        is_multi = Map.get(q, "is_multi_select") || Map.get(q, :is_multi_select, false)

        ans = ask_single_question(question_text, options, is_multi)
        format_answer(question_text, ans)
      end)

    Enum.join(answers, "\n\n")
  end

  def ask(_), do: "No questions provided."

  @doc "Asks a single question and returns choice result map."
  def ask_single_question(question, options, is_multi) do
    options = if is_list(options) and options != [], do: options, else: ["Yes", "No"]
    all_options = options ++ ["Write custom response..."]
    custom_idx = length(all_options) - 1

    if tty?() do
      prompt_tty(question, all_options, is_multi, custom_idx)
    else
      prompt_non_tty(question, all_options, is_multi, custom_idx)
    end
  end

  # ---------------------------------------------------------------------
  # Pure state management (unit-testable)
  # ---------------------------------------------------------------------

  def new_state(question, options, is_multi, custom_idx) do
    %{
      question: question,
      options: options,
      is_multi: is_multi,
      custom_idx: custom_idx,
      cursor: 0,
      selected: MapSet.new(),
      rendered_lines: 0
    }
  end

  def move_up(%{cursor: cursor, options: options} = state) do
    new_cursor = if cursor > 0, do: cursor - 1, else: length(options) - 1
    %{state | cursor: new_cursor}
  end

  def move_down(%{cursor: cursor, options: options} = state) do
    new_cursor = if cursor < length(options) - 1, do: cursor + 1, else: 0
    %{state | cursor: new_cursor}
  end

  def toggle_selection(%{cursor: cursor, selected: selected, is_multi: true} = state) do
    new_selected =
      if MapSet.member?(selected, cursor) do
        MapSet.delete(selected, cursor)
      else
        MapSet.put(selected, cursor)
      end

    %{state | selected: new_selected}
  end

  def toggle_selection(state), do: state

  def select_index(%{options: options} = state, idx) when idx >= 0 and idx < length(options) do
    %{state | cursor: idx}
  end

  def select_index(state, _), do: state

  # ---------------------------------------------------------------------
  # Formatting results
  # ---------------------------------------------------------------------

  def format_answer(question, %{cancelled: true}) do
    Jason.encode!(%{
      "question" => question,
      "status" => "cancelled",
      "selected_options" => [],
      "custom_response" => nil
    })
  end

  def format_answer(question, %{selected: selected, custom: custom}) when is_binary(custom) do
    Jason.encode!(%{
      "question" => question,
      "status" => "answered",
      "selected_options" => selected,
      "custom_response" => custom
    })
  end

  def format_answer(question, %{selected: selected}) when is_list(selected) do
    Jason.encode!(%{
      "question" => question,
      "status" => "answered",
      "selected_options" => selected,
      "custom_response" => nil
    })
  end

  # ---------------------------------------------------------------------
  # TTY Interactive Raw Loop
  # ---------------------------------------------------------------------

  defp tty? do
    case :io.columns() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp prompt_tty(question, options, is_multi, custom_idx) do
    set_raw_mode()
    state = new_state(question, options, is_multi, custom_idx)

    try do
      result = tui_loop(state)
      restore_tty_mode()
      IO.puts("")
      result
    catch
      _kind, _err ->
        restore_tty_mode()
        prompt_non_tty(question, options, is_multi, custom_idx)
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

  defp tui_loop(state) do
    state = render_modal(state)

    case read_key() do
      :up ->
        tui_loop(move_up(state))

      :down ->
        tui_loop(move_down(state))

      :space ->
        tui_loop(toggle_selection(state))

      {:char, char_code} when char_code >= ?1 and char_code <= ?9 ->
        idx = char_code - ?1
        tui_loop(select_index(state, idx))

      :enter ->
        handle_confirm(state)

      :ctrl_c ->
        %{cancelled: true, selected: []}

      _ ->
        tui_loop(state)
    end
  end

  defp handle_confirm(state) do
    if state.cursor == state.custom_idx do
      # User selected write-in custom response
      restore_tty_mode()
      IO.puts("\n" <> Formatter.cyan() <> "✏️  Enter custom response: " <> Formatter.reset())

      custom_input =
        case IO.gets("") do
          line when is_binary(line) -> String.trim(line)
          _ -> ""
        end

      chosen_standard =
        state.selected
        |> Enum.reject(&(&1 == state.custom_idx))
        |> Enum.map(&Enum.at(state.options, &1))

      %{selected: chosen_standard, custom: custom_input}
    else
      if state.is_multi do
        selected_set =
          if MapSet.size(state.selected) == 0 do
            MapSet.new([state.cursor])
          else
            state.selected
          end

        chosen =
          selected_set
          |> Enum.reject(&(&1 == state.custom_idx))
          |> Enum.map(&Enum.at(state.options, &1))

        %{selected: chosen}
      else
        chosen = Enum.at(state.options, state.cursor)
        %{selected: [chosen]}
      end
    end
  end

  # ---------------------------------------------------------------------
  # TUI Box Renderer
  # ---------------------------------------------------------------------

  def render_modal(state) do
    box_width = 72

    if state.rendered_lines > 0 do
      # Move cursor up and clear lines
      IO.write("\e[#{state.rendered_lines}A\e[0J")
    end

    header_title = " ❓ Question from AI "

    header_padding =
      String.duplicate("─", max(0, box_width - String.length(header_title) - 2))

    header =
      "#{Formatter.cyan()}╭─#{Formatter.bold()}#{header_title}#{Formatter.reset()}#{Formatter.cyan()}#{header_padding}╮#{Formatter.reset()}"

    footer_text =
      if state.is_multi do
        "[↑/↓ or 1-#{length(state.options)}: Navigate | Space: Toggle | Enter: Confirm]"
      else
        "[↑/↓ or 1-#{length(state.options)}: Select | Enter: Confirm]"
      end

    footer_padding =
      String.duplicate("─", max(0, box_width - String.length(footer_text) - 2))

    footer =
      "#{Formatter.cyan()}╰─#{Formatter.dim()}#{footer_text}#{Formatter.reset()}#{Formatter.cyan()}#{footer_padding}╯#{Formatter.reset()}"

    blank_line =
      "#{Formatter.cyan()}│#{Formatter.reset()}#{String.duplicate(" ", box_width)}#{Formatter.cyan()}│#{Formatter.reset()}"

    q_wrapped = wrap_text(state.question, box_width - 4)

    q_lines =
      Enum.map(q_wrapped, fn line ->
        pad = String.duplicate(" ", max(0, box_width - String.length(line) - 4))

        "#{Formatter.cyan()}│#{Formatter.reset()}  #{Formatter.bold()}#{line}#{Formatter.reset()}#{pad}  #{Formatter.cyan()}│#{Formatter.reset()}"
      end)

    opt_lines =
      state.options
      |> Enum.with_index()
      |> Enum.map(fn {opt, idx} ->
        is_current = idx == state.cursor
        is_checked = MapSet.member?(state.selected, idx)
        is_custom = idx == state.custom_idx

        prefix =
          cond do
            state.is_multi and is_checked -> "[✓] "
            state.is_multi -> "[ ] "
            true -> ""
          end

        label =
          if is_custom do
            "#{prefix}#{idx + 1}. ✏️  #{opt}"
          else
            "#{prefix}#{idx + 1}. #{opt}"
          end

        {pointer, styled_label} =
          if is_current do
            {"❯ ", "#{Formatter.green()}#{Formatter.bold()}#{label}#{Formatter.reset()}"}
          else
            {"  ", "#{Formatter.dim()}#{label}#{Formatter.reset()}"}
          end

        raw_label = " #{pointer}#{label}"
        pad = String.duplicate(" ", max(0, box_width - String.length(raw_label) - 2))

        "#{Formatter.cyan()}│#{Formatter.reset()} #{pointer}#{styled_label}#{pad} #{Formatter.cyan()}│#{Formatter.reset()}"
      end)

    lines =
      [header] ++
        [blank_line] ++
        q_lines ++ [blank_line] ++ opt_lines ++ [blank_line] ++ [footer]

    IO.puts(Enum.join(lines, "\n"))
    %{state | rendered_lines: length(lines)}
  end

  defp wrap_text(text, max_len) do
    words = String.split(text, ~r/\s+/)

    Enum.reduce(words, {[], ""}, fn word, {acc, current} ->
      cond do
        current == "" ->
          {acc, word}

        String.length(current) + 1 + String.length(word) <= max_len ->
          {acc, current <> " " <> word}

        true ->
          {acc ++ [current], word}
      end
    end)
    |> then(fn {acc, last} -> if last != "", do: acc ++ [last], else: acc end)
  end

  # ---------------------------------------------------------------------
  # Non-TTY Fallback Prompt
  # ---------------------------------------------------------------------

  defp prompt_non_tty(question, options, _is_multi, custom_idx) do
    IO.puts("\n" <> Formatter.cyan() <> "❓ Question from AI: " <> Formatter.bold() <> question <> Formatter.reset())

    options
    |> Enum.with_index()
    |> Enum.each(fn {opt, idx} ->
      tag = if idx == custom_idx, do: "✏️  #{opt}", else: opt
      IO.puts("  #{idx + 1}. #{tag}")
    end)

    input =
      case IO.gets("Select option number (1-#{length(options)}) or enter response: ") do
        str when is_binary(str) -> String.trim(str)
        _ -> ""
      end

    case Integer.parse(input) do
      {num, ""} when num >= 1 and num <= length(options) ->
        idx = num - 1

        if idx == custom_idx do
          custom_val = IO.gets("Enter custom response: ") |> to_string() |> String.trim()
          %{selected: [], custom: custom_val}
        else
          %{selected: [Enum.at(options, idx)]}
        end

      _ ->
        %{selected: [], custom: input}
    end
  end

  # ---------------------------------------------------------------------
  # Key Reader (using standard BEAM term reading)
  # ---------------------------------------------------------------------

  defp read_key do
    case IO.getn("", 1) do
      "\e" ->
        case IO.getn("", 2) do
          "[A" -> :up
          "[B" -> :down
          "[C" -> :right
          "[D" -> :left
          _ -> :escape
        end

      "\n" ->
        :enter

      "\r" ->
        :enter

      " " ->
        :space

      "\x03" ->
        :ctrl_c

      <<char_code::utf8>> ->
        {:char, char_code}

      _ ->
        :unknown
    end
  end
end
