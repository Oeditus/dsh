defmodule DeepSeekHarness.CLI.ContextExpander do
  @moduledoc """
  Expands `@filename`, `@relative_path`, `@file://...`, and `@https://...` references in user prompts.
  Allows seamless context embedding into agent prompts.
  """
  require Logger

  # Matches @file://..., @http(s)://..., or @path/file
  @ref_regex ~r/@(file:\/\/\S+|https?:\/\/\S+|\/?[\w\.\-\/]+)/

  @doc "Parses and expands all @ references in the prompt text."
  def expand(text, cwd \\ ".") do
    matches = Regex.scan(@ref_regex, text)

    if Enum.empty?(matches) do
      {:ok, text, []}
    else
      {expanded_text, attachments} =
        Enum.reduce(matches, {text, []}, fn [full_match, target], {acc_text, acc_attachments} ->
          case resolve_reference(target, cwd) do
            {:ok, content, label} ->
              block = "\n\n=== Attached File/URI (#{label}) ===\n#{content}\n=======================\n"
              # Replace the @reference in prompt with a clean label and append block
              clean_text = String.replace(acc_text, full_match, "[Ref: #{label}]")
              {clean_text <> block, [label | acc_attachments]}

            {:error, reason} ->
              Logger.warning("[ContextExpander] Failed to expand reference '#{target}': #{reason}")
              {acc_text, acc_attachments}
          end
        end)

      {:ok, expanded_text, Enum.reverse(attachments)}
    end
  end

  def resolve_reference("file://" <> path, _cwd) do
    read_local_file(path, "file://" <> path)
  end

  def resolve_reference("http://" <> _ = url, _cwd), do: fetch_url(url)
  def resolve_reference("https://" <> _ = url, _cwd), do: fetch_url(url)

  def resolve_reference(rel_or_abs_path, cwd) do
    expanded_path =
      if String.starts_with?(rel_or_abs_path, "/") do
        rel_or_abs_path
      else
        Path.expand(rel_or_abs_path, cwd)
      end

    read_local_file(expanded_path, rel_or_abs_path)
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
