defmodule DeepSeekHarness.CLI.ContextExpander do
  @moduledoc """
  Expands `@filename`, `@relative_path`, `@file://...`, and `@https://...` references in user prompts.
  Includes workspace sandbox bounds checks and URL fetch notifications.
  """
  require Logger

  # Matches @file://..., @http(s)://..., or @path/file
  @ref_regex ~r/@(file:\/\/\S+|https?:\/\/\S+|\/?[\w\.\-\/]+)/

  @image_ext_names ~w(.png .jpg .jpeg .gif .webp .bmp)

  # Images larger than this are refused (base64 inflates the payload ~33% and
  # the vision model has a fixed image budget).
  @max_image_bytes 10_000_000

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
            {:ok, {:image, mime, data_uri, bytes, analysis_text, filename}, label} ->
              clean_text =
                String.replace(acc_text, full_match, "[Image: #{label}]\n#{analysis_text}")

              img_attachment = %{
                type: "image",
                label: label,
                filename: filename,
                mime: mime,
                bytes: bytes,
                data_uri: data_uri,
                analysis_text: analysis_text
              }

              {clean_text, [img_attachment | acc_attachments]}

            {:ok, {:image, mime, data_uri}, label} ->
              clean_text = String.replace(acc_text, full_match, "[Image: #{label}]")

              img_attachment = %{
                type: "image",
                label: label,
                filename: Path.basename(label),
                mime: mime,
                bytes: nil,
                data_uri: data_uri
              }

              {clean_text, [img_attachment | acc_attachments]}

            {:ok, content, label} when is_binary(content) ->
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
          content = m["content"]

          is_binary(content) and
            ((m["role"] == "tool" and
                (String.contains?(content, "failed") or String.contains?(content, "error"))) or
               (m["role"] == "user" and String.contains?(content, "SYSTEM NOTICE")))
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
        {:ok, content} when is_binary(content) ->
          if image?(path) do
            if byte_size(content) > @max_image_bytes do
              {:error,
               "Image '#{label}' is #{byte_size(content)} bytes, exceeding the " <>
                 "#{@max_image_bytes} byte limit for vision attachment."}
            else
              mime = image_mime(path)
              data_uri = "data:#{mime};base64," <> Base.encode64(content)
              {analysis_text, filename} = analyze_image(path, content, label)
              {:ok, {:image, mime, data_uri, content, analysis_text, filename}, label}
            end
          else
            # Truncate extremely large text files if > 500KB to prevent OOM
            truncated =
              if byte_size(content) > 500_000 do
                binary_part(content, 0, 500_000) <> "\n... [Content truncated at 500KB]"
              else
                content
              end

            {:ok, truncated, label}
          end

        {:error, reason} ->
          {:error, "File read error: #{inspect(reason)}"}
      end
    else
      {:error, "File does not exist or is a directory: #{path}"}
    end
  end

  defp image?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @image_ext_names
  end

  defp image_mime(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".bmp" -> "image/bmp"
      _ -> "image/png"
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

  @doc "Analyzes an image file via Ragex.Image (if available) and returns an analysis summary text block and basename."
  def analyze_image(path, content, label) do
    filename = Path.basename(path)

    analysis_map =
      if Code.ensure_loaded?(Ragex.Image) and apply(Ragex.Image, :available?, []) do
        case apply(Ragex.Image, :info, [path]) do
          {:ok, info} -> info
          _ -> %{}
        end
      else
        %{}
      end

    width = Map.get(analysis_map, :width)
    height = Map.get(analysis_map, :height)

    format =
      Map.get(analysis_map, :format) ||
        path |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    aspect = Map.get(analysis_map, :aspect)
    colorspace = Map.get(analysis_map, :colorspace)
    file_size = Map.get(analysis_map, :file_size_bytes) || byte_size(content)
    dominant = Map.get(analysis_map, :dominant_color)
    exif = Map.get(analysis_map, :exif)

    size_str = format_bytes(file_size)
    dim_str = if width && height, do: "#{width}x#{height}", else: "unknown dimensions"

    aspect_str =
      cond do
        is_number(aspect) -> ", aspect ratio: #{Float.round(aspect * 1.0, 2)}"
        is_atom(aspect) and not is_nil(aspect) -> ", aspect ratio: #{aspect}"
        is_binary(aspect) -> ", aspect ratio: #{aspect}"
        true -> ""
      end

    color_str = if colorspace, do: ", colorspace: #{colorspace}", else: ""
    dom_str = if dominant, do: ", dominant color: #{inspect(dominant)}", else: ""

    exif_str =
      if is_map(exif) and map_size(exif) > 0, do: ", EXIF tags: #{map_size(exif)}", else: ""

    summary =
      "=== Ragex Image Analysis (#{label}) ===\n" <>
        "Format: #{format} | Resolution: #{dim_str}#{aspect_str} | Size: #{size_str}#{color_str}#{dom_str}#{exif_str}\n" <>
        "========================================="

    {summary, filename}
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "unknown"
end
