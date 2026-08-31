defmodule DeepSeekHarness.Workflow.Json do
  @moduledoc """
  Minimal JSON encode/decode helpers for the Workflow subsystem, built on
  OTP's native `:json` module rather than the `Jason` dependency already
  used elsewhere in this codebase, per the project's standing preference
  to migrate JSON handling to the OTP built-in.

  `:json.encode/1` only produces compact output, so a small hand-rolled
  pretty-printer is layered on top: workflow definitions, run state, and
  split plans under `.dsh/workflows/` are meant to be human-readable and
  hand-editable, unlike the single-line JSONL transcript entries.
  """

  @doc "Decodes a JSON string into Elixir terms (maps have string keys). Raises on malformed input."
  def decode!(text) when is_binary(text), do: :json.decode(text)

  @doc "Decodes a JSON string, returning `{:ok, term}` or `{:error, reason}` instead of raising."
  def decode(text) when is_binary(text) do
    {:ok, :json.decode(text)}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    _, reason -> {:error, inspect(reason)}
  end

  @doc "Encodes a term as compact (single-line) JSON text, for append-only JSONL logs."
  def encode!(term), do: term |> :json.encode() |> IO.iodata_to_binary()

  @doc "Encodes a term as pretty-printed (indented, sorted-key) JSON text."
  def encode_pretty!(term), do: pretty(term, 0)

  defp pretty(map, indent) when is_map(map) do
    if map_size(map) == 0 do
      "{}"
    else
      inner_indent = indent + 2

      entries =
        map
        |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
        |> Enum.map_join(",\n", fn {k, v} ->
          String.duplicate(" ", inner_indent) <>
            encode_string(to_string(k)) <> ": " <> pretty(v, inner_indent)
        end)

      "{\n" <> entries <> "\n" <> String.duplicate(" ", indent) <> "}"
    end
  end

  defp pretty([], _indent), do: "[]"

  defp pretty(list, indent) when is_list(list) do
    inner_indent = indent + 2

    entries =
      Enum.map_join(list, ",\n", fn v ->
        String.duplicate(" ", inner_indent) <> pretty(v, inner_indent)
      end)

    "[\n" <> entries <> "\n" <> String.duplicate(" ", indent) <> "]"
  end

  defp pretty(str, _indent) when is_binary(str), do: encode_string(str)
  defp pretty(true, _indent), do: "true"
  defp pretty(false, _indent), do: "false"
  defp pretty(nil, _indent), do: "null"
  defp pretty(num, _indent) when is_number(num), do: to_string(num)
  defp pretty(atom, indent) when is_atom(atom), do: pretty(Atom.to_string(atom), indent)

  defp encode_string(str), do: str |> :json.encode() |> IO.iodata_to_binary()
end
