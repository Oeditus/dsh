defmodule Yoke.CLI.ConfigExplorer do
  @moduledoc """
  Interactive TUI Explorer for navigating, inspecting, and updating the `.yoke`
  configuration directory ecosystem (.yoke/config.json, rules.json, practices/,
  sessions/, jobs/, ERRORS_TO_FIX.lmml, and skills).

  Provides a Warp-styled tabbed terminal UI for examining and managing all local
  and global Yoke workspace settings, prompt rules, conversation logs, and diagnostic files.
  """
  alias Yoke.CLI.Formatter
  alias Yoke.CLI.TerminalOwner
  alias Yoke.Config
  alias Yoke.Rules

  @tabs [:settings, :rules, :sessions, :practices, :jobs, :diagnostics]

  @doc """
  Main entry point to launch the interactive Config Directory Explorer TUI.
  """
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    if tty?() do
      run_tty(cwd, opts)
    else
      run_non_tty(cwd, opts)
    end
  end

  # ---------------------------------------------------------------------
  # Data Loading & Scanning Helpers
  # ---------------------------------------------------------------------

  @doc "Scans local and global .yoke directory tree and returns summary map."
  def scan_directory_tree(cwd \\ ".") do
    local_dir = Path.join(cwd, ".yoke")
    global_dir = Path.expand("~/.yoke")

    config = Config.load_config(cwd)
    rules = Rules.load_rules(cwd)
    sessions = list_session_files(cwd)
    practices = list_practice_files(cwd)
    jobs = list_job_files(cwd)
    errors = read_error_log(cwd)

    %{
      local_dir: local_dir,
      global_dir: global_dir,
      config: config,
      rules: rules,
      sessions: sessions,
      practices: practices,
      jobs: jobs,
      errors: errors
    }
  end

  def list_session_files(cwd \\ ".") do
    dir = Path.join(cwd, ".yoke/sessions")

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&(String.ends_with?(&1, ".lmml") or String.ends_with?(&1, ".lmmlz")))
          |> Enum.map(fn file ->
            full_path = Path.join(dir, file)
            stat = File.stat!(full_path)
            id = String.replace(file, ~r/\.(lmml|lmmlz)$/, "")

            %{
              id: id,
              file: file,
              path: full_path,
              size: stat.size,
              mtime: stat.mtime
            }
          end)
          |> Enum.sort_by(& &1.mtime, :desc)

        _ ->
          []
      end
    else
      []
    end
  end

  def list_practice_files(cwd \\ ".") do
    local_dir = Path.join(cwd, ".yoke/practices")
    global_dir = Path.expand("~/.yoke/practices")

    local_files =
      if File.dir?(local_dir), do: File.ls!(local_dir) |> Enum.map(&{:local, &1, Path.join(local_dir, &1)}), else: []

    global_files =
      if File.dir?(global_dir), do: File.ls!(global_dir) |> Enum.map(&{:global, &1, Path.join(global_dir, &1)}), else: []

    (local_files ++ global_files)
    |> Enum.filter(fn {_scope, f, _path} -> String.ends_with?(f, ".lmml") end)
    |> Enum.map(fn {scope, file, path} ->
      lang = String.replace(file, ".lmml", "")
      %{scope: scope, lang: lang, file: file, path: path}
    end)
  end

  def list_job_files(cwd \\ ".") do
    dir = Path.join(cwd, ".yoke/jobs")

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".log"))
          |> Enum.map(fn file ->
            full_path = Path.join(dir, file)
            stat = File.stat!(full_path)
            id = String.replace(file, ".log", "")

            %{
              id: id,
              file: file,
              path: full_path,
              size: stat.size,
              mtime: stat.mtime
            }
          end)
          |> Enum.sort_by(& &1.mtime, :desc)

        _ ->
          []
      end
    else
      []
    end
  end

  def read_error_log(cwd \\ ".") do
    file_path = Path.join(cwd, ".yoke/ERRORS_TO_FIX.lmml")

    if File.exists?(file_path) do
      content = File.read!(file_path)

      entries =
        content
        |> String.split("<!-- error_entry -->", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      %{file_path: file_path, count: length(entries), content: content, entries: entries}
    else
      %{file_path: file_path, count: 0, content: "", entries: []}
    end
  end

  # ---------------------------------------------------------------------
  # TUI State & Controller
  # ---------------------------------------------------------------------

  def new_state(cwd) do
    tree = scan_directory_tree(cwd)

    %{
      cwd: cwd,
      active_tab: :settings,
      tab_index: 0,
      tree: tree,
      cursor: 0,
      rendered_lines: 0,
      status_notice: nil
    }
  end

  def switch_tab(state, delta) do
    new_idx = Integer.mod(state.tab_index + delta, length(@tabs))
    new_tab = Enum.at(@tabs, new_idx)
    %{state | tab_index: new_idx, active_tab: new_tab, cursor: 0, status_notice: nil}
  end

  def move_cursor(state, delta) do
    max_idx = max(0, item_count(state) - 1)
    new_cursor = Integer.mod(state.cursor + delta, max(1, max_idx + 1))
    %{state | cursor: new_cursor}
  end

  def item_count(%{active_tab: :settings, tree: tree}) do
    map_size(tree.config)
  end

  def item_count(%{active_tab: :rules, tree: tree}) do
    length(tree.rules)
  end

  def item_count(%{active_tab: :sessions, tree: tree}) do
    length(tree.sessions)
  end

  def item_count(%{active_tab: :practices, tree: tree}) do
    length(tree.practices)
  end

  def item_count(%{active_tab: :jobs, tree: tree}) do
    length(tree.jobs)
  end

  def item_count(%{active_tab: :diagnostics, tree: tree}) do
    length(tree.errors.entries)
  end

  # ---------------------------------------------------------------------
  # Interactive Actions (Toggle / Edit / Delete)
  # ---------------------------------------------------------------------

  def handle_toggle(state) do
    case state.active_tab do
      :settings ->
        config_keys = Enum.sort(Map.keys(state.tree.config))

        if key = Enum.at(config_keys, state.cursor) do
          val = Map.get(state.tree.config, key)

          if is_boolean(val) do
            updated_config = Map.put(state.tree.config, key, not val)
            Config.save_config(updated_config, state.cwd)
            notice = "Toggled '#{key}' -> #{not val}"
            refresh_state(state, notice)
          else
            %{state | status_notice: "Setting '#{key}' is non-boolean. Press 'e' to edit value."}
          end
        else
          state
        end

      :rules ->
        if rule = Enum.at(state.tree.rules, state.cursor) do
          rule_id = Map.get(rule, "id")
          {:ok, _} = Rules.toggle_rule(rule_id, state.cwd)
          notice = "Toggled rule ##{rule_id}"
          refresh_state(state, notice)
        else
          state
        end

      _ ->
        state
    end
  end

  def handle_delete(state) do
    case state.active_tab do
      :rules ->
        if rule = Enum.at(state.tree.rules, state.cursor) do
          rule_id = Map.get(rule, "id")
          {:ok, _} = Rules.delete_rules([rule_id], state.cwd)
          notice = "Deleted rule ##{rule_id}"
          refresh_state(state, notice)
        else
          state
        end

      :sessions ->
        if sess = Enum.at(state.tree.sessions, state.cursor) do
          File.rm(sess.path)
          notice = "Deleted session file '#{sess.file}'"
          refresh_state(state, notice)
        else
          state
        end

      :diagnostics ->
        if File.exists?(state.tree.errors.file_path) do
          File.write!(state.tree.errors.file_path, "")
          notice = "Cleared diagnostic log ERRORS_TO_FIX.lmml"
          refresh_state(state, notice)
        else
          state
        end

      _ ->
        state
    end
  end

  def refresh_state(state, notice \\ nil) do
    updated_tree = scan_directory_tree(state.cwd)
    %{state | tree: updated_tree, status_notice: notice}
  end

  # ---------------------------------------------------------------------
  # TUI Rendering Engine
  # ---------------------------------------------------------------------

  def render_explorer(state, opts \\ []) do
    inner_width = 74

    if Keyword.get(opts, :erase?, true) and state.rendered_lines > 0 do
      IO.write(:user, "\r\e[#{state.rendered_lines}A\e[0J")
    end

    header =
      "#{Formatter.cyan()}╭─#{Formatter.bold()} ⚙ .yoke Config Directory Explorer #{Formatter.reset()}#{Formatter.cyan()}───────────────────────────────╮#{Formatter.reset()}"

    tabs_str =
      @tabs
      |> Enum.with_index()
      |> Enum.map_join("  ", fn {tab, idx} ->
        label = tab_label(tab)

        if idx == state.tab_index do
          "#{Formatter.cyan()}#{Formatter.bold()}[#{idx + 1}: #{label}]#{Formatter.reset()}"
        else
          "#{Formatter.dim()}[#{idx + 1}: #{label}]#{Formatter.reset()}"
        end
      end)

    tab_bar = "│ #{tabs_str} │"

    sep =
      "#{Formatter.cyan()}├──────────────────────────────────────────────────────────────────────────┤#{Formatter.reset()}"

    body_lines = render_tab_content(state, inner_width)

    notice_line =
      if state.status_notice do
        "│ #{Formatter.yellow()}⚡ #{state.status_notice}#{Formatter.reset()}"
        |> pad_line(inner_width)
      else
        nil
      end

    footer =
      "#{Formatter.cyan()}╰─[Tab/←/→: Tab | ↑/↓: Select | Space: Toggle | d: Delete | r: Refresh | q: Exit]─╯#{Formatter.reset()}"

    lines =
      [header, tab_bar, sep] ++
        body_lines ++
        (if notice_line, do: [notice_line], else: []) ++
        [footer]

    output = Enum.join(lines, "\r\n") <> "\r\n"
    IO.write(:user, output)

    %{state | rendered_lines: length(lines)}
  end

  defp tab_label(:settings), do: "Settings"
  defp tab_label(:rules), do: "Rules"
  defp tab_label(:sessions), do: "Sessions"
  defp tab_label(:practices), do: "Practices"
  defp tab_label(:jobs), do: "Jobs"
  defp tab_label(:diagnostics), do: "Diagnostics"

  defp render_tab_content(%{active_tab: :settings} = state, width) do
    keys = Enum.sort(Map.keys(state.tree.config))

    if keys == [] do
      ["│   (No config keys loaded)" |> pad_line(width)]
    else
      keys
      |> Enum.with_index()
      |> Enum.map(fn {key, idx} ->
        val = Map.get(state.tree.config, key)
        cursor_prefix = if idx == state.cursor, do: " ❯ ", else: "   "

        line_str =
          if idx == state.cursor do
            "│#{Formatter.cyan()}#{cursor_prefix}#{Formatter.bold()}#{key}: #{inspect(val)}#{Formatter.reset()}"
          else
            "│#{cursor_prefix}#{key}: #{Formatter.dim()}#{inspect(val)}#{Formatter.reset()}"
          end

        pad_line(line_str, width)
      end)
    end
  end

  defp render_tab_content(%{active_tab: :rules} = state, width) do
    rules = state.tree.rules

    if rules == [] do
      ["│   (No prompt rules configured)" |> pad_line(width)]
    else
      rules
      |> Enum.with_index()
      |> Enum.map(fn {rule, idx} ->
        id = Map.get(rule, "id")
        scope = Map.get(rule, "scope", "all")
        text = Map.get(rule, "text", "")
        enabled? = Map.get(rule, "enabled", true)

        status_mark = if enabled?, do: "#{Formatter.green()}✔#{Formatter.reset()}", else: "#{Formatter.red()}✘#{Formatter.reset()}"
        cursor_prefix = if idx == state.cursor, do: " ❯ ", else: "   "

        line_str =
          if idx == state.cursor do
            "│#{Formatter.cyan()}#{cursor_prefix}#{Formatter.bold()}[##{id} #{scope}] #{status_mark} #{text}#{Formatter.reset()}"
          else
            "│#{cursor_prefix}[##{id} #{scope}] #{status_mark} #{text}"
          end

        pad_line(line_str, width)
      end)
    end
  end

  defp render_tab_content(%{active_tab: :sessions} = state, width) do
    sessions = state.tree.sessions

    if sessions == [] do
      ["│   (No session logs in .yoke/sessions/)" |> pad_line(width)]
    else
      sessions
      |> Enum.take(15)
      |> Enum.with_index()
      |> Enum.map(fn {sess, idx} ->
        cursor_prefix = if idx == state.cursor, do: " ❯ ", else: "   "
        size_kb = Float.round(sess.size / 1024, 1)

        line_str =
          if idx == state.cursor do
            "│#{Formatter.cyan()}#{cursor_prefix}#{Formatter.bold()}#{sess.id} (#{size_kb} KB) - #{sess.file}#{Formatter.reset()}"
          else
            "│#{cursor_prefix}#{sess.id} #{Formatter.dim()}(#{size_kb} KB) - #{sess.file}#{Formatter.reset()}"
          end

        pad_line(line_str, width)
      end)
    end
  end

  defp render_tab_content(%{active_tab: :practices} = state, width) do
    practices = state.tree.practices

    if practices == [] do
      ["│   (No practice manifests found in .yoke/practices/ or ~/.yoke/practices/)" |> pad_line(width)]
    else
      practices
      |> Enum.with_index()
      |> Enum.map(fn {prac, idx} ->
        cursor_prefix = if idx == state.cursor, do: " ❯ ", else: "   "

        line_str =
          if idx == state.cursor do
            "│#{Formatter.cyan()}#{cursor_prefix}#{Formatter.bold()}[#{prac.scope}] Language: #{prac.lang} (#{prac.file})#{Formatter.reset()}"
          else
            "│#{cursor_prefix}[#{prac.scope}] Language: #{prac.lang} (#{prac.file})"
          end

        pad_line(line_str, width)
      end)
    end
  end

  defp render_tab_content(%{active_tab: :jobs} = state, width) do
    jobs = state.tree.jobs

    if jobs == [] do
      ["│   (No background job logs in .yoke/jobs/)" |> pad_line(width)]
    else
      jobs
      |> Enum.take(12)
      |> Enum.with_index()
      |> Enum.map(fn {job, idx} ->
        cursor_prefix = if idx == state.cursor, do: " ❯ ", else: "   "
        size_bytes = job.size

        line_str =
          if idx == state.cursor do
            "│#{Formatter.cyan()}#{cursor_prefix}#{Formatter.bold()}Job #{job.id} (#{size_bytes} bytes) - #{job.file}#{Formatter.reset()}"
          else
            "│#{cursor_prefix}Job #{job.id} (#{size_bytes} bytes) - #{job.file}"
          end

        pad_line(line_str, width)
      end)
    end
  end

  defp render_tab_content(%{active_tab: :diagnostics} = state, width) do
    entries = state.tree.errors.entries

    if entries == [] do
      ["│   (No errors logged in .yoke/ERRORS_TO_FIX.lmml)" |> pad_line(width)]
    else
      entries
      |> Enum.take(10)
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        cursor_prefix = if idx == state.cursor, do: " ❯ ", else: "   "
        first_line = entry |> String.split("\n") |> List.first() || entry

        line_str =
          if idx == state.cursor do
            "│#{Formatter.cyan()}#{cursor_prefix}#{Formatter.bold()}#{first_line}#{Formatter.reset()}"
          else
            "│#{cursor_prefix}#{Formatter.red()}●#{Formatter.reset()} #{first_line}"
          end

        pad_line(line_str, width)
      end)
    end
  end

  defp pad_line(line_str, width) do
    vis_width = Formatter.display_width(line_str)
    # Subtract 1 for border char '│' if included
    target_width = width + 1

    if vis_width < target_width do
      line_str <> String.duplicate(" ", target_width - vis_width) <> "│"
    else
      line_str <> "│"
    end
  end

  # ---------------------------------------------------------------------
  # TUI Input Event Loop
  # ---------------------------------------------------------------------

  def run_tty(cwd, _opts) do
    set_raw_mode()
    state = new_state(cwd)

    try do
      tui_loop(state)
    after
      TerminalOwner.clear()
      restore_tty_mode()
      IO.write(:user, "\r\n")
    end
  end

  defp tui_loop(state) do
    state = render_explorer(state)
    TerminalOwner.set(&erase_for_log/1, &redraw_for_log/1, state)

    case read_key() do
      :tab ->
        tui_loop(switch_tab(state, 1))

      :right ->
        tui_loop(switch_tab(state, 1))

      :left ->
        tui_loop(switch_tab(state, -1))

      :up ->
        tui_loop(move_cursor(state, -1))

      :down ->
        tui_loop(move_cursor(state, 1))

      :space ->
        tui_loop(handle_toggle(state))

      {:char, ?d} ->
        tui_loop(handle_delete(state))

      {:char, ?r} ->
        tui_loop(refresh_state(state, "Refreshed configuration tree."))

      {:char, ?q} ->
        :ok

      :escape ->
        :ok

      :ctrl_c ->
        :ok

      {:char, c} when c >= ?1 and c <= ?6 ->
        idx = c - ?1
        tab = Enum.at(@tabs, idx)
        tui_loop(%{state | tab_index: idx, active_tab: tab, cursor: 0})

      _ ->
        tui_loop(state)
    end
  end

  defp erase_for_log(%{rendered_lines: n}) when is_integer(n) and n > 0 do
    IO.write(:user, "\r\e[#{n}A\e[0J")
  end

  defp erase_for_log(_state), do: :ok

  defp redraw_for_log(state), do: render_explorer(state, erase?: false)

  def run_non_tty(cwd, _opts) do
    tree = scan_directory_tree(cwd)
    output = format_non_tty_summary(tree)
    IO.puts(output)
    {:ok, output}
  end

  def format_non_tty_summary(tree) do
    """
    === Yoke Config Directory Explorer Summary ===
    Local path: #{tree.local_dir}
    Global path: #{tree.global_dir}

    ● Config keys (#{map_size(tree.config)}):
      Model: #{tree.config["model"]}
      Permission mode: #{tree.config["permission_mode"]}
      Plan gate: #{tree.config["plan_gate_enabled"]} (threshold: #{tree.config["plan_gate_threshold"]})
      God mode: #{tree.config["god_mode"]}

    ● Prompt Rules (#{length(tree.rules)} active)
    ● Saved Sessions (#{length(tree.sessions)} files in .yoke/sessions/)
    ● Practice Manifests (#{length(tree.practices)} loaded)
    ● Job Logs (#{length(tree.jobs)} files in .yoke/jobs/)
    ● Logged Diagnostic Errors (#{tree.errors.count} entries in ERRORS_TO_FIX.lmml)
    =============================================
    """
  end

  # Raw Key Reading helpers
  defp tty? do
    if (function_exported?(Mix, :env, 0) and Mix.env() == :test) or
         System.get_env("CI") != nil or
         Application.get_env(:yoke, :non_interactive, false) do
      false
    else
      case :io.columns(:user) do
        {:ok, _} -> true
        _ -> case :io.columns() do
               {:ok, _} -> true
               _ -> false
             end
      end
    end
  end

  defp set_raw_mode do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp read_key do
    case get_raw_input_chunk() do
      :eof -> :eof
      other -> match_key(other)
    end
  end

  defp match_key("\e[A"), do: :up
  defp match_key("\e[B"), do: :down
  defp match_key("\e[C"), do: :right
  defp match_key("\e[D"), do: :left
  defp match_key("\eOA"), do: :up
  defp match_key("\eOB"), do: :down
  defp match_key("\eOC"), do: :right
  defp match_key("\eOD"), do: :left
  defp match_key("\r"), do: :enter
  defp match_key("\n"), do: :enter
  defp match_key("\t"), do: :tab
  defp match_key(" "), do: :space
  defp match_key("\e"), do: :escape
  defp match_key("\x03"), do: :ctrl_c

  defp match_key(other) when is_binary(other) do
    cond do
      String.contains?(other, "[A") or String.contains?(other, "OA") -> :up
      String.contains?(other, "[B") or String.contains?(other, "OB") -> :down
      String.contains?(other, "[C") or String.contains?(other, "OC") -> :right
      String.contains?(other, "[D") or String.contains?(other, "OD") -> :left
      true ->
        case String.to_charlist(other) do
          [c | _] -> {:char, c}
          _ -> :other
        end
    end
  end

  defp get_raw_input_chunk do
    case read_char() do
      "\e" ->
        seq = read_available_escape_bytes("", 6)
        "\e" <> seq

      :eof ->
        :eof

      char when is_binary(char) ->
        char
    end
  end

  defp read_char_with_timeout(timeout_ms) do
    task = Task.async(fn -> read_char() end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  defp read_available_escape_bytes(acc, count) when count > 0 do
    case read_char_with_timeout(25) do
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
    case IO.getn(:user, "", 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      char when is_binary(char) -> char
      char when is_list(char) -> IO.iodata_to_binary(char)
    end
  end
end
