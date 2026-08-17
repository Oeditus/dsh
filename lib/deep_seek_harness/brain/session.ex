defmodule DeepSeekHarness.Brain.Session do
  @moduledoc """
  The "Brain" actor of DeepSeek Harness.
  Manages agentic session state, temporal context checkpoints, conversation memory,
  subagent spawning, project rules, context expansion, permission authorization gates,
  and execution loops.
  """
  use GenServer
  require Logger

  alias DeepSeekHarness.Brain.AgentLoop
  alias DeepSeekHarness.Brain.ContextCompressor
  alias DeepSeekHarness.Brain.SessionStore
  alias DeepSeekHarness.CLI.ContextExpander
  alias DeepSeekHarness.Client.DeepSeekAPI
  alias DeepSeekHarness.Config
  alias DeepSeekHarness.Hands.Executor, as: HandsExecutor
  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader

  @default_system_prompt """
  You are an expert agentic AI coding assistant powered by DeepSeek.
  You have access to tools for file operations, bash execution, skills, MCP servers, Elixir evaluation, and interactive user questions (ask_question tool).
  Break down tasks systematically, reason carefully, and invoke tools when needed.
  If requirements are underspecified, design choices need feedback, or confirmation is helpful, use the `ask_question` tool to present structured choices to the user.
  """

  # Client API

  def start_link(opts \\ []) do
    session_id = opts[:session_id] || "default"
    name = via_tuple(session_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def via_tuple(session_id) do
    {:via, Registry, {DeepSeekHarness.Registry, "session_" <> session_id}}
  end

  @doc "Sends a user prompt to the session actor, expanding @ references."
  def send_user_message(pid, text) do
    GenServer.call(pid, {:send_user_message, text}, :infinity)
  end

  @doc "Sets the DeepSeek model ('deepseek-chat' or 'deepseek-reasoner')."
  def set_model(pid, model) do
    GenServer.call(pid, {:set_model, model}, :infinity)
  end

  @doc "Sets permission mode (:auto_approve | :ask_confirm)."
  def set_permission_mode(pid, mode) do
    GenServer.call(pid, {:set_permission_mode, mode}, :infinity)
  end

  @doc "Configures the Hands execution mode (:local, :remote, :docker)."
  def set_hands_mode(pid, mode, target \\ nil) do
    GenServer.call(pid, {:set_hands_mode, mode, target}, :infinity)
  end

  @doc "Compresses context history (/compact)."
  def compact_context(pid) do
    GenServer.call(pid, :compact_context, :infinity)
  end

  @doc "Creates a temporal state snapshot (checkpoint)."
  def checkpoint(pid, label \\ nil) do
    GenServer.call(pid, {:checkpoint, label}, :infinity)
  end

  @doc "Rolls back session state to previous checkpoint."
  def undo(pid) do
    GenServer.call(pid, :undo, :infinity)
  end

  @doc "Spawns a subagent session actor for sub-task execution."
  def spawn_subagent(pid, prompt, opts \\ []) do
    GenServer.call(pid, {:spawn_subagent, prompt, opts}, :infinity)
  end

  @doc "Generates a comprehensive Code Review comparing two git branches."
  def generate_code_review(pid, base_branch, head_branch \\ "HEAD") do
    GenServer.call(pid, {:generate_code_review, base_branch, head_branch}, :infinity)
  end

  @doc "Returns token stats and session cost estimate."
  def get_token_stats(pid) do
    GenServer.call(pid, :get_token_stats, :infinity)
  end

  @doc "Returns current session summary and statistics."
  def get_info(pid) do
    GenServer.call(pid, :get_info, :infinity)
  end

  @doc "Returns content of the latest assistant message response in session."
  def get_latest_response(pid) do
    GenServer.call(pid, :get_latest_response, :infinity)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = opts[:session_id] || "default"
    base_sys_prompt = opts[:system_prompt] || @default_system_prompt

    # Inject workspace project rules if available (.dshrules, .dsh/rules.md)
    rules = Config.discover_project_rules(opts[:cwd] || ".")

    system_prompt =
      if rules != "" do
        base_sys_prompt <> "\n\n" <> rules
      else
        base_sys_prompt
      end

    # Register in PubSub registry "sessions" group for hot-code tool reload broadcasts
    Registry.register(DeepSeekHarness.PubSubRegistry, "sessions", session_id)

    tools = PluginLoader.list_tools()
    initial_messages = [%{"role" => "system", "content" => system_prompt}]

    state = %{
      session_id: session_id,
      model: opts[:model] || System.get_env("DEEPSEEK_MODEL") || "deepseek-chat",
      permission_mode: opts[:permission_mode] || :ask_confirm,
      session_tool_permissions: %{},
      api_key: opts[:api_key] || System.get_env("DEEPSEEK_API_KEY"),
      hands: %HandsExecutor{mode: :local},
      messages: initial_messages,
      tools: tools,
      tool_failure_counts: %{},
      snapshots: [],
      step_count: 0,
      max_tool_depth: opts[:max_tool_depth] || 50,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      cwd: opts[:cwd] || ".",
      status: :idle
    }

    # Attempt to restore session state if persisted
    state =
      case SessionStore.load_session(session_id, state.cwd) do
        {:ok, saved_data} ->
          Logger.info("[Brain.Session] Restored persisted session state for '#{session_id}'")
          %{state | messages: saved_data["messages"] || initial_messages}

        _ ->
          state
      end

    Logger.info(
      "[Brain.Session] Session actor initialized: #{session_id} (model: #{state.model})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:send_user_message, raw_text}, _from, state) do
    # Expand @filename, @relative_path, @file://..., @https://... references
    {:ok, expanded_text, _attachments} = ContextExpander.expand(raw_text, state.cwd)

    user_msg = %{"role" => "user", "content" => expanded_text}
    state = %{state | messages: state.messages ++ [user_msg], status: :thinking}

    state = auto_checkpoint(state, "Pre-turn ##{state.step_count + 1}")

    {final_response, new_state} = run_agent_loop(state, state.max_tool_depth)
    {:reply, final_response, new_state}
  end

  @impl true
  def handle_call({:set_model, model}, _from, state) do
    new_state = %{state | model: model}
    {:reply, {:ok, model}, new_state}
  end

  @impl true
  def handle_call({:set_permission_mode, mode}, _from, state) do
    new_state = %{state | permission_mode: mode}
    {:reply, {:ok, mode}, new_state}
  end

  @impl true
  def handle_call({:set_hands_mode, mode, target}, _from, state) do
    hands =
      case mode do
        :remote -> %HandsExecutor{mode: :remote, remote_node: target}
        :docker -> %HandsExecutor{mode: :docker, docker_container: target}
        _ -> %HandsExecutor{mode: :local}
      end

    new_state = %{state | hands: hands}
    {:reply, {:ok, hands}, new_state}
  end

  @impl true
  def handle_call(:compact_context, _from, state) do
    opts = [model: state.model, api_key: state.api_key]

    case ContextCompressor.compress_messages(state.messages, opts) do
      {:ok, new_messages, summary} ->
        new_state = %{state | messages: new_messages}
        SessionStore.save_session(new_state, state.cwd)
        {:reply, {:ok, summary}, new_state}

      {:error, err} ->
        {:reply, {:error, err}, state}
    end
  end

  @impl true
  def handle_call({:checkpoint, label}, _from, state) do
    label = label || "Manual Checkpoint ##{length(state.snapshots) + 1}"

    snapshot = %{
      id: "cp_#{System.unique_integer([:positive])}",
      label: label,
      timestamp: DateTime.utc_now(),
      messages: state.messages,
      model: state.model
    }

    new_state = %{state | snapshots: [snapshot | state.snapshots]}
    SessionStore.save_session(new_state, state.cwd)
    {:reply, {:ok, snapshot}, new_state}
  end

  @impl true
  def handle_call(:undo, _from, state) do
    case state.snapshots do
      [latest | rest] ->
        Logger.info("[Brain.Session] Rolling back state to snapshot: #{latest.label}")

        new_state = %{
          state
          | messages: latest.messages,
            model: latest.model,
            snapshots: rest
        }

        SessionStore.save_session(new_state, state.cwd)
        {:reply, {:ok, "Rolled back to checkpoint: '#{latest.label}'"}, new_state}

      [] ->
        {:reply, {:error, "No checkpoints available to undo."}, state}
    end
  end

  @impl true
  def handle_call({:spawn_subagent, prompt, opts}, _from, state) do
    sub_id = "sub_#{System.unique_integer([:positive])}"
    async? = Keyword.get(opts, :async, false)

    Logger.info("[Brain.Session] Spawning subagent session '#{sub_id}' (async: #{async?})")

    if async? do
      parent_pid = self()

      Task.start(fn ->
        case DeepSeekHarness.Brain.SessionSupervisor.start_session(
               session_id: sub_id,
               model: state.model,
               cwd: state.cwd
             ) do
          {:ok, sub_pid} ->
            res = send_user_message(sub_pid, prompt)
            send(parent_pid, {:subagent_completed, sub_id, res})
            DeepSeekHarness.Brain.SessionSupervisor.stop_session(sub_pid)

          {:error, err} ->
            send(parent_pid, {:subagent_completed, sub_id, {:error, err}})
        end
      end)

      {:reply, {:ok, "Subagent '#{sub_id}' spawned asynchronously."}, state}
    else
      case DeepSeekHarness.Brain.SessionSupervisor.start_session(
             session_id: sub_id,
             model: state.model,
             cwd: state.cwd
           ) do
        {:ok, sub_pid} ->
          case send_user_message(sub_pid, prompt) do
            {:ok, response} ->
              DeepSeekHarness.Brain.SessionSupervisor.stop_session(sub_pid)
              {:reply, {:ok, response.content}, state}

            {:error, err} ->
              DeepSeekHarness.Brain.SessionSupervisor.stop_session(sub_pid)
              {:reply, {:error, err}, state}
          end

        {:error, err} ->
          {:reply, {:error, "Failed to spawn subagent: #{inspect(err)}"}, state}
      end
    end
  end

  @impl true
  def handle_call({:generate_code_review, base_branch, head_branch}, _from, state) do
    case DeepSeekHarness.Git.diff_branches(base_branch, head_branch, state.cwd) do
      {:ok, data} ->
        prompt = """
        Perform a thorough, expert production Code Review comparing base branch '#{data.base}' against head branch '#{data.head}'.

        ### Branch Comparison Data
        - Base Branch: #{data.base}
        - Head Branch: #{data.head}

        ### Commits Included in Branch Range
        #{data.log}

        ### Diff Summary (--stat)
        #{data.stat}

        ### Code Diff Payload
        ```diff
        #{data.raw_diff}
        ```

        Please generate a detailed, structured Code Review in GitHub-flavored Markdown:
        1. **Executive Summary**: Architectural purpose & high-level review summary.
        2. **Key Modifications & Feature Breakdown**: File-by-file analysis of major changes.
        3. **Risk & Edge Case Assessment**: Potential bugs, security flaws, breaking changes, or performance risks.
        4. **Actionable Recommendations**: Specific code refactoring snippets & improvements.
        5. **Test & Verification Coverage**: Assessment of missing test cases.
        6. **GitHub PR Review Formatted Block**: A ready-to-post Markdown comment block formatted for GitHub Pull Request review.
        """

        user_msg = %{"role" => "user", "content" => prompt}
        state_with_msg = %{state | messages: state.messages ++ [user_msg], status: :thinking}

        {final_response, new_state} = run_agent_loop(state_with_msg, state.max_tool_depth)
        {:reply, final_response, new_state}

      {:error, err} ->
        {:reply, {:error, err}, state}
    end
  end

  @impl true
  def handle_call(:get_token_stats, _from, state) do
    prompt_tokens = state.total_prompt_tokens
    completion_tokens = state.total_completion_tokens
    total = prompt_tokens + completion_tokens

    # DeepSeek Pricing: V3 prompt $0.14/1M, completion $0.28/1M
    cost_prompt = prompt_tokens * 0.00000014
    cost_completion = completion_tokens * 0.00000028
    total_cost = cost_prompt + cost_completion

    stats = %{
      tracked_prompt_tokens: prompt_tokens,
      tracked_completion_tokens: completion_tokens,
      total_tokens: total,
      estimated_cost_usd: Float.round(total_cost, 6)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      session_id: state.session_id,
      model: state.model,
      permission_mode: state.permission_mode,
      message_count: length(state.messages),
      snapshot_count: length(state.snapshots),
      hands_mode: state.hands.mode,
      hands_target: state.hands.remote_node || state.hands.docker_container || "local",
      tools_count: length(state.tools),
      status: state.status,
      pid: self()
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_latest_response, _from, state) do
    last_assistant_msg =
      state.messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m["role"] == "assistant" end)

    case last_assistant_msg do
      %{"content" => content} when is_binary(content) and content != "" ->
        {:reply, {:ok, content}, state}

      _ ->
        {:reply, {:error, "No assistant response found in active session history."}, state}
    end
  end

  @impl true
  def handle_info({:hot_reload_tools, new_tools}, state) do
    Logger.debug(
      "[Brain.Session] Hot-reloaded tools dynamically without dropping conversation state! (Tools: #{length(new_tools)})"
    )

    {:noreply, %{state | tools: new_tools}}
  end

  @impl true
  def handle_info({:tools_reloaded, new_tools}, state) do
    Logger.debug(
      "[Brain.Session] Dynamic tools updated without dropping conversation state (#{length(new_tools)} tools active)."
    )

    {:noreply, %{state | tools: new_tools}}
  end

  @impl true
  def handle_info({:subagent_completed, sub_id, result}, state) do
    Logger.info("[Brain.Session] Async subagent '#{sub_id}' completed with result.")

    notice_content =
      case result do
        {:ok, text} -> "=== Async Subagent Result (#{sub_id}) ===\n#{text}\n"
        {:error, err} -> "=== Async Subagent Failure (#{sub_id}) ===\n#{err}\n"
      end

    notice = %{"role" => "user", "content" => notice_content}
    {:noreply, %{state | messages: state.messages ++ [notice]}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Brain.Session] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  # Agent Execution Loop

  defp run_agent_loop(state, depth) when depth <= 0,
    do: {{:error, "Max tool iteration depth reached."}, state}

  defp run_agent_loop(state, depth) do
    opts = [model: state.model, api_key: state.api_key]

    case DeepSeekAPI.chat_completion(state.messages, state.tools, opts) do
      {:ok, %{tool_calls: tool_calls} = response} when is_list(tool_calls) and tool_calls != [] ->
        state = accumulate_usage(state, response[:usage])

        if response[:reasoning_content] do
          Logger.info("[DeepSeek-R1 Reasoning]\n#{response.reasoning_content}")
        end

        assistant_msg =
          %{
            "role" => "assistant",
            "content" => response.content || "",
            "tool_calls" =>
              Enum.map(tool_calls, fn tc ->
                %{
                  "id" => tc.id,
                  "type" => "function",
                  "function" => %{
                    "name" => tc.name,
                    "arguments" => Jason.encode!(tc.arguments)
                  }
                }
              end)
          }
          |> maybe_put_reasoning(response[:reasoning_content])

        state_after_assistant = %{state | messages: state.messages ++ [assistant_msg]}

        if AgentLoop.duplicate_tool_calls?(state.messages, tool_calls) do
          Logger.warning(
            "[Brain.Session] Detected duplicate tool call loop. Instructing model to finalize response."
          )

          system_feedback = %{
            "role" => "user",
            "content" =>
              "SYSTEM NOTICE: The tool call(s) #{inspect(Enum.map(tool_calls, & &1.name))} with the exact same arguments were already executed in the previous turn. Do NOT call the tool again. Synthesize your final answer using the results already provided."
          }

          state_with_feedback = %{
            state_after_assistant
            | messages: state_after_assistant.messages ++ [system_feedback]
          }

          run_agent_loop(state_with_feedback, depth - 1)
        else
          {tool_messages, updated_hands_state} =
            execute_tool_calls(tool_calls, state_after_assistant)

          state_after_tools = %{
            updated_hands_state
            | messages: updated_hands_state.messages ++ tool_messages,
              step_count: updated_hands_state.step_count + 1
          }

          run_agent_loop(state_after_tools, depth - 1)
        end

      {:ok, response} ->
        state = accumulate_usage(state, response[:usage])

        if response[:reasoning_content] do
          Logger.info("[DeepSeek-R1 Reasoning]\n#{response.reasoning_content}")
        end

        final_msg = %{"role" => "assistant", "content" => response.content}
        final_state = %{state | messages: state.messages ++ [final_msg], status: :idle}
        SessionStore.save_session(final_state, state.cwd)
        {{:ok, response}, final_state}

      {:error, reason} ->
        {{:error, "Error communicating with DeepSeek API: #{reason}"}, %{state | status: :idle}}
    end
  end

  defp accumulate_usage(state, nil), do: state

  defp accumulate_usage(state, usage) when is_map(usage) do
    p = Map.get(usage, :prompt_tokens, 0)
    c = Map.get(usage, :completion_tokens, 0)

    %{
      state
      | total_prompt_tokens: state.total_prompt_tokens + p,
        total_completion_tokens: state.total_completion_tokens + c
    }
  end

  defp maybe_put_reasoning(msg, reasoning) when is_binary(reasoning) and reasoning != "" do
    Map.put(msg, "reasoning_content", reasoning)
  end

  defp maybe_put_reasoning(msg, _), do: msg

  defp execute_tool_calls(tool_calls, state) do
    Enum.reduce(tool_calls, {[], state}, fn tc, {msg_acc, current_state} ->
      case tool_permitted?(tc.name, tc.arguments, current_state) do
        {:allow, updated_state} ->
          exec_res = HandsExecutor.execute(updated_state.hands, tc.name, tc.arguments)

          tool_msg =
            case exec_res do
              {:ok, result} ->
                %{"role" => "tool", "tool_call_id" => tc.id, "content" => result}

              {:error, err} ->
                %{
                  "role" => "tool",
                  "tool_call_id" => tc.id,
                  "content" => "Tool execution failed: #{err}"
                }
            end

          updated_state_after = AgentLoop.handle_tool_failure(tc.name, exec_res, updated_state)
          {msg_acc ++ [tool_msg], updated_state_after}

        {:deny, reason, updated_state} ->
          tool_msg = %{
            "role" => "tool",
            "tool_call_id" => tc.id,
            "content" => "Tool execution denied: #{reason}"
          }

          {msg_acc ++ [tool_msg], updated_state}
      end
    end)
  end

  # Permission Authorization Gate (Item 1, 4, 18)
  defp tool_permitted?(tool_name, args, state) do
    config = Config.load_config(state.cwd)
    tool_perms = Map.get(config, "tool_permissions", %{})
    config_policy = Map.get(tool_perms, tool_name)
    session_perms = Map.get(state, :session_tool_permissions, %{})
    session_policy = Map.get(session_perms, tool_name)

    policy = session_policy || config_policy

    cond do
      policy == "deny" ->
        {:deny, "Tool '#{tool_name}' execution denied by configuration policy.", state}

      policy == "allow" ->
        {:allow, state}

      destructive_bash_command?(tool_name, args) ->
        confirm_tool_with_user(
          tool_name,
          args,
          "Warning: Destructive shell command detected!",
          state
        )

      state.permission_mode == :ask_confirm or policy == "confirm" ->
        confirm_tool_with_user(tool_name, args, "Confirmation required for tool execution", state)

      true ->
        {:allow, state}
    end
  end

  defp destructive_bash_command?("bash", %{"command" => cmd}) when is_binary(cmd) do
    c = String.downcase(cmd)

    String.contains?(c, "rm -rf") or String.contains?(c, "git push --force") or
      String.contains?(c, "git reset --hard") or String.contains?(c, "drop database") or
      String.contains?(c, "mkfs")
  end

  defp destructive_bash_command?(_, _), do: false

  defp confirm_tool_with_user(tool_name, args, reason, state) do
    # Never ask for ask_question tool itself
    if tool_name == "ask_question" do
      {:allow, state}
    else
      formatted_args = inspect(args, pretty: true)
      q = "#{reason}: Allow tool '#{tool_name}'?\nArgs: #{formatted_args}"

      opts = [
        "Allow once",
        "Allow always for this session",
        "Allow always (save to project config)",
        "Deny tool execution"
      ]

      ans =
        DeepSeekHarness.CLI.Spinner.with_paused(fn ->
          DeepSeekHarness.CLI.QuestionPrompt.ask_single_question(q, opts, false)
        end)

      case ans do
        %{selected: [sel]} ->
          cond do
            String.contains?(sel, "save to project config") ->
              Config.set_tool_permission(tool_name, "allow", state.cwd)
              perms = Map.put(Map.get(state, :session_tool_permissions, %{}), tool_name, "allow")
              {:allow, %{state | session_tool_permissions: perms}}

            String.contains?(sel, "this session") ->
              perms = Map.put(Map.get(state, :session_tool_permissions, %{}), tool_name, "allow")
              {:allow, %{state | session_tool_permissions: perms}}

            String.contains?(String.downcase(sel), "allow") ->
              {:allow, state}

            true ->
              {:deny, "Tool execution denied by user.", state}
          end

        _ ->
          {:deny, "Tool execution denied by user.", state}
      end
    end
  end

  defp auto_checkpoint(state, label) do
    snapshot = %{
      id: "auto_#{System.unique_integer([:positive])}",
      label: label,
      timestamp: DateTime.utc_now(),
      messages: state.messages,
      model: state.model
    }

    snapshots = Enum.take([snapshot | state.snapshots], 20)
    new_state = %{state | snapshots: snapshots}
    SessionStore.save_session(new_state, state.cwd)
    new_state
  end
end
