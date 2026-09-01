defmodule DeepSeekHarness.Brain.SessionLmml do
  @moduledoc """
  Serializes DSH session state to and from the `lmml` markup format
  (a Markdown-superset language for structuring LLM conversations -- see
  `Lmml`), making `lmml` the default on-disk markup for stored
  conversations.

  A session is encoded as a *narrative* (the human-readable, ordered view
  of the conversation) plus two kinds of named *embeds*:

    - `@@@manifest.json ... @@@` -- the session's metadata and temporal
      snapshots, `Lmml.Manifest`-compatible.
    - `@@@message.N.json ... @@@` -- one inline embed per message, carrying
      the exact JSON of that message so a save/load round-trip is lossless
      even for structured messages (tool calls, tool results, multimodal
      `content` arrays, reasoning text).

  The narrative prose is deliberately a *view*, not the source of truth:
  reading the file as a human gives you the whole conversation at a glance,
  while `decode/1` reconstructs the authoritative `messages` list from the
  embeds. This mirrors `lmml`'s own model of "an ordered narrative with
  zero or more named embeds."

  ## Why `.lmml` and not `.json`

  A `.lmml` narrative is plain, self-contained, git-diff-friendly Markdown
  that any Markdown viewer renders sensibly, yet every structured detail
  (metadata, snapshots, tool calls, images) round-trips losslessly through
  its embed model -- see `Lmml.Bundle`, `Lmml.Manifest` and
  `Lmml.Narrative.Renderer`.
  """

  alias Lmml.Bundle
  alias Lmml.Manifest

  @manifest_name "manifest.json"
  @message_prefix "message."
  @message_suffix ".json"

  @doc "The reserved embed name a session's metadata is stored under (manifest-compatible)."
  @spec manifest_name() :: String.t()
  def manifest_name, do: @manifest_name

  @typedoc "A message as stored in a session's `messages` list (string-keyed map)."
  @type message :: map()

  # ---------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------

  @doc """
  Encodes `session_state` (a map with atom keys, as held by
  `DeepSeekHarness.Brain.Session`) into the `.lmml` narrative text for a
  session identified by `session_id`.

  Returns `{:ok, narrative}` or `{:error, reason}`. The narrative embeds
  a `manifest.json` (metadata + snapshots) and one `message.N.json` embed
  per message.
  """
  @spec encode(map(), String.t()) :: {:ok, binary()} | {:error, term()}
  def encode(session_state, session_id) do
    manifest = build_manifest(session_state, session_id)
    messages = Map.get(session_state, :messages, [])

    header = """
    # DSH Conversation: #{session_id}

    This conversation is stored as an `lmml` narrative (a Markdown-superset
    markup). The authoritative message list and session metadata are carried
    as inline embeds below; the role headings are a human-readable view.

    @@@#{@manifest_name}
    #{Jason.encode!(manifest, pretty: true)}
    @@@
    """

    body =
      messages
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {msg, idx} ->
        role = String.upcase(Map.get(msg, "role") || "unknown")
        text = readable_text(msg)

        """
        ## #{role}

        #{text}

        @@@#{@message_prefix}#{idx}#{@message_suffix}
        #{Jason.encode!(msg)}
        @@@
        """
      end)

    narrative = header <> "\n\n" <> body <> "\n"

    case Bundle.new_text("#{session_id}.lmml", narrative) do
      {:ok, _bundle} -> {:ok, narrative}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Decodes a `.lmml` narrative (or a parsed `Lmml.Bundle`) back into the
  string-keyed map shape `DeepSeekHarness.Brain.SessionStore.load_session/2`
  returns: `%{"session_id", "model", "permission_mode", "step_count",
  "total_prompt_tokens", "total_completion_tokens", "updated_at",
  "messages", "snapshots"}`.

  Accepts either a `Lmml.Bundle.t()` or a raw narrative binary.
  """
  @spec decode(Bundle.t() | binary()) :: {:ok, map()} | {:error, term()}
  def decode(%Bundle{} = bundle) do
    with {:ok, messages} <- decode_messages(bundle),
         {:ok, manifest} <- decode_manifest(bundle) do
      {:ok, Map.merge(manifest, %{"messages" => messages})}
    end
  end

  def decode(narrative) when is_binary(narrative) do
    with {:ok, bundle} <- Bundle.new_text("session.lmml", narrative) do
      decode(bundle)
    end
  end

  def decode(_), do: {:error, "Cannot decode: expected a narrative binary or Lmml.Bundle."}

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp build_manifest(session_state, session_id) do
    %{
      "session_id" => session_id,
      "model" => Map.get(session_state, :model, "deepseek-chat"),
      "permission_mode" => to_string(Map.get(session_state, :permission_mode, :ask_confirm)),
      "step_count" => Map.get(session_state, :step_count, 0),
      "total_prompt_tokens" => Map.get(session_state, :total_prompt_tokens, 0),
      "total_completion_tokens" => Map.get(session_state, :total_completion_tokens, 0),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "snapshots" => serialize_snapshots(Map.get(session_state, :snapshots, []))
    }
  end

  defp serialize_snapshots(snapshots) when is_list(snapshots) do
    Enum.map(snapshots, fn s ->
      %{
        "id" => s[:id] || s["id"],
        "label" => s[:label] || s["label"],
        "timestamp" => s[:timestamp] || s["timestamp"],
        "model" => s[:model] || s["model"],
        "messages" => s[:messages] || s["messages"]
      }
    end)
  end

  defp serialize_snapshots(_), do: []

  defp decode_manifest(%Bundle{} = bundle) do
    case Manifest.load(bundle) do
      {:ok, nil} ->
        {:ok, default_manifest()}

      {:ok, %Manifest{data: data}} ->
        {:ok, normalize_manifest(data)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_manifest do
    %{
      "session_id" => nil,
      "model" => "deepseek-chat",
      "permission_mode" => "ask_confirm",
      "step_count" => 0,
      "total_prompt_tokens" => 0,
      "total_completion_tokens" => 0,
      "updated_at" => nil,
      "snapshots" => []
    }
  end

  defp normalize_manifest(data) do
    %{
      "session_id" => Map.get(data, "session_id"),
      "model" => Map.get(data, "model", "deepseek-chat"),
      "permission_mode" => Map.get(data, "permission_mode", "ask_confirm"),
      "step_count" => Map.get(data, "step_count", 0),
      "total_prompt_tokens" => Map.get(data, "total_prompt_tokens", 0),
      "total_completion_tokens" => Map.get(data, "total_completion_tokens", 0),
      "updated_at" => Map.get(data, "updated_at"),
      "snapshots" => Map.get(data, "snapshots", [])
    }
  end

  defp decode_messages(%Bundle{} = bundle) do
    bundle
    |> Bundle.embeds()
    |> Enum.filter(&embed_message?/1)
    |> Enum.sort_by(&embed_index/1)
    |> Enum.reduce_while({:ok, []}, fn embed, {:ok, acc} ->
      case Bundle.embed(bundle, embed.name) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, msg} when is_map(msg) -> {:cont, {:ok, acc ++ [msg]}}
            _ -> {:halt, {:error, {:invalid_message_embed, embed.name}}}
          end

        {:error, reason} ->
          {:halt, {:error, {embed.name, reason}}}
      end
    end)
  end

  defp embed_message?(%Lmml.Embed{name: name}) do
    String.starts_with?(name, @message_prefix) and String.ends_with?(name, @message_suffix)
  end

  defp embed_index(%Lmml.Embed{name: name}) do
    inner = String.replace_prefix(name, @message_prefix, "")
    inner = String.replace_suffix(inner, @message_suffix, "")

    case Integer.parse(inner) do
      {n, _} -> n
      :error -> -1
    end
  end

  # Human-readable prose for a message's `content`, mirroring
  # `DeepSeekHarness.Brain.Session.message_content_text/1`: handles the
  # plain-string form and the multimodal array form (image_url / text
  # parts) used by vision models. Tool-call messages are checked first so
  # their `content` (often an empty string) doesn't shadow the call list.
  defp readable_text(%{"tool_calls" => calls}) when is_list(calls) do
    names =
      Enum.map_join(calls, ", ", fn call ->
        call |> Map.get("function", %{}) |> Map.get("name", "?")
      end)

    "*(tool calls: #{names})*"
  end

  defp readable_text(%{"content" => content}) when is_binary(content), do: content

  defp readable_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{"image_url" => %{"url" => url}} when is_binary(url) -> "[Image: #{url}]"
      _ -> ""
    end)
  end

  defp readable_text(_), do: ""
end
