defmodule DeepSeekHarness.Client.DeepSeekAPI do
  @moduledoc """
  Client interface for DeepSeek API (deepseek-chat V3 and deepseek-reasoner R1).
  Handles message serialization, tool declarations, reasoning extraction (R1),
  real token usage tracking, SSE response streaming, and mock execution mode.
  """
  require Logger

  @default_endpoint "https://api.deepseek.com/chat/completions"
  @default_model "deepseek-chat"

  defmodule ClientConfig do
    @moduledoc "Configuration parameters for DeepSeek API requests."
    defstruct model: "deepseek-chat",
              api_key: nil,
              endpoint: "https://api.deepseek.com/chat/completions",
              temperature: 0.7,
              stream: false,
              stream_fun: nil,
              mock: false
  end

  @doc """
  Sends a chat completion request to DeepSeek API or mock handler.
  """
  def chat_completion(messages, tools, opts \\ []) do
    config = build_config(opts)

    if is_nil(config.api_key) or config.api_key == "" or config.mock == true do
      mock_response(messages, tools, config.model)
    else
      real_chat_completion(messages, tools, config)
    end
  end

  @doc "Builds a structured ClientConfig struct from keyword options."
  def build_config(opts) when is_list(opts) do
    mock_default =
      cond do
        Keyword.has_key?(opts, :mock) ->
          opts[:mock]

        function_exported?(Mix, :env, 0) and Mix.env() == :test and
            System.get_env("ENABLE_REAL_API_TESTS") != "true" ->
          true

        true ->
          false
      end

    %ClientConfig{
      model: opts[:model] || System.get_env("DEEPSEEK_MODEL") || @default_model,
      api_key: opts[:api_key] || System.get_env("DEEPSEEK_API_KEY"),
      endpoint: opts[:endpoint] || @default_endpoint,
      temperature: opts[:temperature] || 0.7,
      stream: opts[:stream] || false,
      stream_fun: opts[:stream_fun],
      mock: mock_default
    }
  end

  defp real_chat_completion(messages, tools, %ClientConfig{} = config) do
    formatted_tools = format_tools(tools)

    body = %{
      "model" => config.model,
      "messages" => messages,
      "temperature" => config.temperature
    }

    body =
      if Enum.empty?(formatted_tools) do
        body
      else
        Map.put(body, "tools", formatted_tools)
      end

    headers = [
      {"Authorization", "Bearer #{config.api_key}"},
      {"Content-Type", "application/json"}
    ]

    req_opts = [
      json: body,
      headers: headers,
      receive_timeout: :infinity
    ]

    post_with_retry(config.endpoint, req_opts)
  end

  defp post_with_retry(endpoint, req_opts, attempts_left \\ 3, backoff_ms \\ 500) do
    case Req.post(endpoint, req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = resp_body}} ->
        usage = Map.get(resp_body, "usage", %{})
        parse_choice(choice, usage)

      {:ok, %Req.Response{status: status, body: _err_body}}
      when status in [429, 500, 502, 503, 504] and attempts_left > 1 ->
        Logger.warning(
          "[DeepSeekAPI] Transient HTTP #{status} error. Retrying in #{backoff_ms}ms... (#{attempts_left - 1} attempts left)"
        )

        Process.sleep(backoff_ms)
        post_with_retry(endpoint, req_opts, attempts_left - 1, backoff_ms * 2)

      {:ok, %Req.Response{status: status, body: err_body}} ->
        {:error, "DeepSeek API returned HTTP status #{status}: #{inspect(err_body)}"}

      {:error, reason} when attempts_left > 1 ->
        Logger.warning(
          "[DeepSeekAPI] Transport error #{inspect(reason)}. Retrying in #{backoff_ms}ms... (#{attempts_left - 1} attempts left)"
        )

        Process.sleep(backoff_ms)
        post_with_retry(endpoint, req_opts, attempts_left - 1, backoff_ms * 2)

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn t ->
      name = Map.get(t, :name) || Map.get(t, "name")
      desc = Map.get(t, :description) || Map.get(t, "description")
      params = Map.get(t, :parameters) || Map.get(t, "parameters")

      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => desc,
          "parameters" => params
        }
      }
    end)
  end

  defp parse_choice(%{"message" => msg}, usage) do
    content = Map.get(msg, "content")
    reasoning_content = Map.get(msg, "reasoning_content")
    tool_calls = Map.get(msg, "tool_calls") || []

    parsed_tool_calls =
      Enum.map(tool_calls, fn tc ->
        fn_data = Map.get(tc, "function", %{})
        args_raw = Map.get(fn_data, "arguments", "{}")

        args =
          case Jason.decode(args_raw) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        %{
          id: Map.get(tc, "id"),
          name: Map.get(fn_data, "name"),
          arguments: args
        }
      end)

    usage_map = %{
      prompt_tokens: Map.get(usage, "prompt_tokens", 0),
      completion_tokens: Map.get(usage, "completion_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0)
    }

    {:ok,
     %{
       role: "assistant",
       content: content,
       reasoning_content: reasoning_content,
       tool_calls: parsed_tool_calls,
       usage: usage_map
     }}
  end

  # Mock lookup patterns table (eliminates deep cond nesting)
  @mock_handlers [
    {~r/(list|ls|directory|examine|project)/i, "list_dir", %{"path" => "."},
     "I will list the files in the directory to inspect project layout.",
     "Thought: User requested directory listing. Calling list_dir tool."},
    {~r/(eval|calculate|elixir)/i, "elixir_eval", %{"code" => "1 + 1 + 42"},
     "Executing Elixir code snippet.", "Thought: Need to evaluate mathematical expression."}
  ]

  defp mock_response(messages, _tools, model) do
    last_user_msg =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m["role"] == "user" end) || %{"content" => ""}

    has_tool_result? = Enum.any?(messages, fn m -> m["role"] == "tool" end)

    if has_tool_result? do
      tool_results =
        messages
        |> Enum.filter(fn m -> m["role"] == "tool" end)
        |> Enum.map_join("\n", fn m -> message_content_text(m["content"]) end)

      prefix = if model == "deepseek-reasoner", do: "[DeepSeek-R1 Reasoning Mode] ", else: ""

      {:ok,
       %{
         role: "assistant",
         content:
           "#{prefix}Examined workspace directory:\n\n#{tool_results}\n\n(Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
         reasoning_content: "Processed tool results and formulated response.",
         tool_calls: [],
         usage: %{prompt_tokens: 60, completion_tokens: 30, total_tokens: 90}
       }}
    else
      content_str = message_content_text(last_user_msg["content"])

      case match_mock_handler(content_str) do
        {:ok, tool_name, args, text, reasoning} ->
          {:ok,
           %{
             role: "assistant",
             content: text,
             reasoning_content: reasoning,
             tool_calls: [
               %{
                 id: "call_mock_#{System.unique_integer([:positive])}",
                 name: tool_name,
                 arguments: args
               }
             ],
             usage: %{prompt_tokens: 40, completion_tokens: 25, total_tokens: 65}
           }}

        :no_match ->
          prefix = if model == "deepseek-reasoner", do: "[DeepSeek-R1 Reasoning Mode] ", else: ""
          vision_note = if vision_model?(model), do: "[Vision] ", else: ""

          {:ok,
           %{
             role: "assistant",
             content:
               "#{prefix}#{vision_note}Received prompt: \"#{content_str}\". (Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
             reasoning_content: "Analyzed request using spatiotemporal actor context.",
             tool_calls: [],
             usage: %{prompt_tokens: 30, completion_tokens: 20, total_tokens: 50}
           }}
      end
    end
  end

  defp message_content_text(content) when is_binary(content), do: content

  defp message_content_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{"image_url" => %{"url" => url}} when is_binary(url) -> "[Image attached: #{url}]"
      _ -> ""
    end)
  end

  defp message_content_text(_), do: ""

  defp vision_model?(model) when is_binary(model) do
    String.contains?(String.downcase(model), "vision") or
      String.contains?(String.downcase(model), "vl")
  end

  defp vision_model?(_), do: false

  defp match_mock_handler(input) do
    Enum.find_value(@mock_handlers, :no_match, fn {regex, name, args, text, reasoning} ->
      if Regex.match?(regex, input) do
        {:ok, name, args, text, reasoning}
      else
        false
      end
    end)
  end
end
