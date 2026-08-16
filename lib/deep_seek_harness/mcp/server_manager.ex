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
    send(self(), :auto_start_ragex)
    {:ok, %{servers: %{}}}
  end

  @impl true
  def handle_info(:auto_start_ragex, state) do
    cwd = File.cwd!()

    case do_start_ragex(cwd, []) do
      {:ok, dir, tools_registered} ->
        new_servers =
          Map.put(state.servers, "ragex", %{
            command: "in_process",
            args: [],
            cwd: dir,
            tools: tools_registered
          })

        {:noreply, %{state | servers: new_servers}}

      {:error, reason} ->
        Logger.warning("⚡🔌 Ragex auto-start notice: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[ServerManager] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
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
      configure_ragex_store()

      Logger.info("⚡🔌 Auto-indexing codebase in '#{target_dir}' via Ragex...")

      case Ragex.Analyzers.Directory.analyze_directory(target_dir) do
        {:ok, stats} ->
          Logger.info(
            "⚡🔌 Ragex indexing complete! Indexed #{stats.success} files into Knowledge Graph."
          )

        {:error, reason} ->
          Logger.warning("⚡🔌 Ragex indexing notice: #{inspect(reason)}")
      end

      tools = Ragex.MCP.Handlers.Tools.list_tools()

      registered_names =
        Enum.map(tools, fn t ->
          t_name = Map.get(t, "name") || Map.get(t, :name)
          t_desc = Map.get(t, "description") || Map.get(t, :description) || "Ragex tool #{t_name}"

          input_schema =
            Map.get(t, "inputSchema") || Map.get(t, :inputSchema) ||
              %{"type" => "object", "properties" => %{}}

          tool_name = "mcp_ragex_#{t_name}"

          tool_def = %{
            name: tool_name,
            description: "[MCP:ragex] #{t_desc}",
            parameters: input_schema,
            execute: fn args ->
              case Ragex.MCP.Handlers.Tools.call_tool(t_name, args) do
                {:ok, result} -> {:ok, format_mcp_content(result)}
                {:error, err} -> {:error, "Ragex tool error: #{inspect(err)}"}
                other -> {:ok, inspect(other, pretty: true)}
              end
            end
          }

          register_mcp_tool_in_plugin(tool_def)
          tool_name
        end)

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

  defp configure_ragex_store do
    use_dllb? = Code.ensure_loaded?(Dllb)
    backend = if use_dllb?, do: :dllb, else: :ets

    Application.put_env(:ragex, :store_backend, backend)
    if use_dllb?, do: Application.put_env(:dllb, :enabled, true)

    Logger.info(
      "⚡🔌 Ragex Knowledge Graph backend configured: #{backend} (dllb active: #{use_dllb?})"
    )
  end

  # Helper Functions

  def discover_ragex_dir(start_dir \\ ".") do
    candidates = [
      "/opt/Proyectos/Oeditus/ragex",
      Path.expand("../ragex", start_dir),
      Path.expand("~/Proyectos/Oeditus/ragex", start_dir),
      start_dir
    ]

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
            registered_names =
              Enum.map(mcp_tools, fn t ->
                tool_name = "mcp_#{name}_#{t["name"]}"
                desc = Map.get(t, "description", "MCP Tool from #{name}")

                input_schema =
                  Map.get(t, "inputSchema", %{"type" => "object", "properties" => %{}})

                tool_def = %{
                  name: tool_name,
                  description: "[MCP:#{name}] #{desc}",
                  parameters: input_schema,
                  execute: fn arguments ->
                    case MCPClient.call_mcp_tool(client_pid, t["name"], arguments) do
                      {:ok, %{"content" => content}} -> {:ok, format_mcp_content(content)}
                      {:ok, res} -> {:ok, inspect(res, pretty: true)}
                      {:error, err} -> {:error, "MCP tool error: #{inspect(err)}"}
                    end
                  end
                }

                register_mcp_tool_in_plugin(tool_def)
                tool_name
              end)

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

  defp register_mcp_tool_in_plugin(tool_def) do
    dynamic_mod_name = String.to_atom("Elixir.DeepSeekHarness.Plugin.MCP_#{tool_def.name}")

    contents = """
    defmodule #{dynamic_mod_name} do
      @behaviour DeepSeekHarness.Plugin.Behaviour

      def name, do: "#{tool_def.name}"
      def description, do: "#{String.replace(tool_def.description, "\"", "\\\"")}"
      def tools, do: [#{inspect(tool_def)}]
    end
    """

    [{mod, _}] = Code.compile_string(contents)
    PluginLoader.register_plugin(mod)
  end

  defp format_mcp_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      item -> inspect(item)
    end)
  end

  defp format_mcp_content(content), do: inspect(content, pretty: true)
end
