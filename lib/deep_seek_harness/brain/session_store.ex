defmodule DeepSeekHarness.Brain.SessionStore do
  @moduledoc """
  Handles disk persistence for session memory, history checkpoints, and snapshots.
  Enables session resumption across CLI restarts (~/.dsh/sessions/<session_id>.json).
  """
  require Logger

  @doc "Saves session state and snapshots to disk."
  def save_session(session_state, cwd \\ ".") do
    session_id = session_state.session_id
    dir = session_dir(cwd)
    file_path = Path.join(dir, "#{session_id}.json")

    payload = %{
      "session_id" => session_id,
      "model" => session_state.model,
      "permission_mode" => to_string(session_state.permission_mode),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "step_count" => session_state.step_count,
      "total_prompt_tokens" => session_state.total_prompt_tokens,
      "total_completion_tokens" => session_state.total_completion_tokens,
      "messages" => session_state.messages,
      "snapshots" => serialize_snapshots(session_state.snapshots)
    }

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(payload, pretty: true),
         :ok <- File.write(file_path, json) do
      {:ok, file_path}
    else
      err ->
        Logger.warning("[SessionStore] Failed to save session '#{session_id}': #{inspect(err)}")
        {:error, err}
    end
  end

  @doc "Appends a full untruncated step log to local transcript files (.dsh/sessions/<id>/transcript_full.jsonl and transcript_compact.jsonl)."
  def append_transcript(session_id, step_type, payload, cwd \\ ".") do
    dir = Path.join(session_dir(cwd), session_id)
    File.mkdir_p!(dir)

    entry = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => to_string(step_type),
      "payload" => payload
    }

    full_path = Path.join(dir, "transcript_full.jsonl")
    line = Jason.encode!(entry) <> "\n"
    File.write!(full_path, line, [:append])

    compact_path = Path.join(dir, "transcript_compact.jsonl")
    compact_line = Jason.encode!(%{entry | "payload" => compact_payload(payload)}) <> "\n"
    File.write!(compact_path, compact_line, [:append])
  rescue
    _ -> :ok
  end

  defp compact_payload(payload) when is_binary(payload) do
    if byte_size(payload) > 500 do
      String.slice(payload, 0, 500) <> "... [truncated]"
    else
      payload
    end
  end

  defp compact_payload(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {k, compact_payload(v)} end)
  end

  defp compact_payload(list) when is_list(list) do
    Enum.map(list, &compact_payload/1)
  end

  defp compact_payload(val), do: val

  @doc "Loads a persisted session from disk."
  def load_session(session_id, cwd \\ ".") do
    file_path = Path.join(session_dir(cwd), "#{session_id}.json")

    if File.exists?(file_path) do
      with {:ok, content} <- File.read(file_path),
           {:ok, data} when is_map(data) <- Jason.decode(content) do
        {:ok, data}
      else
        err -> {:error, "Failed to decode session file '#{file_path}': #{inspect(err)}"}
      end
    else
      {:error, "Session file '#{file_path}' does not exist."}
    end
  end

  @doc """
  Imports an externally-produced session JSON file into DSH's own on-disk
  session store, so it can be resumed like any native session via `/resume`
  or `/session switch`. Replaces ad-hoc external scripts previously used to
  massage foreign session exports into a loadable shape.

  Tolerantly accepts several JSON shapes at `source_path`:
    - the native `save_session/2` schema (`session_id`, `model`,
      `permission_mode`, `step_count`, `total_prompt_tokens`,
      `total_completion_tokens`, `messages`, `snapshots`)
    - the `/export json` schema (`session_id`, `model`, `exported_at`,
      `total_tokens`, `messages`)
    - a bare `%{"messages" => [...]}` object
    - a raw top-level JSON array of message objects

  `opts` supports:
    - `:session_id` -- target session ID (defaults to the source file's own
      `"session_id"` field, or a freshly generated UUID)
    - `:overwrite` -- when `true`, allows replacing an existing session file
      with the same ID (default: `false`)

  Returns `{:ok, session_id, file_path}` or `{:error, reason}`.
  """
  def import_session(source_path, opts \\ [], cwd \\ ".") do
    with {:ok, content} <- read_import_file(source_path),
         {:ok, data} <- decode_import_json(content, source_path),
         {:ok, messages} <- extract_import_messages(data) do
      meta = if is_map(data), do: data, else: %{}
      session_id = opts[:session_id] || meta["session_id"] || generate_session_id()
      file_path = Path.join(session_dir(cwd), "#{session_id}.json")

      if File.exists?(file_path) and !Keyword.get(opts, :overwrite, false) do
        {:error,
         "Session '#{session_id}' already exists at #{file_path}. Pass a different session_id, or overwrite: true."}
      else
        session_state = %{
          session_id: session_id,
          model: meta["model"] || "deepseek-chat",
          permission_mode: normalize_permission_mode(meta["permission_mode"]),
          step_count: meta["step_count"] || 0,
          total_prompt_tokens: meta["total_prompt_tokens"] || 0,
          total_completion_tokens: meta["total_completion_tokens"] || 0,
          messages: messages,
          snapshots: meta["snapshots"] || []
        }

        case save_session(session_state, cwd) do
          {:ok, path} -> {:ok, session_id, path}
          {:error, reason} -> {:error, "Failed to write imported session: #{inspect(reason)}"}
        end
      end
    end
  end

  defp read_import_file(source_path) do
    case File.read(source_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read '#{source_path}': #{inspect(reason)}"}
    end
  end

  defp decode_import_json(content, source_path) do
    case Jason.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, err} -> {:error, "Invalid JSON in '#{source_path}': #{Exception.message(err)}"}
    end
  end

  defp extract_import_messages(data) when is_list(data), do: {:ok, data}
  defp extract_import_messages(%{"messages" => msgs}) when is_list(msgs), do: {:ok, msgs}

  defp extract_import_messages(_) do
    {:error,
     "Source JSON must be either a top-level array of messages, or an object with a 'messages' array."}
  end

  defp normalize_permission_mode(mode) when mode in ["auto_approve", "ask_confirm"], do: mode
  defp normalize_permission_mode(_), do: "ask_confirm"

  defp generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  @doc "Lists all saved session IDs."
  def list_sessions(cwd \\ ".") do
    dir = session_dir(cwd)

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(&String.replace(&1, ".json", ""))

        _ ->
          []
      end
    else
      []
    end
  end

  @doc """
  Deletes a persisted session state file from disk.

  Returns `{:ok, path}` on success, or `{:error, reason}` when the session
  file does not exist or could not be removed.
  """
  def delete_session(session_id, cwd \\ ".") do
    file_path = Path.join(session_dir(cwd), "#{session_id}.json")

    case File.rm(file_path) do
      :ok -> {:ok, file_path}
      {:error, :enoent} -> {:error, "Session '#{session_id}' has no persisted state to delete."}
      {:error, reason} -> {:error, "Failed to delete session file: #{inspect(reason)}"}
    end
  end

  @doc """
  Returns metadata about all persisted sessions in the workspace.

  Each entry is a map with `session_id`, `model`, `updated_at`, `message_count`,
  and `step_count`. Entries are sorted most-recently-updated first. Useful for
  building `/session list` output and for auto-resume prompts.
  """
  def list_session_metadata(cwd \\ ".") do
    dir = session_dir(cwd)

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.map(&read_session_metadata/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1[:updated_at], {:desc, NaiveDateTime})

        _ ->
          []
      end
    else
      []
    end
  end

  @doc """
  Loads only the persisted session metadata (without the full message
  history) for a given session id, or `nil` when no such session exists.
  """
  def load_session_metadata(session_id, cwd \\ ".") do
    file_path = Path.join(session_dir(cwd), "#{session_id}.json")
    read_session_metadata(file_path)
  end

  defp read_session_metadata(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            messages = Map.get(map, "messages", [])

            %{
              session_id: map["session_id"],
              model: map["model"],
              updated_at: parse_timestamp(map["updated_at"]),
              message_count: length(messages),
              step_count: Map.get(map, "step_count", 0),
              title: extract_first_user_message(messages)
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc "Extracts and truncates the first user message content from session history."
  def extract_first_user_message(messages) when is_list(messages) do
    user_msg =
      Enum.find(messages, fn
        %{"role" => "user"} = msg -> get_message_text(msg["content"]) != ""
        %{role: "user"} = msg -> get_message_text(msg[:content] || msg["content"]) != ""
        _ -> false
      end)

    case user_msg do
      %{"content" => content} -> sanitize_title(get_message_text(content))
      %{content: content} -> sanitize_title(get_message_text(content))
      _ -> nil
    end
  end

  def extract_first_user_message(_), do: nil

  defp get_message_text(content) when is_binary(content), do: content

  defp get_message_text(content) when is_list(content) do
    Enum.map_join(content, " ", fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp get_message_text(_), do: ""

  # `get_message_text/1` (the only caller) always returns a binary, so this
  # single clause covers every real input; dialyzer confirms a catch-all
  # fallback clause here would be unreachable dead code.
  defp sanitize_title(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if cleaned == "" do
      nil
    else
      truncate_text(cleaned, 60)
    end
  end

  defp truncate_text(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  defp parse_timestamp(nil), do: NaiveDateTime.utc_now()

  defp parse_timestamp(iso) when is_binary(iso) do
    case NaiveDateTime.from_iso8601(iso) do
      {:ok, dt} -> dt
      _ -> NaiveDateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: NaiveDateTime.utc_now()

  def session_dir(cwd \\ ".") do
    Path.join(cwd, ".dsh/sessions")
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
end
