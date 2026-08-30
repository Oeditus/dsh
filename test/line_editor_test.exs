defmodule DeepSeekHarness.LineEditorTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.LineEditor

  describe "prompt building" do
    test "builds prompt string with configurable interpolation" do
      prompt = LineEditor.build_prompt("main", "deepseek-chat", :local)
      assert String.contains?(prompt, "deepseek-chat")
    end

    test "supports extended prompt style" do
      # `prompt_style` is read from `.dsh/config.json` (via DeepSeekHarness.Config),
      # not from Application env, so exercise the real config-file mechanism
      # against an isolated temp workspace instead of the user's real config.
      tmp_dir =
        Path.join(System.tmp_dir!(), "dsh_test_cfg_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, ".dsh"))
      File.write!(Path.join(tmp_dir, ".dsh/config.json"), ~s({"prompt_style": "extended"}))
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      prompt =
        LineEditor.build_prompt("02ec14fa-0fae-62b0-9b52", "deepseek-chat", :local, tmp_dir)

      assert String.contains?(prompt, "deepseek-chat")
      assert String.contains?(prompt, "id:02ec14fa")
    end
  end

  describe "persistent history" do
    test "loads and appends persistent history safely" do
      assert is_list(LineEditor.load_history())
      LineEditor.add_history("test_command_123")
      history = LineEditor.load_history()
      assert "test_command_123" in history
    end

    test "loads history most-recent-first, matching in-memory prepend order" do
      LineEditor.add_history("first_recorded_#{System.unique_integer([:positive])}")
      LineEditor.add_history("second_recorded_#{System.unique_integer([:positive])}")
      [most_recent | _rest] = LineEditor.load_history()
      assert String.starts_with?(most_recent, "second_recorded_")
    end
  end

  describe "cursor navigation" do
    test "moves cursor left and right without corrupting the buffer" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 3}

      assert LineEditor.move_left(state).cursor == 2
      assert LineEditor.move_right(state).cursor == 4

      assert LineEditor.move_left(%{state | cursor: 0}).cursor == 0
      assert LineEditor.move_right(%{state | cursor: 5}).cursor == 5
    end

    test "jumps to start and end of line" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 2}

      assert LineEditor.move_to_start(state).cursor == 0
      assert LineEditor.move_to_end(state).cursor == 5
    end

    test "backspace deletes the grapheme left of the cursor" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 3}
      result = LineEditor.delete_backward(state)

      assert result.buffer == String.graphemes("helo")
      assert result.cursor == 2

      unchanged = LineEditor.delete_backward(%{state | cursor: 0})
      assert unchanged.buffer == String.graphemes("hello")
      assert unchanged.cursor == 0
    end

    test "delete removes the grapheme at the cursor" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 1}
      result = LineEditor.delete_forward(state)

      assert result.buffer == String.graphemes("hllo")
      assert result.cursor == 1

      at_end = %{state | cursor: 5}
      assert LineEditor.delete_forward(at_end).buffer == String.graphemes("hello")
    end

    test "ctrl+u clears left of the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("hello world"),
          cursor: 6
      }

      result = LineEditor.kill_to_start(state)

      assert result.buffer == String.graphemes("world")
      assert result.cursor == 0
    end

    test "ctrl+k clears right of the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("hello world"),
          cursor: 5
      }

      result = LineEditor.kill_to_end(state)

      assert result.buffer == String.graphemes("hello")
      assert result.cursor == 5
    end

    test "ctrl+w deletes the word behind the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("git commit "),
          cursor: 11
      }

      result = LineEditor.delete_word_backward(state)

      assert Enum.join(result.buffer) == "git "
      assert result.cursor == 4
    end

    test "inserts unicode graphemes and keeps combining marks clustered" do
      state =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("é")
        |> LineEditor.insert_char("ñ")

      assert state.buffer == String.graphemes("éñ")
      assert state.cursor == 2

      # A base char followed by a combining accent should merge into one
      # grapheme cluster even though they arrive as separate keystrokes.
      combining_accent = <<0x0301::utf8>>
      composed = "e" <> combining_accent

      merged =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("e")
        |> LineEditor.insert_char(combining_accent)

      assert merged.buffer == String.graphemes(composed)
      assert length(merged.buffer) == 1
    end
  end

  describe "history navigation" do
    test "navigates history up and down, preserving uncommitted input" do
      history = ["cmd_two", "cmd_one"]
      state = %{LineEditor.new_state("prompt> ", history) | buffer: String.graphemes("draft")}

      up_state = LineEditor.history_navigate(state, :up)
      assert up_state.hist_idx == 0
      assert up_state.buffer == String.graphemes("cmd_two")
      assert up_state.saved_buffer == String.graphemes("draft")

      up_again = LineEditor.history_navigate(up_state, :up)
      assert up_again.hist_idx == 1
      assert up_again.buffer == String.graphemes("cmd_one")

      # Cannot go further back than the oldest entry.
      assert LineEditor.history_navigate(up_again, :up) == up_again

      down_state = LineEditor.history_navigate(up_again, :down)
      assert down_state.hist_idx == 0
      assert down_state.buffer == String.graphemes("cmd_two")

      restored = LineEditor.history_navigate(down_state, :down)
      assert restored.hist_idx == -1
      assert restored.buffer == String.graphemes("draft")
    end
  end

  describe "reverse-incremental search" do
    test "finds items in history by substring" do
      history = ["git status", "mix test", "dsh review"]
      assert LineEditor.find_in_history("git", history) == "git status"
      assert LineEditor.find_in_history("xyz", history) == ""
      assert LineEditor.find_in_history("", history) == ""
    end

    test "cycles through multiple matches via offset" do
      history = ["mix test", "git commit", "git status"]
      assert LineEditor.find_in_history("git", history, 0) == "git commit"
      assert LineEditor.find_in_history("git", history, 1) == "git status"
      assert LineEditor.find_in_history("git", history, 2) == ""
    end

    test "toggles search mode on and is idempotent while already active" do
      state = LineEditor.new_state("prompt> ")
      activated = LineEditor.toggle_reverse_search(state)

      assert activated.search_mode == true
      assert activated.search_query == []
      assert LineEditor.toggle_reverse_search(activated) == activated
    end
  end

  describe "Ctrl+J newline insertion" do
    test "insert_newline/1 inserts a literal newline at the cursor without submitting" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 5}
      result = LineEditor.insert_newline(state)

      assert Enum.join(result.buffer) == "hello\n"
      assert result.cursor == 6
    end

    test "insert_newline/1 splits the buffer when the cursor is mid-line" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("abcd"), cursor: 2}
      result = LineEditor.insert_newline(state)

      assert Enum.join(result.buffer) == "ab\ncd"
      assert result.cursor == 3
    end

    test "a multi-line buffer joins into one logical string with embedded newlines" do
      state =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("a")
        |> LineEditor.insert_newline()
        |> LineEditor.insert_char("b")

      assert Enum.join(state.buffer) == "a\nb"
    end
  end

  describe "multi-line layout math" do
    test "layout_rows/3 counts a single row for short single-line text" do
      assert LineEditor.layout_rows(8, "hello", 80) == 1
    end

    test "layout_rows/3 counts one additional row per embedded hard newline" do
      assert LineEditor.layout_rows(8, "line one\nline two\nline three", 80) == 3
    end

    test "layout_rows/3 also accounts for soft, width-based wrapping" do
      # Starting at column 0 in an 8-column terminal, a 20-character line
      # wraps across 3 rows (8 + 8 + 4).
      assert LineEditor.layout_rows(0, String.duplicate("x", 20), 8) == 3
    end

    test "layout_rows/3 combines hard breaks with soft wraps across segments" do
      # First segment starts at column 5 in a 10-column terminal ("first"
      # fits within the remaining 5 columns on row 0); second segment
      # starts fresh at column 0 and wraps once (12 chars / 10 cols).
      text = "first\n" <> String.duplicate("y", 12)
      assert LineEditor.layout_rows(5, text, 10) == 3
    end

    test "layout_rows/3 is ANSI-safe (escape codes don't inflate the row count)" do
      plain = LineEditor.layout_rows(0, "hello world", 80)
      ansi = LineEditor.layout_rows(0, "\e[36mhello\e[0m world", 80)
      assert plain == ansi
    end

    test "layout_cursor/4 finds the cursor on a single line" do
      assert LineEditor.layout_cursor(8, "hello", 3, 80) == {0, 11}
    end

    test "layout_cursor/4 finds the cursor on a later line after a hard newline" do
      # "ab\ncd", cursor offset 4 -> after "c" on the second line (row 1).
      assert LineEditor.layout_cursor(0, "ab\ncd", 4, 80) == {1, 1}
    end

    test "layout_cursor/4 places the cursor at the end of a line when it sits right before a hard newline" do
      # "ab\ncd", cursor offset 2 -> right after "ab", still row 0.
      assert LineEditor.layout_cursor(0, "ab\ncd", 2, 80) == {0, 2}
    end

    test "layout_cursor/4 accounts for soft wrapping when locating the cursor" do
      # 12 'x' chars in an 8-column terminal wrap after column 8; cursor at
      # offset 10 sits on the second wrapped row, column 2.
      text = String.duplicate("x", 12)
      assert LineEditor.layout_cursor(0, text, 10, 8) == {1, 2}
    end
  end

  describe "history persistence with embedded newlines" do
    test "round-trips a multi-line entry without corrupting the history file" do
      unique = System.unique_integer([:positive])
      multiline = "first line #{unique}\nsecond line #{unique}"

      LineEditor.add_history(multiline)
      history = LineEditor.load_history()

      assert multiline in history
      # The embedded newline must not have been split into two separate entries.
      refute "first line #{unique}" in history
      refute "second line #{unique}" in history
    end

    test "round-trips an entry containing a literal backslash" do
      unique = System.unique_integer([:positive])
      line = "regex \\d+ test #{unique}"

      LineEditor.add_history(line)
      history = LineEditor.load_history()

      assert line in history
    end
  end

  describe "tab completion" do
    test "completes a unique slash command match" do
      assert {:ok, "/ragex"} = LineEditor.tab_complete("/ra")
      # "/re" alone is ambiguous between "/resume" and "/review"; "/rev" is the
      # shortest unambiguous prefix that resolves to "/review".
      assert {:ok, "/review"} = LineEditor.tab_complete("/rev")
      assert {:ok, "/checkpoint"} = LineEditor.tab_complete("/ch")
      assert {:ok, "/plugins"} = LineEditor.tab_complete("/pl")
    end

    test "extends to the common prefix when ambiguous but extendable" do
      assert {:ok, "/skill"} = LineEditor.tab_complete("/sk")
      assert {:ok, "/mode"} = LineEditor.tab_complete("/mod")
    end

    test "reports ambiguity when the common prefix cannot be extended" do
      assert {:ambiguous, matches} = LineEditor.tab_complete("/m")
      assert "/mcp" in matches
      assert "/mode" in matches
      assert "/model" in matches
    end

    test "returns :none for input with no matches or non-slash input" do
      assert :none = LineEditor.tab_complete("not_a_slash_cmd")
      assert :none = LineEditor.tab_complete("/zzz")
    end
  end

  describe "syntax highlighting and ghost suggestions" do
    test "highlights slash commands and shell commands" do
      cfg = %{"enable_syntax_highlighting" => true}
      assert LineEditor.highlight_input("/model chat", cfg) =~ "model"
      assert LineEditor.highlight_input("!git status", cfg) =~ "git status"
    end

    test "computes ghost auto-suggestions from history" do
      cfg = %{"enable_autosuggestions" => true}
      history = ["git commit -m 'fix'"]
      assert LineEditor.get_ghost_suggestion("git com", history, cfg) == "mit -m 'fix'"
    end

    test "calculates physical terminal display width of prompts with Nerd Font symbols" do
      prompt_str = "\e[36m󰉋 ragec\e[0m \e[32m󰚩 deepseek-chat\e[0m ❯ "

      raw_len = String.length(String.replace(prompt_str, ~r/\e\[[0-9;]*[mGKH]/, ""))
      width = LineEditor.display_width(prompt_str)

      assert width >= raw_len
    end
  end

  describe "status bar width safety net" do
    test "leaves content untouched when it already fits within max_width" do
      short = "\e[36mhello\e[0m"
      assert LineEditor.truncate_to_width(short, 80) == short
    end

    test "never returns a string wider than max_width, even for long ANSI content" do
      # Simulates a status bar segment (e.g. the token/cost gauge) that grew
      # past the terminal width, such as when a process count crosses into
      # double digits and pushes previously-borderline content over the edge.
      long =
        "\e[32m[████████░░░░░░░░] 75%\e[0m " <>
          "\e[2m(12000/64000 tokens\e[0m \e[32m(+500)\e[0m " <>
          "\e[2m| $0.1234 USD | ⚡ 12 procs serving)\e[0m"

      for max_width <- [10, 20, 40, 79, 80] do
        truncated = LineEditor.truncate_to_width(long, max_width)
        assert LineEditor.display_width(truncated) <= max_width
      end
    end

    test "never exceeds max_width even when the budget is smaller than 1" do
      assert LineEditor.truncate_to_width("anything", 0) == ""
    end

    test "preserves embedded ANSI escapes without splitting them mid-sequence" do
      long = String.duplicate("a", 50) <> "\e[31m" <> String.duplicate("b", 50) <> "\e[0m"
      truncated = LineEditor.truncate_to_width(long, 30)

      assert LineEditor.display_width(truncated) <= 30
      # Every remaining escape sequence must be well-formed (fully matched by
      # the escape regex); stripping them should leave no stray `\e` bytes.
      stripped = String.replace(truncated, ~r/\e\[[0-9;]*[mGKH]/, "")
      refute stripped =~ "\e"
    end
  end
end
