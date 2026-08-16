defmodule DeepSeekHarness.Brain.Session do
  @moduledoc """
  The "Brain" actor of DeepSeek Harness.
  Manages agentic session state, temporal context checkpoints, conversation memory,
  subagent spawning, project rules, context expansion, and execution loops.
  """
  use GenServer
  require Logger

  alias DeepSeekHarness.Brain.ContextCompressor
  alias DeepSeekHarness.CLI.ContextExpander
  alias DeepSeekHarness.Client.DeepSeekAPI
  alias DeepSeekHarness.Config
  alias DeepSeekHarness.Hands.Executor, as: HandsExecutor
  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader

  @default_system_prompt """
  You are an expert agentic AI coding assistant powered by DeepSeek.
  You have access to tools for file operations, bash execution, skills, MCP servers, and Elixir evaluation.
  Break down tasks systematically, reason carefully, and invoke tools when needed.
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
    GenServer.call(pid, {:send_user_message, text}, 180_000)
  end

  @doc "Sets the DeepSeek model ('deepseek-chat' or 'deepseek-reasoner')."
  def set_model(pid, model) do
    GenServer.call(pid, {:set_model, model})
  end

  @doc "Sets permission mode (:auto_approve | :ask_confirm)."
  def set_permission_mode(pid, mode) do
    GenServer.call(pid, {:set_permission_mode, mode})
  end

  @doc "Configures the Hands execution mode (:local, :remote, :docker)."
  def set_hands_mode(pid, mode, target \\ nil) do
    GenServer.call(pid, {:set_hands_mode, mode, target})
  end

  @doc "Compresses context history (/compact)."
  def compact_context(pid) do
    GenServer.call(pid, :compact_context, 60_000)
  end

  @doc "Creates a temporal state snapshot (checkpoint)."
  def checkpoint(pid, label \\ nil) do
    GenServer.call(pid, {:checkpoint, label})
  end

  @doc "Rolls back session state to previous checkpoint."
  def undo(pid) do
    GenServer.call(pid, :undo)
  end

  @doc "Spawns a subagent session actor for parallel sub-task execution."
  def spawn_subagent(pid, prompt) do
    GenServer.call(pid, {:spawn_subagent, prompt}, 180_000)
  end

  @doc "Generates a comprehensive Code Review comparing two git branches."
  def generate_code_review(pid, base_branch, head_branch \\ "HEAD") do
    GenServer.call(pid, {:generate_code_review, base_branch, head_branch}, 240_000)
  end

  @doc "Returns token stats and session cost estimate."
  def get_token_stats(pid) do
    GenServer.call(pid, :get_token_stats)
  end

  @doc "Returns current session summary and statistics."
  def get_info(pid) do
    GenServer.call(pid, :get_info)
  end

  @doc "Returns content of the latest assistant message response in session."
  def get_latest_response(pid) do
    GenServer.call(pid, :get_latest_response)
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
      status: :idle
    }

    Logger.info(
      "[Brain.Session] Session actor initialized: #{session_id} (model: #{state.model})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:send_user_message, raw_text}, _from, state) do
    # Expand @filename, @relative_path, @file://..., @https://... references
    {:ok, expanded_text, _attachments} = ContextExpander.expand(raw_text)

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

        {:reply, {:ok, "Rolled back to checkpoint: '#{latest.label}'"}, new_state}

      [] ->
        {:reply, {:error, "No checkpoints available to undo."}, state}
    end
  end

  @impl true
  def handle_call({:spawn_subagent, prompt}, _from, state) do
    sub_id = "sub_#{System.unique_integer([:positive])}"
    Logger.info("[Brain.Session] Spawning background subagent session '#{sub_id}'")

    case DeepSeekHarness.Brain.SessionSupervisor.start_session(
           session_id: sub_id,
           model: state.model
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

  @impl true
  def handle_call({:generate_code_review, base_branch, head_branch}, _from, state) do
    case DeepSeekHarness.Git.diff_branches(base_branch, head_branch) do
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
    # Estimate total token count from message string lengths (~4 chars per token)
    est_prompt_tokens =
      state.messages
      |> Enum.map(fn m -> String.length(m["content"] || "") end)
      |> Enum.sum()
      |> div(4)

    stats = %{
      estimated_prompt_tokens: est_prompt_tokens,
      tracked_prompt_tokens: state.total_prompt_tokens,
      tracked_completion_tokens: state.total_completion_tokens,
      total_tokens: est_prompt_tokens + state.total_completion_tokens,
      estimated_cost_usd: (est_prompt_tokens + state.total_completion_tokens) * 0.0000005
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

        if duplicate_tool_calls?(state.messages, tool_calls) do
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
        if response[:reasoning_content] do
          Logger.info("[DeepSeek-R1 Reasoning]\n#{response.reasoning_content}")
        end

        final_msg = %{"role" => "assistant", "content" => response.content}
        final_state = %{state | messages: state.messages ++ [final_msg], status: :idle}
        {{:ok, response}, final_state}

      {:error, reason} ->
        {{:error, "Error communicating with DeepSeek API: #{reason}"}, %{state | status: :idle}}
    end
  end

  defp maybe_put_reasoning(msg, reasoning) when is_binary(reasoning) and reasoning != "" do
    Map.put(msg, "reasoning_content", reasoning)
  end

  defp maybe_put_reasoning(msg, _), do: msg

  defp duplicate_tool_calls?(messages, new_tool_calls) do
    case Enum.reverse(messages) do
      [%{"tool_calls" => prev_calls} | _] when is_list(prev_calls) ->
        prev_names_and_args =
          Enum.map(prev_calls, fn tc ->
            fn_data = Map.get(tc, "function", %{})
            {Map.get(fn_data, "name"), Map.get(fn_data, "arguments")}
          end)

        new_names_and_args =
          Enum.map(new_tool_calls, fn tc ->
            {tc.name, Jason.encode!(tc.arguments)}
          end)

        prev_names_and_args == new_names_and_args and prev_names_and_args != []

      _ ->
        false
    end
  end

  @standard_tools ~w(read_file write_file replace_file list_dir bash elixir_eval)

  defp execute_tool_calls(tool_calls, state) do
    Enum.reduce(tool_calls, {[], state}, fn tc, {msg_acc, current_state} ->
      exec_res = HandsExecutor.execute(current_state.hands, tc.name, tc.arguments)

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

      updated_state =
        if non_standard_tool?(tc.name) and blank_result?(exec_res) do
          current_counts = Map.get(current_state, :tool_failure_counts, %{})
          new_fail_count = Map.get(current_counts, tc.name, 0) + 1
          updated_counts = Map.put(current_counts, tc.name, new_fail_count)

          if new_fail_count >= 3 do
            Logger.warning(
              "[Brain.Session] Non-standard tool '#{tc.name}' failed #{new_fail_count} times without results. Disabling tool and falling back to standard bash+grep."
            )

            # Disable failing non-standard tool from active tool definitions
            remaining_tools =
              Enum.reject(current_state.tools, fn t ->
                Map.get(t, :name) == tc.name or Map.get(t, "name") == tc.name
              end)

            fallback_notice = %{
              "role" => "user",
              "content" =>
                "SYSTEM NOTICE: Non-standard tool '#{tc.name}' failed to provide results after #{new_fail_count} attempts. Fallback mode activated: tool '#{tc.name}' has been disabled. Please use standard tools: bash (with grep, find, cat), read_file, or list_dir instead."
            }

            %{
              current_state
              | tool_failure_counts: updated_counts,
                tools: remaining_tools,
                messages: current_state.messages ++ [fallback_notice]
            }
          else
            %{current_state | tool_failure_counts: updated_counts}
          end
        else
          current_state
        end

      {msg_acc ++ [tool_msg], updated_state}
    end)
  end

  defp non_standard_tool?(name) when is_binary(name) do
    name not in @standard_tools
  end

  defp non_standard_tool?(_), do: false

  defp blank_result?({:error, _}), do: true

  defp blank_result?({:ok, res}) when is_binary(res) do
    trimmed = String.trim(res)

    trimmed == "" or String.starts_with?(trimmed, "Tool execution failed") or
      String.starts_with?(trimmed, "Ragex tool error") or
      String.contains?(trimmed, "dllb_disabled") or
      String.contains?(trimmed, "manager_not_started")
  end

  defp blank_result?({:ok, nil}), do: true
  defp blank_result?({:ok, []}), do: true
  defp blank_result?({:ok, %{}}), do: true
  defp blank_result?(_), do: false

  defp auto_checkpoint(state, label) do
    snapshot = %{
      id: "auto_#{System.unique_integer([:positive])}",
      label: label,
      timestamp: DateTime.utc_now(),
      messages: state.messages,
      model: state.model
    }

    snapshots = Enum.take([snapshot | state.snapshots], 20)
    %{state | snapshots: snapshots}
  end
end
