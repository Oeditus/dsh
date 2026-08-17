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
            %{
              session_id: map["session_id"],
              model: map["model"],
              updated_at: parse_timestamp(map["updated_at"]),
              message_count: length(Map.get(map, "messages", [])),
              step_count: Map.get(map, "step_count", 0)
            }

          _ ->
            nil
        end

      _ ->
        nil
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
