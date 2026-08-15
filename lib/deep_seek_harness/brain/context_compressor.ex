defmodule DeepSeekHarness.Brain.ContextCompressor do
  @moduledoc """
  Handles context compression (/compact) for agent sessions to free up context window space.
  Sends conversation history to DeepSeek to generate a condensed summary preserving key facts.
  """

  alias DeepSeekHarness.Client.DeepSeekAPI

  @doc "Compresses session message history into a summary block."
  def compress_messages(messages, opts \\ []) do
    non_system = Enum.filter(messages, fn m -> m["role"] != "system" end)

    if Enum.empty?(non_system) do
      {:ok, messages, "No history to compress."}
    else
      summary_prompt = [
        %{
          "role" => "system",
          "content" => "You are an expert technical summarizer. Compress the provided conversation history into a structured summary preserving: 1. Core user goal & requirements. 2. Code files modified/inspected. 3. Decisions made. 4. Current state and next steps. Keep it highly concise."
        },
        %{
          "role" => "user",
          "content" => "Conversation History to Compress:\n" <> format_history(non_system)
        }
      ]

      case DeepSeekAPI.chat_completion(summary_prompt, [], opts) do
        {:ok, %{content: summary}} when is_binary(summary) ->
          system_msgs = Enum.filter(messages, fn m -> m["role"] == "system" end)

          compressed_block = %{
            "role" => "system",
            "content" => "=== Compressed Conversation Context ===\n#{summary}\n======================================"
          }

          new_messages = system_msgs ++ [compressed_block]
          {:ok, new_messages, summary}

        {:error, reason} ->
          {:error, "Compression failed: #{reason}"}
      end
    end
  end

  defp format_history(messages) do
    Enum.map(messages, fn m ->
      role = String.upcase(m["role"] || "UNKNOWN")
      content = m["content"] || ""
      "[#{role}]: #{content}"
    end)
    |> Enum.join("\n\n")
  end
end
