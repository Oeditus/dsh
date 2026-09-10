defmodule Yoke.CLI.ConfigExplorerTest do
  use ExUnit.Case, async: true

  alias Yoke.CLI.ConfigExplorer

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "explorer_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, ".yoke/sessions"))
    File.mkdir_p!(Path.join(tmp_dir, ".yoke/practices"))
    File.mkdir_p!(Path.join(tmp_dir, ".yoke/jobs"))

    # Seed test files
    File.write!(Path.join(tmp_dir, ".yoke/config.json"), "{\"model\": \"deepseek-chat\", \"god_mode\": false}")
    File.write!(Path.join(tmp_dir, ".yoke/sessions/test_sess.lmml"), "# Session Log")
    File.write!(Path.join(tmp_dir, ".yoke/practices/elixir.lmml"), "# Elixir Practice")
    File.write!(Path.join(tmp_dir, ".yoke/jobs/job_101.log"), "Starting job...")
    File.write!(Path.join(tmp_dir, ".yoke/ERRORS_TO_FIX.lmml"), "<!-- error_entry -->\n## Test Error")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "directory scanning & summary" do
    test "scans directory tree correctly", %{tmp_dir: tmp_dir} do
      tree = ConfigExplorer.scan_directory_tree(tmp_dir)

      assert is_map(tree.config)
      assert tree.config["model"] == "deepseek-chat"

      assert length(tree.sessions) == 1
      assert hd(tree.sessions).id == "test_sess"

      assert length(tree.jobs) == 1
      assert hd(tree.jobs).id == "job_101"

      assert tree.errors.count == 1
    end

    test "formats non-TTY summary cleanly", %{tmp_dir: tmp_dir} do
      tree = ConfigExplorer.scan_directory_tree(tmp_dir)
      summary = ConfigExplorer.format_non_tty_summary(tree)

      assert String.contains?(summary, "Yoke Config Directory Explorer Summary")
      assert String.contains?(summary, "deepseek-chat")
      assert String.contains?(summary, "1 files in .yoke/sessions/")
    end
  end

  describe "state navigation & tab switching" do
    test "initializes state and switches tabs", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      assert state.active_tab == :settings
      assert state.tab_index == 0

      state = ConfigExplorer.switch_tab(state, 1)
      assert state.active_tab == :rules
      assert state.tab_index == 1

      state = ConfigExplorer.switch_tab(state, 1)
      assert state.active_tab == :sessions
    end

    test "moves cursor within tab boundaries", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      state = ConfigExplorer.move_cursor(state, 1)
      assert state.cursor == 1

      state = ConfigExplorer.move_cursor(state, -1)
      assert state.cursor == 0
    end
  end

  describe "toggles and deletions" do
    test "toggles boolean setting in config tab", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      # Find index of 'god_mode' in sorted config keys
      keys = Enum.sort(Map.keys(state.tree.config))
      god_idx = Enum.find_index(keys, &(&1 == "god_mode"))

      state = %{state | cursor: god_idx}
      updated_state = ConfigExplorer.handle_toggle(state)

      assert updated_state.tree.config["god_mode"] == true
    end

    test "clears errors in diagnostics tab", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      state = %{state | active_tab: :diagnostics}

      updated_state = ConfigExplorer.handle_delete(state)
      assert updated_state.tree.errors.count == 0
      assert File.read!(Path.join(tmp_dir, ".yoke/ERRORS_TO_FIX.lmml")) == ""
    end
  end
end
