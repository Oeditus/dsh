defmodule DeepSeekHarness.Client.DeepSeekAPI do
  @moduledoc """
  Client interface for DeepSeek API (deepseek-chat and deepseek-reasoner).
  Handles message serialization, tool declarations, reasoning extraction (R1),
  and mock execution mode when API key is missing or offline.
  """

  @default_endpoint "https://api.deepseek.com/chat/completions"
  @default_model "deepseek-chat"

  @doc """
  Sends a chat completion request to DeepSeek API or mock handler.
  """
  def chat_completion(messages, tools, opts \\ []) do
    api_key = opts[:api_key] || System.get_env("DEEPSEEK_API_KEY")
    model = opts[:model] || System.get_env("DEEPSEEK_MODEL") || @default_model
    endpoint = opts[:endpoint] || @default_endpoint

    if is_nil(api_key) or api_key == "" or opts[:mock] == true do
      mock_response(messages, tools, model)
    else
      real_chat_completion(messages, tools, model, api_key, endpoint, opts)
    end
  end

  defp real_chat_completion(messages, tools, model, api_key, endpoint, opts) do
    formatted_tools = format_tools(tools)

    body = %{
      "model" => model,
      "messages" => messages,
      "temperature" => opts[:temperature] || 0.7
    }

    body =
      if Enum.empty?(formatted_tools) do
        body
      else
        Map.put(body, "tools", formatted_tools)
      end

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(endpoint, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]}}} ->
        parse_choice(choice)

      {:ok, %Req.Response{status: status, body: err_body}} ->
        {:error, "DeepSeek API returned HTTP status #{status}: #{inspect(err_body)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn t ->
      %{
        "type" => "function",
        "function" => %{
          "name" => t.name,
          "description" => t.description,
          "parameters" => t.parameters
        }
      }
    end)
  end

  defp parse_choice(%{"message" => msg}) do
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

    {:ok,
     %{
       role: "assistant",
       content: content,
       reasoning_content: reasoning_content,
       tool_calls: parsed_tool_calls
     }}
  end

  # Mock handler for local demonstration and test environments without API key
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
        |> Enum.map_join("\n", fn m -> m["content"] || "" end)

      prefix = if model == "deepseek-reasoner", do: "[DeepSeek-R1 Reasoning Mode] ", else: ""

      {:ok,
       %{
         role: "assistant",
         content:
           "#{prefix}Examined workspace directory:\n\n#{tool_results}\n\n(Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
         reasoning_content: "Processed tool results and formulated response.",
         tool_calls: []
       }}
    else
      query = String.downcase(last_user_msg["content"] || "")

      cond do
        String.contains?(query, "list") or String.contains?(query, "ls") or
          String.contains?(query, "directory") or String.contains?(query, "examine") or
            String.contains?(query, "project") ->
          {:ok,
           %{
             role: "assistant",
             content: "I will list the files in the directory to inspect the project layout.",
             reasoning_content:
               "Thought: The user requested directory contents. Utilizing list_dir tool.",
             tool_calls: [
               %{
                 id: "call_mock_#{System.unique_integer([:positive])}",
                 name: "list_dir",
                 arguments: %{"path" => "."}
               }
             ]
           }}

        String.contains?(query, "eval") or String.contains?(query, "calculate") or
            String.contains?(query, "elixir") ->
          {:ok,
           %{
             role: "assistant",
             content: "Executing Elixir code snippet.",
             reasoning_content: "Thought: Need to evaluate expression.",
             tool_calls: [
               %{
                 id: "call_mock_#{System.unique_integer([:positive])}",
                 name: "elixir_eval",
                 arguments: %{"code" => "1 + 1 + 42"}
               }
             ]
           }}

        true ->
          prefix = if model == "deepseek-reasoner", do: "[DeepSeek-R1 Reasoning Mode] ", else: ""

          {:ok,
           %{
             role: "assistant",
             content:
               "#{prefix}Received prompt: \"#{last_user_msg["content"]}\". (Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
             reasoning_content: "Analyzed request using spatiotemporal actor context.",
             tool_calls: []
           }}
      end
    end
  end
end
