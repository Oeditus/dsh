defmodule DeepSeekHarness.CLI.Repl do
  @moduledoc """
  Interactive REPL loop and slash-command handler for DeepSeek Harness.
  Includes support for !shell execution, /compact, /diff, /commit, /cost, /permissions, /skills, /subagent.
  """
  alias DeepSeekHarness.Brain.Session
  alias DeepSeekHarness.Brain.SessionSupervisor
  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Distribution.NodeManager
  alias DeepSeekHarness.Git
  alias DeepSeekHarness.MCP.ServerManager, as: MCPServerManager
  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader
  alias DeepSeekHarness.Skill.Manager, as: SkillManager

  def start(opts \\ []) do
    IO.puts(Formatter.banner())

    session_id = opts[:session_id] || "main"
    {:ok, session_pid} = SessionSupervisor.start_session(session_id: session_id, model: opts[:model] || "deepseek-chat")

    IO.puts(Formatter.format_info("Brain actor spawned for session '#{session_id}'"))
    IO.puts(Formatter.format_info("Type /help for command menu or !command for direct shell execution.\n"))

    loop(session_pid, session_id)
  end

  def loop(session_pid, session_id) do
    info = Session.get_info(session_pid)
    prompt = Formatter.format_user_prompt(session_id, info.model)

    case IO.gets(prompt) do
      :eof ->
        IO.puts("\nGoodbye!")

      {:error, reason} ->
        IO.puts(Formatter.format_error("Input error: #{inspect(reason)}"))

      line when is_binary(line) ->
        trimmed = String.trim(line)

        case handle_input(trimmed, session_pid, session_id) do
          :continue ->
            loop(session_pid, session_id)

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
        IO.puts("#{Formatter.dim()}#{summary}#{Formatter.reset()}\n")

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

    IO.puts("\n#{Formatter.bold()}Session Token & Cost Statistics:#{Formatter.reset()}")
    IO.puts("  • Estimated Context Tokens: #{stats.estimated_prompt_tokens}")
    IO.puts("  • Completion Tokens:       #{stats.tracked_completion_tokens}")
    IO.puts("  • Total Session Tokens:     #{stats.total_tokens}")
    IO.puts("  • Estimated Cost (USD):     $#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}\n")

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
    IO.puts("\n#{Formatter.bold()}Discovered Skills (#{length(skills)}):#{Formatter.reset()}")

    Enum.each(skills, fn s ->
      IO.puts("  • #{Formatter.cyan()}#{s.name}#{Formatter.reset()} [#{Path.basename(s.path)}]: #{s.description}")
    end)

    IO.puts("")
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
        IO.puts("\n#{Formatter.cyan()}🤖 Subagent Completed Result:#{Formatter.reset()}\n#{result}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error("Subagent failed: #{err}"))
    end

    :continue
  end

  def handle_input("/plugins", _session_pid, _session_id) do
    tools = PluginLoader.list_tools()
    IO.puts("\n#{Formatter.bold()}Registered Tools (#{length(tools)}):#{Formatter.reset()}")

    Enum.each(tools, fn t ->
      IO.puts("  • #{Formatter.cyan()}#{t.name}#{Formatter.reset()}: #{t.description}")
    end)

    IO.puts("")
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

  def handle_input("/mcp", _session_pid, _session_id) do
    servers = MCPServerManager.list_servers()
    IO.puts("\n#{Formatter.bold()}Connected MCP Servers (#{length(servers)}):#{Formatter.reset()}")

    Enum.each(servers, fn s ->
      IO.puts("  • #{Formatter.cyan()}#{s.name}#{Formatter.reset()} (#{s.command} #{Enum.join(s.args, " ")}): #{s.tools_count} tools registered")
      Enum.each(s.tools, fn t ->
        IO.puts("      └─ #{t}")
      end)
    end)

    IO.puts("")
    :continue
  end

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
    IO.puts(Formatter.format_info("Connecting to Ragex MCP server (@../ragex)..."))

    case MCPServerManager.start_ragex() do
      {:ok, dir, tools} ->
        IO.puts(Formatter.format_success("Connected Ragex MCP server from '#{dir}'! Registered #{length(tools)} code analysis & refactoring tools."))

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

    IO.puts("\n#{Formatter.bold()}Active Session Status:#{Formatter.reset()}")
    IO.puts("  • Session ID:    #{info.session_id}")
    IO.puts("  • Actor PID:     #{inspect(info.pid)}")
    IO.puts("  • Model:         #{Formatter.cyan()}#{info.model}#{Formatter.reset()}")
    IO.puts("  • Permission:    #{info.permission_mode}")
    IO.puts("  • History Size:  #{info.message_count} messages")
    IO.puts("  • Checkpoints:   #{info.snapshot_count} snapshots")
    IO.puts("  • Hands Mode:    #{info.hands_mode} (#{info.hands_target})")
    IO.puts("  • Active Tools:  #{info.tools_count} registered\n")
    :continue
  end

  def handle_input("/nodes", _session_pid, _session_id) do
    data = NodeManager.list_nodes()

    IO.puts("\n#{Formatter.bold()}Distributed Erlang Node Cluster:#{Formatter.reset()}")
    IO.puts("  • Local Node:    #{data.self}")
    IO.puts("  • Node Alive?:   #{data.alive?}")
    IO.puts("  • Connected Nodes: #{inspect(data.connected)}\n")
    :continue
  end

  def handle_input(user_prompt, session_pid, _session_id) do
    IO.puts("#{Formatter.dim()}Thinking and coordinating with Hands...#{Formatter.reset()}")

    case Session.send_user_message(session_pid, user_prompt) do
      {:ok, %{content: content}} ->
        IO.puts("\n" <> Formatter.format_agent_response(content) <> "\n")

      {:error, reason} ->
        IO.puts(Formatter.format_error("Turn failed: #{reason}"))
    end

    :continue
  end
end
