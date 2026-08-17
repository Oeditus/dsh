defmodule DeepSeekHarness.MCP.ServerManager do
  @moduledoc """
  Manages connections to external Model Context Protocol (MCP) servers, with first-class
  support for the `ragex` code intelligence & analysis MCP server.

  Launches MCP server processes over stdio (JSON-RPC), fetches declared tools,
  and registers them with DeepSeekHarness.Plugin.Loader for live hot-code tool access.
  """
  use GenServer
  require Logger

  alias DeepSeekHarness.Config
  alias DeepSeekHarness.MCP.Client, as: MCPClient
  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Connects and registers an MCP server given name, command, args, and optional cwd/env."
  def add_server(name, command, args \\ [], opts \\ []) do
    GenServer.call(@name, {:add_server, name, command, args, opts}, 45_000)
  end

  @doc "Starts and registers Ragex (@../ragex) as a first-class MCP server targeting specified working directory."
  def start_ragex(opts \\ []) do
    target_dir = opts[:target_dir] || opts[:cwd] || File.cwd!()
    GenServer.call(@name, {:start_ragex, target_dir, opts}, 60_000)
  end

  @doc "Lists active connected MCP servers."
  def list_servers do
    GenServer.call(@name, :list_servers)
  end

  @doc "Loads all configured MCP servers from ~/.dsh/config.json or .dsh/config.json."
  def load_from_config(cwd \\ ".") do
    GenServer.call(@name, {:load_from_config, cwd}, 60_000)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    if Application.get_env(:deep_seek_harness, :auto_start_ragex, true) do
      send(self(), :auto_start_ragex)
    end

    {:ok, %{servers: %{}}}
  end

  @impl true
  def handle_info(:auto_start_ragex, state) do
    cwd = File.cwd!()

    Task.start(fn ->
      case do_start_ragex(cwd, []) do
        {:ok, dir, tools_registered} ->
          GenServer.cast(@name, {:ragex_started, dir, tools_registered})

        {:error, reason} ->
          Logger.warning("⚡🔌 Ragex auto-start notice: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[ServerManager] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:ragex_started, dir, tools_registered}, state) do
    new_servers =
      Map.put(state.servers, "ragex", %{
        command: "in_process",
        args: [],
        cwd: dir,
        tools: tools_registered
      })

    {:noreply, %{state | servers: new_servers}}
  end

  @impl true
  def handle_call({:add_server, name, command, args, opts}, _from, state) do
    case start_and_register_mcp_server(name, command, args, opts) do
      {:ok, tools_registered, pid} ->
        new_servers =
          Map.put(state.servers, name, %{
            command: command,
            args: args,
            cwd: opts[:cwd],
            pid: pid,
            tools: tools_registered
          })

        {:reply, {:ok, tools_registered}, %{state | servers: new_servers}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:start_ragex, target_dir, opts}, _from, state) do
    case do_start_ragex(target_dir, opts) do
      {:ok, dir, tools_registered} ->
        new_servers =
          Map.put(state.servers, "ragex", %{
            command: "in_process",
            args: [],
            cwd: dir,
            tools: tools_registered
          })

        {:reply, {:ok, dir, tools_registered}, %{state | servers: new_servers}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    info =
      Enum.map(state.servers, fn {name, srv} ->
        %{
          name: name,
          command: srv.command,
          args: srv.args,
          cwd: srv[:cwd],
          tools_count: length(srv.tools),
          tools: srv.tools
        }
      end)

    {:reply, info, state}
  end

  @impl true
  def handle_call({:load_from_config, cwd}, _from, state) do
    cfg = Config.load_config(cwd)
    mcp_servers = Map.get(cfg, "mcp_servers", %{})

    results =
      Enum.map(mcp_servers, fn {name, srv_cfg} ->
        cmd = Map.get(srv_cfg, "command", "npx")
        args = Map.get(srv_cfg, "args", [])
        srv_cwd = Map.get(srv_cfg, "cwd")
        srv_env = Map.get(srv_cfg, "env", %{})

        opts = []
        opts = if srv_cwd, do: Keyword.put(opts, :cwd, srv_cwd), else: opts
        opts = if srv_env != %{}, do: Keyword.put(opts, :env, srv_env), else: opts

        {name, add_server(name, cmd, args, opts)}
      end)

    {:reply, {:ok, results}, state}
  end

  defp do_start_ragex(target_dir, opts) do
    if Code.ensure_loaded?(Ragex.MCP.Handlers.Tools) do
      DeepSeekHarness.CLI.Spinner.run(
        fn ->
          orig_level = Logger.level()
          Logger.configure(level: :warning)

          try do
            configure_ragex_store(target_dir)

            existing_nodes =
              if Code.ensure_loaded?(Ragex.Graph.Store) do
                try do
                  stats = Ragex.Graph.Store.stats()
                  Map.get(stats, :nodes, 0) + Map.get(stats, :total, 0)
                rescue
                  _ -> 0
                catch
                  _, _ -> 0
                end
              else
                0
              end

            if existing_nodes > 0 do
              Logger.configure(level: orig_level)

              Logger.info("⚡🔌 Ragex Knowledge Graph loaded from store (#{existing_nodes} nodes).")
            else
              case Ragex.Analyzers.Directory.analyze_directory(target_dir) do
                {:ok, stats} ->
                  Logger.configure(level: orig_level)

                  Logger.info(
                    "⚡🔌 Ragex indexing complete! Indexed #{stats.success} files into Knowledge Graph."
                  )

                {:error, reason} ->
                  Logger.configure(level: orig_level)
                  Logger.warning("⚡🔌 Ragex indexing notice: #{inspect(reason)}")
              end
            end
          after
            Logger.configure(level: orig_level)
          end
        end,
        title: "Initializing Ragex Knowledge Graph...",
        tip: false
      )

      raw_tools = Ragex.MCP.Handlers.Tools.list_tools()
      tools_list = Map.get(raw_tools, :tools, [])

      built =
        Enum.map(tools_list, fn t ->
          t_name = Map.get(t, "name") || Map.get(t, :name)
          t_desc = Map.get(t, "description") || Map.get(t, :description) || "Ragex tool #{t_name}"

          input_schema =
            Map.get(t, "inputSchema") || Map.get(t, :inputSchema) ||
              %{"type" => "object", "properties" => %{}}

          tool_name = "mcp_ragex_#{t_name}"

          dynamic_mod_name = build_mcp_ragex_tool_module(tool_name, t_name, t_desc, input_schema)
          {tool_name, dynamic_mod_name}
        end)

      # Register every dynamically generated module in a single batch call so
      # sessions receive one "tools reloaded" notification instead of one per tool.
      PluginLoader.register_plugins(Enum.map(built, fn {_tool_name, mod} -> mod end))
      registered_names = Enum.map(built, fn {tool_name, _mod} -> tool_name end)

      Logger.info("● DeepSeek Harness initialization complete! System is ready.")
      {:ok, target_dir, registered_names}
    else
      start_ragex_external(target_dir, opts)
    end
  end

  defp start_ragex_external(target_dir, opts) do
    ragex_dir = discover_ragex_dir(opts[:ragex_dir] || ".")

    case ragex_dir do
      {:ok, dir} ->
        script_path = Path.join(dir, "bin/ragex-mcp")

        {cmd, args, run_opts} =
          if File.exists?(script_path) do
            {script_path, ["--project", target_dir],
             [
               cwd: dir,
               env: %{"MIX_ENV" => "prod", "RAGEX_STDIO" => "1", "RAGEX_PROJECT" => target_dir}
             ]}
          else
            {"mix", ["run", "--no-halt", "--", "--project", target_dir],
             [
               cwd: dir,
               env: %{"MIX_ENV" => "prod", "RAGEX_STDIO" => "1", "RAGEX_PROJECT" => target_dir}
             ]}
          end

        case start_and_register_mcp_server("ragex", cmd, args, run_opts) do
          {:ok, tools_registered, _pid} ->
            {:ok, target_dir, tools_registered}

          {:error, reason} ->
            {:error, "Failed to start ragex MCP server: #{reason}"}
        end

      {:error, err} ->
        {:error, err}
    end
  end

  defp configure_ragex_store(target_dir) do
    use_dllb? = Code.ensure_loaded?(Dllb)
    backend = if use_dllb?, do: :dllb, else: :ets

    host = System.get_env("DLLB_HOST", Application.get_env(:dllb, :host, "127.0.0.1"))

    port =
      case System.get_env("DLLB_PORT") do
        nil -> Application.get_env(:dllb, :port, 3009)
        p -> String.to_integer(p)
      end

    pool_size =
      case System.get_env("DLLB_POOL_SIZE") do
        nil -> Application.get_env(:dllb, :pool_size, 30)
        p -> String.to_integer(p)
      end

    dllb_mode =
      case System.get_env("DLLB_MODE") do
        "per_project" -> :per_project
        "global" -> :global
        _ -> Application.get_env(:ragex, :dllb_mode, :per_project)
      end

    Application.put_env(:ragex, :store_backend, backend)
    Application.put_env(:ragex, :dllb_mode, dllb_mode)

    if use_dllb? do
      Application.put_env(:dllb, :enabled, true)
      Application.put_env(:dllb, :host, host)
      Application.put_env(:dllb, :port, port)
      Application.put_env(:dllb, :pool_size, pool_size)

      if dllb_mode == :per_project and Code.ensure_loaded?(Ragex.Dllb.ProjectManager) do
        case Ragex.Dllb.ProjectManager.set_active_project(target_dir) do
          :ok ->
            Logger.info("⚡🔌 Per-project Dllb instance active for #{target_dir}")

          {:error, reason} ->
            Logger.warning("⚡🔌 Per-project Dllb notice: #{inspect(reason)}")
        end
      else
        # Ensure Dllb.Pool is started under Dllb.Supervisor if not running
        if Process.whereis(Dllb.Pool) == nil and Process.whereis(Dllb.Supervisor) != nil do
          pool_opts = [
            host: host,
            port: port,
            pool_size: pool_size,
            outcome: Application.get_env(:dllb, :outcome, :json),
            timeout: Application.get_env(:dllb, :timeout, 30_000)
          ]

          case Supervisor.start_child(Dllb.Supervisor, Dllb.Pool.child_spec(pool_opts)) do
            {:ok, _pid} ->
              Logger.info("⚡🔌 Dllb.Pool started on #{host}:#{port} (pool size: #{pool_size})")

            {:error, {:already_started, _pid}} ->
              :ok

            {:error, reason} ->
              Logger.warning("⚡🔌 Failed to start Dllb.Pool: #{inspect(reason)}")
          end
        end
      end

      # Fast check: skip schema bootstrapping if ast_node table already exists
      if Process.whereis(Dllb.Pool) != nil or dllb_mode == :per_project do
        already_bootstrapped? =
          try do
            case Ragex.Store.Backend.Dllb.query("SELECT * FROM ast_node LIMIT 1;") do
              {:ok, _} -> true
              _ -> false
            end
          rescue
            _ -> false
          catch
            _, _ -> false
          end

        if already_bootstrapped? do
          Logger.info("⚡🔌 Dllb schema ready for Ragex Knowledge Graph")
        else
          Logger.info("⌛ Bootstrapping Dllb database schema...")

          case Ragex.Store.Backend.Dllb.bootstrap() do
            :ok ->
              Logger.info("⚡🔌 Dllb schema bootstrapped for Ragex Knowledge Graph")

            {:error, reason} ->
              Logger.warning("⚡🔌 Dllb schema bootstrap notice: #{inspect(reason)}")
          end
        end
      end
    end

    Logger.info(
      "⚡🔌 Ragex Knowledge Graph backend configured: #{backend} (mode: #{dllb_mode}, dllb active: #{use_dllb?})"
    )
  end

  # Helper Functions

  def discover_ragex_dir(start_dir \\ ".") do
    env_path = System.get_env("RAGEX_PATH") || Application.get_env(:deep_seek_harness, :ragex_path)

    candidates =
      [
        env_path,
        Path.expand("../ragex", start_dir),
        Path.expand("./ragex", start_dir),
        "/opt/Proyectos/Oeditus/ragex",
        Path.expand("~/Proyectos/Oeditus/ragex", start_dir),
        start_dir
      ]
      |> Enum.reject(&is_nil/1)

    found =
      Enum.find(candidates, fn path ->
        File.exists?(Path.join(path, "mix.exs")) and
          (File.exists?(Path.join(path, "bin/ragex-mcp")) or
             File.exists?(Path.join(path, "lib/ragex")))
      end)

    if found do
      {:ok, found}
    else
      {:error, "Ragex directory not found in candidate paths: #{inspect(candidates)}"}
    end
  end

  defp start_and_register_mcp_server(name, command, args, opts) do
    client_opts = [name: name, command: command, args: args, cwd: opts[:cwd], env: opts[:env]]

    case MCPClient.start_link(client_opts) do
      {:ok, client_pid} ->
        case MCPClient.list_mcp_tools(client_pid) do
          {:ok, %{"tools" => mcp_tools}} when is_list(mcp_tools) ->
            built =
              Enum.map(mcp_tools, fn t ->
                tool_name = "mcp_#{name}_#{t["name"]}"
                desc = Map.get(t, "description", "MCP Tool from #{name}")

                input_schema =
                  Map.get(t, "inputSchema", %{"type" => "object", "properties" => %{}})

                dynamic_mod_name =
                  build_mcp_client_tool_module(
                    name,
                    tool_name,
                    t["name"],
                    desc,
                    input_schema,
                    client_pid
                  )

                {tool_name, dynamic_mod_name}
              end)

            # Single batch registration -- avoids one "tools reloaded" notification per tool.
            PluginLoader.register_plugins(Enum.map(built, fn {_tool_name, mod} -> mod end))
            registered_names = Enum.map(built, fn {tool_name, _mod} -> tool_name end)

            {:ok, registered_names, client_pid}

          {:ok, other} ->
            {:error, "Unexpected tools/list output from MCP server: #{inspect(other)}"}

          {:error, err} ->
            {:error, "Failed to fetch tools/list from MCP server #{name}: #{inspect(err)}"}
        end

      {:error, reason} ->
        {:error,
         "Failed to start MCP server process (#{command} #{Enum.join(args, " ")}): #{inspect(reason)}"}
    end
  end

  @doc "Executes a Ragex MCP tool by target name with args."
  def execute_ragex_tool(t_name, args) do
    case Ragex.MCP.Handlers.Tools.call_tool(t_name, args) do
      {:ok, result} -> {:ok, format_mcp_content(result)}
      {:error, err} -> {:error, "Ragex tool error: #{inspect(err)}"}
      other -> {:ok, inspect(other, pretty: true)}
    end
  end

  @doc "Executes an external stdio MCP tool by target name with args."
  def execute_mcp_client_tool(client_pid, mcp_tool_name, arguments) do
    case MCPClient.call_mcp_tool(client_pid, mcp_tool_name, arguments) do
      {:ok, %{"content" => content}} -> {:ok, format_mcp_content(content)}
      {:ok, res} -> {:ok, inspect(res, pretty: true)}
      {:error, err} -> {:error, "MCP tool error: #{inspect(err)}"}
    end
  end

  defp build_mcp_ragex_tool_module(tool_name, t_name, t_desc, input_schema) do
    exec_ast =
      quote do
        DeepSeekHarness.MCP.ServerManager.execute_ragex_tool(unquote(t_name), args)
      end

    build_dynamic_tool_module(tool_name, "ragex", t_desc, input_schema, exec_ast)
  end

  defp build_mcp_client_tool_module(
         server_name,
         tool_name,
         mcp_tool_name,
         desc,
         input_schema,
         client_pid
       ) do
    exec_ast =
      quote do
        DeepSeekHarness.MCP.ServerManager.execute_mcp_client_tool(
          unquote(client_pid),
          unquote(mcp_tool_name),
          args
        )
      end

    build_dynamic_tool_module(tool_name, server_name, desc, input_schema, exec_ast)
  end

  defp build_dynamic_tool_module(tool_name, server_tag, desc, input_schema, exec_ast) do
    dynamic_mod_name = String.to_atom("Elixir.DeepSeekHarness.Plugin.MCP_#{tool_name}")

    :code.purge(dynamic_mod_name)
    :code.delete(dynamic_mod_name)

    Module.create(
      dynamic_mod_name,
      quote do
        @behaviour DeepSeekHarness.Plugin.Behaviour

        def name, do: unquote(tool_name)
        def description, do: unquote("[MCP:#{server_tag}] #{desc}")

        def execute(args) do
          unquote(exec_ast)
        end

        def tools do
          [
            %{
              name: unquote(tool_name),
              description: unquote("[MCP:#{server_tag}] #{desc}"),
              parameters: unquote(Macro.escape(input_schema)),
              execute: &execute/1
            }
          ]
        end
      end,
      Macro.Env.location(__ENV__)
    )

    dynamic_mod_name
  end

  defp format_mcp_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      item -> inspect(item)
    end)
  end

  defp format_mcp_content(content), do: inspect(content, pretty: true)
end
