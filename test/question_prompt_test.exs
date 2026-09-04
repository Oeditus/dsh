defmodule DeepSeekHarness.CLI.QuestionPromptTest do
  # Not async: tests capture global :user IO device output
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias DeepSeekHarness.CLI.QuestionPrompt
  alias DeepSeekHarness.Plugin.DefaultTools

  describe "QuestionPrompt pure state operations" do
    test "initializes fresh state with cursor at 0" do
      state = QuestionPrompt.new_state("Which framework?", ["Phoenix", "Absinthe"], false, 2)

      assert state.cursor == 0
      assert state.question == "Which framework?"
      assert length(state.options) == 2
      assert state.custom_idx == 2
      assert MapSet.size(state.selected) == 0
    end

    test "moves cursor up and down with wrapping" do
      state = QuestionPrompt.new_state("Question", ["A", "B", "C"], false, 3)

      state = QuestionPrompt.move_down(state)
      assert state.cursor == 1

      state = QuestionPrompt.move_down(state)
      assert state.cursor == 2

      state = QuestionPrompt.move_down(state)
      assert state.cursor == 0

      state = QuestionPrompt.move_up(state)
      assert state.cursor == 2
    end

    test "toggles selection in multi-select mode" do
      state = QuestionPrompt.new_state("Question", ["A", "B"], true, 2)

      state = QuestionPrompt.toggle_selection(state)
      assert MapSet.member?(state.selected, 0)

      state = QuestionPrompt.toggle_selection(state)
      refute MapSet.member?(state.selected, 0)
    end

    test "selects index directly" do
      state = QuestionPrompt.new_state("Question", ["A", "B", "C"], false, 3)

      state = QuestionPrompt.select_index(state, 2)
      assert state.cursor == 2

      # Out of bounds ignored
      state = QuestionPrompt.select_index(state, 10)
      assert state.cursor == 2
    end

    test "renders modal and wraps long option text across multiple lines" do
      long_opt =
        "Allow execution of bash commands for this specific session and save to project config"

      state = QuestionPrompt.new_state("Confirm?", [long_opt], false, 1)
      updated_state = QuestionPrompt.render_modal(state)

      # Header + blank + q_line + blank + 2 wrapped option lines + blank + footer = 8 lines (7 linebreaks)
      assert updated_state.rendered_lines == 7
    end

    test "strips duplicate leading numbers from option labels" do
      state =
        QuestionPrompt.new_state(
          "Select options:",
          ["1. First option", "2. Second option"],
          false,
          2
        )

      updated_state = QuestionPrompt.render_modal(state)
      assert updated_state.rendered_lines > 0
    end

    test "shows a plain header when no progress is given" do
      state = QuestionPrompt.new_state("Confirm?", ["Yes", "No"], false, 2)
      output = capture_io(:user, fn -> QuestionPrompt.render_modal(state) end)

      assert output =~ "Question from AI"
      refute output =~ "Question 1/1 from AI"
    end

    test "shows a Question i/N header when progress is given for a multi-question batch" do
      state = QuestionPrompt.new_state("Confirm?", ["Yes", "No"], false, 2, true, {2, 3})
      output = capture_io(:user, fn -> QuestionPrompt.render_modal(state) end)

      assert output =~ "Question 2/3 from AI"
    end

    test "omits the progress count when there is only a single question" do
      state = QuestionPrompt.new_state("Confirm?", ["Yes", "No"], false, 2, true, {1, 1})
      output = capture_io(:user, fn -> QuestionPrompt.render_modal(state) end)

      refute output =~ "1/1"
      assert output =~ "Question from AI"
    end

    test "erase?: false skips the modal's own erase of its prior render" do
      state = QuestionPrompt.new_state("Confirm?", ["Yes", "No"], false, 2)
      rendered = QuestionPrompt.render_modal(state)

      with_erase = capture_io(:user, fn -> QuestionPrompt.render_modal(rendered) end)

      without_erase =
        capture_io(:user, fn -> QuestionPrompt.render_modal(rendered, erase?: false) end)

      assert with_erase =~ "\e[#{rendered.rendered_lines}A\e[0J"
      refute without_erase =~ "\e[#{rendered.rendered_lines}A\e[0J"
    end
  end

  describe "QuestionPrompt answer formatting" do
    test "formats standard selected options answer as JSON" do
      q = "Select target database:"
      ans = %{selected: ["PostgreSQL", "SQLite"]}
      formatted = QuestionPrompt.format_answer(q, ans)
      assert {:ok, decoded} = Jason.decode(formatted)

      assert decoded["question"] == "Select target database:"
      assert decoded["selected_options"] == ["PostgreSQL", "SQLite"]
      assert decoded["status"] == "answered"
    end

    test "formats custom written response answer as JSON" do
      q = "What features to add?"
      ans = %{selected: ["Auth"], custom: "GraphQL API"}
      formatted = QuestionPrompt.format_answer(q, ans)
      assert {:ok, decoded} = Jason.decode(formatted)

      assert decoded["question"] == "What features to add?"
      assert decoded["selected_options"] == ["Auth"]
      assert decoded["custom_response"] == "GraphQL API"
    end

    test "formats cancelled answer as JSON" do
      q = "Confirm deployment?"
      ans = %{cancelled: true}
      formatted = QuestionPrompt.format_answer(q, ans)
      assert {:ok, decoded} = Jason.decode(formatted)

      assert decoded["question"] == "Confirm deployment?"
      assert decoded["status"] == "cancelled"
    end
  end

  describe "DefaultTools ask_question tool integration" do
    test "ask_question tool is registered in DefaultTools" do
      tools = DefaultTools.tools()
      ask_tool = Enum.find(tools, &(&1.name == "ask_question"))

      assert ask_tool != nil
      assert ask_tool.description =~ "Ask the user one or more multiple-choice questions"
    end

    test "returns error on invalid arguments" do
      assert {:error, msg} = DefaultTools.ask_question(%{})
      assert msg =~ "Invalid arguments"
    end
  end

  describe "God Mode auto-answering" do
    setup do
      Application.put_env(:deep_seek_harness, :god_mode, true)
      on_exit(fn -> Application.delete_env(:deep_seek_harness, :god_mode) end)
      :ok
    end

    test "ask_single_question automatically selects first/recommended option in God mode" do
      res = QuestionPrompt.ask_single_question("Which option?", ["Option A", "Option B"])
      assert res == %{selected: ["Option A"]}

      res_rec =
        QuestionPrompt.ask_single_question("Which framework?", [
          "Phoenix",
          "(Recommended) Absinthe"
        ])

      assert res_rec == %{selected: ["(Recommended) Absinthe"]}
    end

    test "DefaultTools.ask_question returns auto-answered JSON without prompting user in God mode" do
      args = %{
        "questions" => [
          %{"question" => "Continue build?", "options" => ["Yes", "No"]}
        ]
      }

      assert {:ok, json} = DefaultTools.ask_question(args)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["status"] == "answered"
      assert decoded["selected_options"] == ["Yes"]
    end
  end
end
