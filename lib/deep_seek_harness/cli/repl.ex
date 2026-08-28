defmodule DeepSeekHarness.CLI.Repl do
  @moduledoc """
  Interactive REPL loop and slash-command handler for DeepSeek Harness.
  Includes resilience against actor crashes, slash command validation, and Marcli rendering.
  """
  alias DeepSeekHarness.Brain.Session
  alias DeepSeekHarness.Brain.SessionSupervisor
  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Distribution.NodeManager
  alias DeepSeekHarness.Git
  alias DeepSeekHarness.MCP.ServerManager, as: MCPServerManager
  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader
  alias DeepSeekHarness.Skill.Manager, as: SkillManager

  alias DeepSeekHarness.CLI.LineEditor

  def start(opts \\ []) do
    MCPServerManager.await_ragex()
    IO.puts(Formatter.banner())

    session_id =
      opts[:conversation] || opts[:resume] || opts[:session_id] ||
        DeepSeekHarness.CLI.Main.generate_uuid()

    {:ok, session_pid} =
      SessionSupervisor.start_session(
        session_id: session_id,
        model: opts[:model] || "deepseek-chat"
      )

    IO.puts(Formatter.format_info("Brain actor spawned for session '#{session_id}'"))

    IO.puts(
      Formatter.format_info(
        "Type /help for command menu or !command for direct shell execution.\n"
      )
    )

    history = LineEditor.load_history()
    loop(session_pid, session_id, history)
  end

  def loop(session_pid, session_id, history \\ []) do
    # Ensure session actor process is alive before turn
    session_pid = ensure_session_alive(session_pid, session_id)

    info = Session.get_info(session_pid)
    prompt_str = LineEditor.build_prompt(session_id, info.model, info.hands_mode)

    case LineEditor.get_line(prompt_str, history) do
      :eof ->
        graceful_shutdown()
        print_resume_banner(session_id)

      {:error, reason} ->
        IO.puts(Formatter.format_error("Input error: #{inspect(reason)}"))

      line when is_binary(line) ->
        trimmed = String.trim(line)
        updated_history = if trimmed != "", do: [trimmed | history], else: history

        case handle_input(trimmed, session_pid, session_id) do
          :continue ->
            loop(session_pid, session_id, updated_history)

          {:switch_session, new_id, new_pid} ->
            loop(new_pid, new_id, updated_history)

          :exit ->
            graceful_shutdown()
            print_resume_banner(session_id)
            :ok
        end
    end
  end

  # Stops any externally spawned processes (e.g. the per-project Ragex/dllb
  # instance) before the VM halts. `System.halt/1` (called by the escript
  # runtime once `main/1` returns) skips normal port cleanup, so without
  # this the per-project `dllb-server` OS process is left running as an
  # orphan, and the next launch can't reliably reuse its on-disk cache --
  # forcing a full re-index every time instead of an instant cache hit.
  defp graceful_shutdown do
    MCPServerManager.stop_ragex()
  catch
    _, _ -> :ok
  end

  def handle_input("", _session_pid, _session_id), do: :continue
  def handle_input("/exit", _pid, _id), do: :exit
  def handle_input("/quit", _pid, _id), do: :exit

  # Shell execution shortcut: !command
  def handle_input("!" <> cmd, _session_pid, _session_id) do
    cmd = String.trim(cmd)
    IO.puts(Formatter.format_info("Executing shell command: #{cmd}"))

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {out, 0} -> IO.puts("\n#{out}\n")
      {out, code} -> IO.puts(Formatter.format_error("Exit status #{code}:\n#{out}"))
    end

    :continue
  end

  def handle_input("/help", _session_pid, _session_id) do
    IO.puts(Formatter.help_menu())
    :continue
  end

  def handle_input("/clear", _session_pid, _session_id) do
    IO.write("\e[H\e[2J")
    :continue
  end

  def handle_input("/compact", session_pid, _session_id) do
    IO.puts(Formatter.format_info("Compressing conversation context…"))

    case Session.compact_context(session_pid) do
      {:ok, summary} ->
        IO.puts(Formatter.format_success("Context successfully compressed!"))
        md = "### Compressed Context Summary\n" <> summary
        IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/diff " <> target, _session_pid, _session_id) do
    t = String.trim(target)

    case Git.diff(t) do
      {:ok, diff_out} ->
        IO.puts("\n#{Formatter.bold()}Git Diff (#{t}):#{Formatter.reset()}\n#{diff_out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/diff", _session_pid, _session_id) do
    case Git.diff() do
      {:ok, diff_out} ->
        IO.puts("\n#{Formatter.bold()}Workspace Git Diff:#{Formatter.reset()}\n#{diff_out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/cr " <> base, session_pid, session_id) do
    b = String.trim(base)
    b = if b == "", do: "main", else: b
    handle_input("/review #{b} HEAD", session_pid, session_id)
  end

  def handle_input("/cr", session_pid, session_id) do
    handle_input("/review main HEAD", session_pid, session_id)
  end

  def handle_input("/git " <> args, _session_pid, _session_id) do
    args = String.trim(args)

    case Git.run(args) do
      {:ok, out} ->
        IO.puts("\n#{Formatter.bold()}$ git #{args}#{Formatter.reset()}\n#{out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/git", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_info(
        "Usage: /git <subcommand> [args...]  (e.g. /git status, /git log --oneline -5, /git branch -a)"
      )
    )

    :continue
  end

  def handle_input("/linter " <> args, _session_pid, _session_id) do
    args = String.trim(args)

    IO.puts(Formatter.format_info("Running linter tool: #{args}…"))

    case DeepSeekHarness.Linter.run(args) do
      {:ok, out} ->
        IO.puts("\n#{out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/linter", _session_pid, _session_id) do
    IO.puts(DeepSeekHarness.Linter.help_text())
    :continue
  end

  def handle_input("/lint " <> args, session_pid, session_id) do
    handle_input("/linter " <> args, session_pid, session_id)
  end

  def handle_input("/lint", session_pid, session_id) do
    handle_input("/linter", session_pid, session_id)
  end

  def handle_input("/review " <> args, session_pid, _session_id) do
    parts = String.split(args, " ", trim: true)

    {base_branch, head_branch} =
      case parts do
        [base, head | _] -> {base, head}
        [base] -> {base, "HEAD"}
        _ -> {"main", "HEAD"}
      end

    IO.puts(
      Formatter.format_info(
        "Comparing branches '#{base_branch}' vs '#{head_branch}' and generating Code Review…"
      )
    )

    case Session.generate_code_review(session_pid, base_branch, head_branch) do
      {:ok, %{content: review_md}} ->
        IO.puts("\n" <> Formatter.format_agent_response(review_md) <> "\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/review", session_pid, session_id) do
    handle_input("/review main HEAD", session_pid, session_id)
  end

  def handle_input("/commit " <> msg, _session_pid, _session_id) do
    msg = String.trim(msg)

    case Git.commit(msg) do
      {:ok, out} ->
        IO.puts(Formatter.format_success("Git commit created:\n#{out}"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/cb", session_pid, session_id),
    do: handle_copy_clipboard(session_pid, session_id)

  def handle_input("/clipboard", session_pid, session_id),
    do: handle_copy_clipboard(session_pid, session_id)

  def handle_input("/cost", session_pid, _session_id) do
    stats = Session.get_token_stats(session_pid)
    prompt_tokens = stats[:tracked_prompt_tokens] || stats[:estimated_prompt_tokens] || 0

    md = """
    ### Session Token & Cost Statistics
    - **Estimated Context Tokens**: `#{prompt_tokens}`
    - **Completion Tokens**: `#{stats.tracked_completion_tokens}`
    - **Total Session Tokens**: `#{stats.total_tokens}`
    - **Estimated Cost (USD)**: `$#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/stats", session_pid, _session_id) do
    stats = Session.get_stats(session_pid)

    md = """
    ### Session Analytics & Statistics Dashboard
    - **Session ID**: `#{stats.session_id}`
    - **Model**: `#{stats.model}`
    - **Permission Safety**: `#{stats.permission_mode}`
    - **Sandbox Bounds**: `#{if stats.sandbox_workspace, do: "enabled", else: "disabled"}`
    - **Messages Count**: `#{stats.message_count}`
    - **Snapshots**: `#{stats.snapshot_count}`
    - **Execution Mode**: `#{stats.hands_mode}`
    - **Total Prompt Tokens**: `#{stats.tracked_prompt_tokens}`
    - **Total Completion Tokens**: `#{stats.tracked_completion_tokens}`
    - **Total Tokens**: `#{stats.total_tokens}`
    - **Estimated Cost (USD)**: `$#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}`
    - **Registered Tools**: `#{stats.tools_count}`
    - **Connected MCP Servers**: `#{stats.mcp_servers_count}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/tokens", session_pid, _session_id) do
    turns = Session.get_turn_tokens(session_pid)
    stats = Session.get_token_stats(session_pid)

    rows =
      if Enum.empty?(turns) do
        "| Turn #1 | 0 | 0 | 0 |"
      else
        Enum.map_join(turns, "\n", fn t ->
          "| Turn ##{t.turn} | #{t.prompt_tokens} | #{t.completion_tokens} | #{t.total_tokens} |"
        end)
      end

    md = """
    ### Per-Turn Token Breakdown
    | Turn | Prompt Tokens | Completion Tokens | Total Tokens |
    |---|---|---|---|
    #{rows}

    **Session Cumulative Total**: `#{stats.total_tokens}` tokens (`$#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}`)
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/sandbox " <> mode, session_pid, _session_id) do
    enabled =
      case String.trim(mode) do
        "on" -> true
        "true" -> true
        "enable" -> true
        _ -> false
      end

    {:ok, val} = Session.set_sandbox_mode(session_pid, enabled)

    status_str =
      if val, do: "ENABLED (file refs & tools restricted to workspace)", else: "DISABLED"

    IO.puts(Formatter.format_success("Workspace sandbox bounds set to: #{status_str}"))
    :continue
  end

  def handle_input("/sandbox", session_pid, session_id) do
    handle_input("/sandbox on", session_pid, session_id)
  end

  def handle_input("/export " <> format, session_pid, _session_id) do
    fmt =
      case String.trim(format) do
        "json" -> :json
        _ -> :markdown
      end

    case Session.export_session(session_pid, fmt) do
      {:ok, path} ->
        IO.puts(Formatter.format_success("Session history successfully exported to: #{path}"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/export", session_pid, session_id) do
    handle_input("/export markdown", session_pid, session_id)
  end

  def handle_input("/permissions " <> mode, session_pid, _session_id) do
    perm =
      case String.trim(mode) do
        "auto" -> :auto_approve
        "yolo" -> :auto_approve
        _ -> :ask_confirm
      end

    {:ok, mode_set} = Session.set_permission_mode(session_pid, perm)
    IO.puts(Formatter.format_success("Permission safety mode set to: #{mode_set}"))
    :continue
  end

  def handle_input("/skills", _session_pid, _session_id) do
    skills = SkillManager.discover_skills()

    skill_rows =
      if Enum.empty?(skills) do
        "*No skills discovered in `.dsh/skills` or `~/.dsh/skills`.*"
      else
        Enum.map_join(skills, "\n", fn s ->
          "- **`#{s.name}`** [`#{Path.basename(s.path)}`]: #{s.description}"
        end)
      end

    md = "### Discovered Skills (#{length(skills)})\n\n#{skill_rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/skill " <> skill_name, session_pid, _session_id) do
    name = String.trim(skill_name)
    skills = SkillManager.discover_skills()

    case Enum.find(skills, fn s -> s.name == name end) do
      %SkillManager{content: content} ->
        prompt = "Execute skill '#{name}':\n\n#{content}"
        IO.puts(Formatter.format_info("Loading and executing skill '#{name}'…"))

        case Session.send_user_message(session_pid, prompt) do
          {:ok, %{content: out}} ->
            IO.puts("\n" <> Formatter.format_agent_response(out) <> "\n")

          {:error, err} ->
            IO.puts(Formatter.format_error(err))
        end

      nil ->
        IO.puts(
          Formatter.format_error(
            "Skill '#{name}' not found. Use /skills to view available skills."
          )
        )
    end

    :continue
  end

  def handle_input("/subagent " <> prompt, session_pid, _session_id) do
    prompt = String.trim(prompt)
    IO.puts(Formatter.format_info("Spawning background subagent for task: \"#{prompt}\"…"))

    case Session.spawn_subagent(session_pid, prompt) do
      {:ok, result} ->
        md = "### Subagent Completed Result\n" <> result
        IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")

      {:error, err} ->
        IO.puts(Formatter.format_error("Subagent failed: #{err}"))
    end

    :continue
  end

  def handle_input("/plugins", _session_pid, _session_id) do
    tools = PluginLoader.list_tools()

    tools_rows =
      Enum.map_join(tools, "\n", fn t -> "- **`#{t.name}`**: #{t.description}" end)

    md = "### Registered Tools (#{length(tools)})\n\n#{tools_rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/plugins reload", _session_pid, _session_id) do
    case PluginLoader.reload_all() do
      {:ok, tools_list} ->
        IO.puts(
          Formatter.format_success(
            "Hot-reloaded plugins and updated active Brain actors! Total tools: #{length(tools_list)}"
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error("Plugin reload failed: #{err}"))
    end

    :continue
  end

  # Handle all variations of /mcp list, /mcp ls, /mcp
  def handle_input("/mcp list", session_pid, session_id),
    do: handle_mcp_list(session_pid, session_id)

  def handle_input("/mcp ls", session_pid, session_id),
    do: handle_mcp_list(session_pid, session_id)

  def handle_input("/mcp", session_pid, session_id), do: handle_mcp_list(session_pid, session_id)

  def handle_input("/mcp load", _session_pid, _session_id) do
    IO.puts(Formatter.format_info("Loading MCP servers configured in config.json…"))

    case MCPServerManager.load_from_config() do
      {:ok, results} ->
        IO.puts(Formatter.format_success("MCP servers loaded: #{inspect(results)}"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/mcp add " <> args, _session_pid, _session_id) do
    parts = String.split(args, " ", trim: true)

    case parts do
      [name, cmd | cmd_args] ->
        IO.puts(Formatter.format_info("Connecting to MCP server '#{name}' via '#{cmd}'…"))

        case MCPServerManager.add_server(name, cmd, cmd_args) do
          {:ok, tools} ->
            IO.puts(
              Formatter.format_success(
                "Connected MCP server '#{name}'! Registered #{length(tools)} tools."
              )
            )

          {:error, err} ->
            IO.puts(Formatter.format_error(err))
        end

      _ ->
        IO.puts(Formatter.format_error("Usage: /mcp add <name> <command> [args...]"))
    end

    :continue
  end

  def handle_input("/ragex", _session_pid, _session_id) do
    target_dir = File.cwd!()

    IO.puts(
      Formatter.format_info("Mounting Ragex MCP server targeting workspace '#{target_dir}'…")
    )

    case MCPServerManager.start_ragex(target_dir: target_dir) do
      {:ok, dir, tools} ->
        IO.puts(
          Formatter.format_success(
            "Mounted Ragex MCP server targeting '#{dir}'! Registered #{length(tools)} code analysis & refactoring tools."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/model " <> target, session_pid, _session_id) do
    target_model =
      case String.trim(target) do
        "reasoner" -> "deepseek-reasoner"
        "r1" -> "deepseek-reasoner"
        "chat" -> "deepseek-chat"
        "v3" -> "deepseek-chat"
        "coder" -> "deepseek-coder"
        "v2.5" -> "deepseek-coder"
        "openrouter-r1" -> "deepseek/deepseek-r1"
        "openrouter-v3" -> "deepseek/deepseek-chat"
        "siliconflow-r1" -> "deepseek-ai/DeepSeek-R1"
        "siliconflow-v3" -> "deepseek-ai/DeepSeek-V3"
        "together-r1" -> "deepseek-ai/DeepSeek-R1"
        "ollama-r1" -> "deepseek-r1:70b"
        other -> other
      end

    {:ok, current} = Session.set_model(session_pid, target_model)
    IO.puts(Formatter.format_success("Switched model to '#{current}'"))
    :continue
  end

  def handle_input("/config style " <> style, _session_pid, _session_id) do
    s = String.trim(style)
    cfg = DeepSeekHarness.Config.load_config()
    updated = Map.put(cfg, "prompt_style", s)
    DeepSeekHarness.Config.save_config(updated)
    IO.puts(Formatter.format_success("Prompt style set to '#{s}'"))
    :continue
  end

  def handle_input("/config toggle " <> key, _session_pid, _session_id) do
    k = String.trim(key)
    cfg = DeepSeekHarness.Config.load_config()
    current = Map.get(cfg, k, true)
    updated = Map.put(cfg, k, not current)
    DeepSeekHarness.Config.save_config(updated)

    IO.puts(Formatter.format_success("Toggled config setting '#{k}' to #{not current}"))

    :continue
  end

  def handle_input("/config", _session_pid, _session_id) do
    cfg = DeepSeekHarness.Config.load_config()

    rows =
      cfg
      |> Enum.sort()
      |> Enum.map_join("\n", fn {k, v} -> "- **`#{k}`**: `#{inspect(v)}`" end)

    md = """
    ### DSH CLI Configuration & UI Preferences
    #{rows}

    **Usage:**
    - `/config style <starship|compact|minimal>` — Switch prompt visual layout
    - `/config toggle <setting_key>` — Toggle feature on/off (e.g. `enable_autosuggestions`, `enable_context_gauge`, `enable_file_picker`)
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/update", _session_pid, _session_id) do
    DeepSeekHarness.CLI.Main.handle_self_update()
    :continue
  end

  def handle_input("/rules add " <> rest, _session_pid, _session_id) do
    case DeepSeekHarness.Rules.add_rule(rest) do
      {:ok, rule} ->
        IO.puts(
          Formatter.format_success(
            "Added rule ##{rule["id"]} [#{rule["scope"]}]: \"#{rule["text"]}\""
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/rules delete", _session_pid, _session_id), do: handle_rules_delete()
  def handle_input("/rules rm", _session_pid, _session_id), do: handle_rules_delete()

  def handle_input("/rules toggle " <> id_str, _session_pid, _session_id) do
    case DeepSeekHarness.Rules.toggle_rule(id_str) do
      {:ok, _rules} ->
        IO.puts(Formatter.format_success("Toggled rule ##{id_str} status."))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/rules", _session_pid, _session_id) do
    rules = DeepSeekHarness.Rules.load_rules()

    rows =
      if Enum.empty?(rules) do
        "*No rules currently defined.*"
      else
        rules
        |> Enum.map_join("\n", fn r ->
          status = if r["enabled"], do: "enabled", else: "disabled"
          "| ##{r["id"]} | `#{r["scope"]}` | #{status} | #{r["text"]} |"
        end)
      end

    md = """
    ### Active Prompt & Execution Rules (#{length(rules)})
    | ID | Scope | Status | Rule Text |
    |---|---|---|---|
    #{rows}

    **Commands:**
    - `/rules add <scope: text>` — Add a new rule (e.g. `/rules add all: ...`, `/rules add cr: ...`)
    - `/rules delete` or `/rules rm` — Interactively select rules to delete
    - `/rules toggle <id>` — Toggle rule enabled/disabled
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/mode " <> args, session_pid, _session_id) do
    parts = String.split(args, " ", trim: true)

    case parts do
      ["remote", node_str] ->
        Session.set_hands_mode(session_pid, :remote, node_str)
        IO.puts(Formatter.format_success("Hands target set to remote node: #{node_str}"))

      ["docker", container] ->
        Session.set_hands_mode(session_pid, :docker, container)
        IO.puts(Formatter.format_success("Hands target set to docker container: #{container}"))

      ["local"] ->
        Session.set_hands_mode(session_pid, :local)
        IO.puts(Formatter.format_success("Hands target set to local sandbox"))

      _ ->
        IO.puts(
          Formatter.format_error(
            "Usage: /mode [local | remote <node_name> | docker <container_id>]"
          )
        )
    end

    :continue
  end

  def handle_input("/checkpoint" <> rest, session_pid, _session_id) do
    label = String.trim(rest)
    label = if label == "", do: nil, else: label

    {:ok, cp} = Session.checkpoint(session_pid, label)
    IO.puts(Formatter.format_success("Saved snapshot: '#{cp.label}' (ID: #{cp.id})"))
    :continue
  end

  def handle_input("/undo", session_pid, _session_id) do
    case Session.undo(session_pid) do
      {:ok, msg} ->
        IO.puts(Formatter.format_success(msg))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/session list", _session_pid, _session_id) do
    metas = DeepSeekHarness.Brain.SessionStore.list_session_metadata()

    rows =
      if Enum.empty?(metas) do
        "*No persisted sessions found in workspace.*"
      else
        Enum.map_join(metas, "\n", fn m ->
          dt = m.updated_at |> NaiveDateTime.to_iso8601() |> String.slice(0, 19)
          title_prefix = if m[:title], do: "**\"#{m.title}\"** ", else: ""

          "- #{title_prefix}`#{m.session_id}` [#{m.model}]: #{m.message_count} msgs, step #{m.step_count} (Updated: `#{dt}`)"
        end)
      end

    md = "### Persisted Workspace Sessions (#{length(metas)})\n\n#{rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/session resume " <> target_id, session_pid, session_id) do
    handle_input("/session switch " <> target_id, session_pid, session_id)
  end

  def handle_input("/resume " <> target_id, session_pid, session_id) do
    clean_id =
      target_id
      |> String.trim()
      |> String.replace(~r/^--conversation=|^ -c |^-c=/, "")

    handle_input("/session switch " <> clean_id, session_pid, session_id)
  end

  def handle_input("/resume", session_pid, session_id) do
    metas = DeepSeekHarness.Brain.SessionStore.list_session_metadata()

    if Enum.empty?(metas) do
      IO.puts(Formatter.format_info("No saved sessions available to resume."))
      :continue
    else
      meta_map =
        Enum.into(metas, %{}, fn m ->
          {format_session_picker_label(m), m.session_id}
        end)

      opts = Enum.map(metas, &format_session_picker_label/1)

      ans =
        DeepSeekHarness.CLI.Spinner.with_paused(fn ->
          DeepSeekHarness.CLI.QuestionPrompt.ask_single_question(
            "Select conversation to resume:",
            opts,
            false,
            false
          )
        end)

      case ans do
        %{selected: [sel]} ->
          target_id = Map.get(meta_map, sel) || sel |> String.split(" ", parts: 2) |> List.first()
          handle_input("/session switch " <> target_id, session_pid, session_id)

        _ ->
          :continue
      end
    end
  end

  def handle_input("/session switch " <> target_id, _session_pid, _session_id) do
    id = String.trim(target_id)

    new_pid =
      case DeepSeekHarness.Brain.SessionSupervisor.start_session(session_id: id) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    IO.puts(Formatter.format_success("Switched active REPL session to '#{id}'"))
    {:switch_session, id, new_pid}
  end

  def handle_input("/session cleanup", _session_pid, _session_id) do
    metas = DeepSeekHarness.Brain.SessionStore.list_session_metadata()
    stale = Enum.filter(metas, fn m -> m.message_count <= 1 end)

    removed_count =
      Enum.count(stale, fn m ->
        match?({:ok, _}, DeepSeekHarness.Brain.SessionStore.delete_session(m.session_id))
      end)

    IO.puts(Formatter.format_success("Cleaned up #{removed_count} stale/empty session(s)."))
    :continue
  end

  def handle_input("/session", session_pid, _session_id) do
    info = Session.get_info(session_pid)

    md = """
    ### Active Session Status
    - **Session ID**: `#{info.session_id}`
    - **Actor PID**: `#{inspect(info.pid)}`
    - **Model**: `#{info.model}`
    - **Permission Mode**: `#{info.permission_mode}`
    - **History Length**: `#{info.message_count}` messages
    - **Checkpoints**: `#{info.snapshot_count}` snapshots
    - **Hands Execution Target**: `#{info.hands_mode}` (`#{info.hands_target}`)
    - **Active Tools Count**: `#{info.tools_count}` registered
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/history search " <> query, _session_pid, _session_id) do
    q = String.downcase(String.trim(query))
    history = DeepSeekHarness.CLI.LineEditor.load_history()
    matches = Enum.filter(history, fn line -> String.contains?(String.downcase(line), q) end)

    md =
      if Enum.empty?(matches) do
        "No history entries matching '#{query}'."
      else
        rows = Enum.map_join(matches, "\n", fn m -> "- `#{m}`" end)
        "### History Search Results for '#{query}' (#{length(matches)})\n\n#{rows}"
      end

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/history", _session_pid, _session_id) do
    history = DeepSeekHarness.CLI.LineEditor.load_history()
    recent = Enum.take(Enum.reverse(history), 15)

    rows =
      if Enum.empty?(recent) do
        "*No REPL input history found.*"
      else
        recent
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {line, idx} -> "  #{idx}. `#{line}`" end)
      end

    md = "### Recent Input History (Last 15)\n\n#{rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/env", _session_pid, _session_id) do
    env_model = System.get_env("DEEPSEEK_MODEL") || "deepseek-chat (default)"

    has_key? =
      not is_nil(System.get_env("DEEPSEEK_API_KEY")) and
        System.get_env("DEEPSEEK_API_KEY") != ""

    dsh_env = System.get_env("DSH_ENV") || "prod"
    cwd = File.cwd!()

    md = """
    ### Environment & Runtime Configuration
    - **Operating System**: `#{:os.type() |> inspect()}`
    - **Elixir Version**: `#{System.version()}`
    - **OTP Release**: `#{System.otp_release()}`
    - **Current Workspace CWD**: `#{cwd}`
    - **Node Name**: `#{node()}`
    - **Environment**: `#{dsh_env}`
    - **DEEPSEEK_MODEL**: `#{env_model}`
    - **API Key Set?**: `#{has_key?}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/plugins info", _session_pid, _session_id) do
    tools = PluginLoader.list_tools()
    rows = Enum.map_join(tools, "\n", fn t -> "- **`#{t.name}`**: #{t.description}" end)
    md = "### Registered Plugin Tools Info (#{length(tools)})\n\n#{rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/ragex stats", _session_pid, _session_id) do
    case MCPServerManager.execute_ragex_tool("graph_stats", %{}) do
      {:ok, out} ->
        IO.puts(
          "\n" <> Formatter.format_markdown("### Ragex Knowledge Graph Stats\n\n#{out}") <> "\n"
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex reindex", _session_pid, _session_id) do
    IO.puts(Formatter.format_info("Re-indexing project codebase into Ragex Knowledge Graph…"))

    case MCPServerManager.start_ragex(File.cwd!()) do
      {:ok, _dir, _tools} ->
        IO.puts(Formatter.format_success("Knowledge Graph re-indexing triggered successfully!"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex export " <> fmt, _session_pid, _session_id) do
    format = String.trim(fmt)

    case MCPServerManager.execute_ragex_tool("export_graph", %{"format" => format}) do
      {:ok, out} ->
        IO.puts(
          "\n" <>
            Formatter.format_markdown(
              "### Knowledge Graph Export (#{format})\n\n```\n#{out}\n```"
            ) <> "\n"
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex export", session_pid, session_id) do
    handle_input("/ragex export mermaid", session_pid, session_id)
  end

  def handle_input("/nodes", _session_pid, _session_id) do
    data = NodeManager.list_nodes()

    md = """
    ### Distributed Erlang Node Cluster
    - **Local Node**: `#{data.self}`
    - **Node Alive?**: `#{data.alive?}`
    - **Connected Nodes**: `#{inspect(data.connected)}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  # Catch any unknown slash command to avoid sending accidental mistyped commands to LLM
  def handle_input("/" <> command, _session_pid, _session_id) do
    IO.puts(
      Formatter.format_error(
        "Unknown command '/#{command}'. Type /help for available slash commands."
      )
    )

    :continue
  end

  def handle_input(user_prompt, session_pid, _session_id) do
    turn_fn = fn -> try_send_message(session_pid, user_prompt) end

    res = DeepSeekHarness.CLI.Spinner.run(turn_fn, title: "Thinking & coordinating with Hands…")

    case res do
      {:ok, %{content: content}} ->
        IO.puts("\n" <> Formatter.format_agent_response(content) <> "\n")

      {:error, reason} ->
        IO.puts(Formatter.format_error("Turn failed: #{reason}"))
    end

    :continue
  end

  # Helper to safely send message and handle potential actor exits gracefully
  defp try_send_message(session_pid, user_prompt) do
    Session.send_user_message(session_pid, user_prompt)
  catch
    :exit, reason ->
      {:error, "Session process crashed or stopped: #{inspect(reason)}"}
  end

  defp ensure_session_alive(pid, session_id) do
    if is_pid(pid) and Process.alive?(pid) do
      pid
    else
      via = Session.via_tuple(session_id)

      case GenServer.whereis(via) do
        nil ->
          IO.puts(Formatter.format_info("Restarting agent session actor '#{session_id}'…"))
          {:ok, new_pid} = SessionSupervisor.start_session(session_id: session_id)
          new_pid

        new_pid ->
          new_pid
      end
    end
  end

  defp handle_mcp_list(_session_pid, _session_id) do
    servers = MCPServerManager.list_servers()

    md =
      if Enum.empty?(servers) do
        "### Connected MCP Servers (0)\n*No MCP servers connected. Use `/mcp add <name> <cmd> [args...]`, `/mcp load`, or `/ragex`.*"
      else
        server_blocks = Enum.map_join(servers, "\n\n", &format_server_block/1)
        "### Connected MCP Servers (#{length(servers)})\n\n" <> server_blocks
      end

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  defp format_server_block(s) do
    tools_list = Enum.map_join(s.tools, "\n", fn t -> "  - `#{t}`" end)

    "#### #{s.name} (`#{s.command} #{Enum.join(s.args, " ")}`)\n**Registered Tools (#{s.tools_count}):**\n#{tools_list}"
  end

  defp handle_copy_clipboard(session_pid, _session_id) do
    case Session.get_latest_response(session_pid) do
      {:ok, content} ->
        case Formatter.copy_to_clipboard(content) do
          :ok ->
            IO.puts(
              Formatter.format_success(
                "Copied latest assistant response to clipboard (#{String.length(content)} characters)!"
              )
            )

          {:error, err} ->
            IO.puts(Formatter.format_error(err))
        end

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  defp handle_rules_delete do
    rules = DeepSeekHarness.Rules.load_rules()

    if Enum.empty?(rules) do
      IO.puts(Formatter.format_info("No rules available to delete."))
    else
      opts =
        Enum.map(rules, fn r ->
          "[##{r["id"]}] (#{r["scope"]}): #{r["text"]}"
        end)

      ans =
        DeepSeekHarness.CLI.Spinner.with_paused(fn ->
          DeepSeekHarness.CLI.QuestionPrompt.ask_single_question(
            "Select rules to delete:",
            opts,
            true,
            false
          )
        end)

      case ans do
        %{selected: selected_items} when is_list(selected_items) and selected_items != [] ->
          ids =
            Enum.map(selected_items, fn item ->
              case Regex.run(~r/\[#(\d+)\]/, item) do
                [_, id_str] -> String.to_integer(id_str)
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          DeepSeekHarness.Rules.delete_rules(ids)
          IO.puts(Formatter.format_success("Deleted #{length(ids)} rule(s)."))

        _ ->
          IO.puts(Formatter.format_info("No rules deleted."))
      end
    end

    :continue
  end

  defp format_session_picker_label(m) do
    dt = m.updated_at |> NaiveDateTime.to_iso8601() |> String.slice(0, 19)
    name = if m[:title], do: "\"#{m.title}\"", else: "Untitled Session"
    "#{name} (#{m.session_id}) [#{m.model}, #{m.message_count} msgs, updated #{dt}]"
  end

  def print_resume_banner(session_id) do
    IO.puts("\nResume with -c (or command below):")

    IO.puts("#{Formatter.cyan()}dsh --conversation=#{session_id}#{Formatter.reset()}\n")
  end
end
