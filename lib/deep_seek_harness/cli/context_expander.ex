defmodule DeepSeekHarness.CLI.ContextExpander do
  @moduledoc """
  Expands `@filename`, `@relative_path`, `@file://...`, and `@https://...` references in user prompts.
  Includes workspace sandbox bounds checks and URL fetch notifications.
  """
  require Logger

  # Matches @file://..., @http(s)://..., or @path/file
  @ref_regex ~r/@(file:\/\/\S+|https?:\/\/\S+|\/?[\w\.\-\/]+)/

  @ambiguous_error_patterns ~r/\b(error above|the error|build failure|stack trace|the failure|previous error|tool failure)\b/i

  @doc "Parses and expands all @ references and ambiguous context references (e.g. 'error above') in user prompts."
  def expand(text, cwd \\ ".", opts \\ []) do
    {text_after_refs, attachments} = expand_at_references(text, cwd, opts)

    # Check for ambiguous error references like "error above"
    if Regex.match?(@ambiguous_error_patterns, text_after_refs) or
         String.contains?(text_after_refs, "@error") do
      session_messages = Keyword.get(opts, :session_messages, [])
      issue_tracker = Keyword.get(opts, :issue_tracker, [])

      error_block = build_error_context_block(session_messages, issue_tracker)

      if error_block != "" do
        expanded_text =
          text_after_refs <>
            "\n\n=== Resolved Conversation Context (Error Above) ===\n" <>
            error_block <>
            "\n====================================================\n"

        {:ok, expanded_text, attachments ++ ["error_context"]}
      else
        {:ok, text_after_refs, attachments}
      end
    else
      {:ok, text_after_refs, attachments}
    end
  end

  defp expand_at_references(text, cwd, opts) do
    matches = Regex.scan(@ref_regex, text)

    if Enum.empty?(matches) do
      {text, []}
    else
      {expanded_text, attachments} =
        Enum.reduce(matches, {text, []}, fn [full_match, target], {acc_text, acc_attachments} ->
          case resolve_reference(target, cwd, opts) do
            {:ok, content, label} ->
              block =
                "\n\n=== Attached File/URI (#{label}) ===\n#{content}\n=======================\n"

              clean_text = String.replace(acc_text, full_match, "[Ref: #{label}]")
              {clean_text <> block, [label | acc_attachments]}

            {:error, reason} ->
              Logger.warning(
                "[ContextExpander] Failed to expand reference '#{target}': #{reason}"
              )

              {acc_text, acc_attachments}
          end
        end)

      {expanded_text, Enum.reverse(attachments)}
    end
  end

  def build_error_context_block(messages, issue_tracker) do
    tracked_summary =
      if is_list(issue_tracker) and issue_tracker != [] do
        Enum.map_join(issue_tracker, "\n", fn issue ->
          status_str =
            if issue[:status] == :resolved,
              do: "[RESOLVED in Turn #{issue[:resolved_at]}]",
              else: "[OPEN/PENDING]"

          "Issue ##{issue[:id]}: #{issue[:error]} -> #{status_str} (#{issue[:resolution] || "No resolution code yet"})"
        end)
      else
        ""
      end

    recent_error_msg =
      if is_list(messages) do
        messages
        |> Enum.reverse()
        |> Enum.find(fn m ->
          (m["role"] == "tool" and
             (String.contains?(m["content"], "failed") or String.contains?(m["content"], "error"))) or
            (m["role"] == "user" and String.contains?(m["content"], "SYSTEM NOTICE"))
        end)
      else
        nil
      end

    last_error_str =
      if recent_error_msg do
        "Recent Tool/System Error Log:\n" <> recent_error_msg["content"]
      else
        ""
      end

    cond do
      tracked_summary != "" and last_error_str != "" ->
        tracked_summary <> "\n\n" <> last_error_str

      tracked_summary != "" ->
        tracked_summary

      last_error_str != "" ->
        last_error_str

      true ->
        ""
    end
  end

  def resolve_reference("file://" <> path, cwd, opts) do
    resolve_path_reference(path, "file://" <> path, cwd, opts)
  end

  def resolve_reference("http://" <> _ = url, _cwd, _opts), do: fetch_url(url)
  def resolve_reference("https://" <> _ = url, _cwd, _opts), do: fetch_url(url)

  def resolve_reference(rel_or_abs_path, cwd, opts) do
    expanded_path =
      if String.starts_with?(rel_or_abs_path, "/") do
        rel_or_abs_path
      else
        Path.expand(rel_or_abs_path, cwd)
      end

    resolve_path_reference(expanded_path, rel_or_abs_path, cwd, opts)
  end

  defp resolve_path_reference(expanded_path, label, cwd, opts) do
    sandbox? = Keyword.get(opts, :sandbox_workspace, false)

    if sandbox? and not in_workspace?(expanded_path, cwd) do
      {:error, "File path '#{expanded_path}' is outside active workspace sandbox bounds."}
    else
      read_local_file(expanded_path, label)
    end
  end

  defp in_workspace?(path, cwd) do
    abs_path = Path.expand(path)
    abs_cwd = Path.expand(cwd)
    String.starts_with?(abs_path, abs_cwd)
  end

  defp read_local_file(path, label) do
    if File.exists?(path) and not File.dir?(path) do
      case File.read(path) do
        {:ok, content} ->
          # Truncate extremely large files if > 500KB to prevent OOM
          truncated =
            if byte_size(content) > 500_000 do
              binary_part(content, 0, 500_000) <> "\n... [Content truncated at 500KB]"
            else
              content
            end

          {:ok, truncated, label}

        {:error, reason} ->
          {:error, "File read error: #{inspect(reason)}"}
      end
    else
      {:error, "File does not exist or is a directory: #{path}"}
    end
  end

  defp fetch_url(url) do
    Logger.info("[ContextExpander] Resolving remote URL reference: #{url}")

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        truncated =
          if byte_size(body) > 300_000 do
            binary_part(body, 0, 300_000) <> "\n... [URL content truncated]"
          else
            body
          end

        {:ok, truncated, url}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} fetching URL #{url}"}

      {:error, reason} ->
        {:error, "Failed to fetch URL #{url}: #{inspect(reason)}"}
    end
  end
end
