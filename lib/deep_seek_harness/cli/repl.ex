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
    IO.puts(Formatter.banner())

    session_id = opts[:session_id] || "main"
    {:ok, session_pid} = SessionSupervisor.start_session(session_id: session_id, model: opts[:model] || "deepseek-chat")

    IO.puts(Formatter.format_info("Brain actor spawned for session '#{session_id}'"))
    IO.puts(Formatter.format_info("Type /help for command menu or !command for direct shell execution.\n"))

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
        IO.puts("\nGoodbye!")

      {:error, reason} ->
        IO.puts(Formatter.format_error("Input error: #{inspect(reason)}"))

      line when is_binary(line) ->
        trimmed = String.trim(line)
        updated_history = if trimmed != "", do: [trimmed | history], else: history

        case handle_input(trimmed, session_pid, session_id) do
          :continue ->
            loop(session_pid, session_id, updated_history)

          :exit ->
            IO.puts("#{Formatter.cyan()}Session ended. Exiting DeepSeek Harness.#{Formatter.reset()}")
            :ok
        end
    end
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
    IO.puts(Formatter.format_info("Compressing conversation context..."))

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

  def handle_input("/diff", _session_pid, _session_id) do
    case Git.diff() do
      {:ok, diff_out} ->
        IO.puts("\n#{Formatter.bold()}Workspace Git Diff:#{Formatter.reset()}\n#{diff_out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/review " <> args, session_pid, _session_id) do
    parts = String.split(args, " ", trim: true)

    {base_branch, head_branch} =
      case parts do
        [base, head | _] -> {base, head}
        [base] -> {base, "HEAD"}
        _ -> {"main", "HEAD"}
      end

    IO.puts(Formatter.format_info("Comparing branches '#{base_branch}' vs '#{head_branch}' and generating Code Review..."))

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

  def handle_input("/cost", session_pid, _session_id) do
    stats = Session.get_token_stats(session_pid)

    md = """
    ### Session Token & Cost Statistics
    - **Estimated Context Tokens**: `#{stats.estimated_prompt_tokens}`
    - **Completion Tokens**: `#{stats.tracked_completion_tokens}`
    - **Total Session Tokens**: `#{stats.total_tokens}`
    - **Estimated Cost (USD)**: `$#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
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
        Enum.map_join(skills, "\n", fn s -> "- **`#{s.name}`** [`#{Path.basename(s.path)}`]: #{s.description}" end)
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
        IO.puts(Formatter.format_info("Loading and executing skill '#{name}'..."))
        case Session.send_user_message(session_pid, prompt) do
          {:ok, %{content: out}} ->
            IO.puts("\n" <> Formatter.format_agent_response(out) <> "\n")

          {:error, err} ->
            IO.puts(Formatter.format_error(err))
        end

      nil ->
        IO.puts(Formatter.format_error("Skill '#{name}' not found. Use /skills to view available skills."))
    end

    :continue
  end

  def handle_input("/subagent " <> prompt, session_pid, _session_id) do
    prompt = String.trim(prompt)
    IO.puts(Formatter.format_info("Spawning background subagent for task: \"#{prompt}\"..."))

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
        IO.puts(Formatter.format_success("Hot-reloaded plugins and updated active Brain actors! Total tools: #{length(tools_list)}"))

      {:error, err} ->
        IO.puts(Formatter.format_error("Plugin reload failed: #{err}"))
    end

    :continue
  end

  # Handle all variations of /mcp list, /mcp ls, /mcp
  def handle_input("/mcp list", session_pid, session_id), do: handle_mcp_list(session_pid, session_id)
  def handle_input("/mcp ls", session_pid, session_id), do: handle_mcp_list(session_pid, session_id)
  def handle_input("/mcp", session_pid, session_id), do: handle_mcp_list(session_pid, session_id)

  def handle_input("/mcp load", _session_pid, _session_id) do
    IO.puts(Formatter.format_info("Loading MCP servers configured in config.json..."))

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
        IO.puts(Formatter.format_info("Connecting to MCP server '#{name}' via '#{cmd}'..."))

        case MCPServerManager.add_server(name, cmd, cmd_args) do
          {:ok, tools} ->
            IO.puts(Formatter.format_success("Connected MCP server '#{name}'! Registered #{length(tools)} tools."))

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
    IO.puts(Formatter.format_info("Mounting Ragex MCP server targeting workspace '#{target_dir}'..."))

    case MCPServerManager.start_ragex(target_dir: target_dir) do
      {:ok, dir, tools} ->
        IO.puts(Formatter.format_success("Mounted Ragex MCP server targeting '#{dir}'! Registered #{length(tools)} code analysis & refactoring tools."))

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
        other -> other
      end

    {:ok, current} = Session.set_model(session_pid, target_model)
    IO.puts(Formatter.format_success("Switched model to '#{current}'"))
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
        IO.puts(Formatter.format_error("Usage: /mode [local | remote <node_name> | docker <container_id>]"))
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
    IO.puts(Formatter.format_error("Unknown command '/#{command}'. Type /help for available slash commands."))
    :continue
  end

  def handle_input(user_prompt, session_pid, _session_id) do
    turn_fn = fn -> try_send_message(session_pid, user_prompt) end

    res =
      if Code.ensure_loaded?(Owl.Spinner) do
        Owl.Spinner.run(turn_fn, title: "Thinking & coordinating with Hands...")
      else
        IO.puts("#{Formatter.dim()}Thinking and coordinating with Hands...#{Formatter.reset()}")
        turn_fn.()
      end

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
          IO.puts(Formatter.format_info("Restarting agent session actor '#{session_id}'..."))
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
        server_blocks =
          Enum.map(servers, fn s ->
            tools_list = Enum.map_join(s.tools, "\n", fn t -> "  - `#{t}`" end)
            "#### #{s.name} (`#{s.command} #{Enum.join(s.args, " ")}`)\n**Registered Tools (#{s.tools_count}):**\n#{tools_list}"
          end)
          |> Enum.join("\n\n")

        "### Connected MCP Servers (#{length(servers)})\n\n" <> server_blocks
      end

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end
end
