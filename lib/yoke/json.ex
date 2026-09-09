defmodule Yoke.Json do
  @moduledoc """
  Thin wrapper around Elixir's built-in `JSON` module (Elixir 1.18+ /
  OTP 27+), replacing the former direct `:jason` dependency for Yoke's own
  JSON encoding/decoding needs.

  `JSON.encode!/1` only produces compact output -- there is no built-in
  pretty-printing option -- so this module adds a small hand-rolled
  pretty-printer (`encode!/2` and `encode/2` with `pretty: true`) for the
  human-edited/diffed files Yoke writes to disk (config, rules, session
  manifests). Everything else delegates straight to `JSON`, so string
  escaping and scalar encoding always go through the standard library's
  own (spec-conformant) implementation.
  """

  @doc "Decodes a JSON binary. See `JSON.decode/1`."
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  defdelegate decode(binary), to: JSON

  @doc "Decodes a JSON binary, raising on error. See `JSON.decode!/1`."
  @spec decode!(binary()) :: term()
  defdelegate decode!(binary), to: JSON

  @doc """
  Encodes `term` to a JSON binary.

  Pass `pretty: true` to indent the output (2 spaces per level) for
  human-edited/diffed files; omitted (or `false`) produces the same
  compact output as `JSON.encode!/1`.
  """
  @spec encode!(term(), keyword()) :: binary()
  def encode!(term, opts \\ []) do
    if Keyword.get(opts, :pretty, false) do
      pretty_encode!(term, 0)
    else
      JSON.encode!(term)
    end
  end

  @doc """
  Same as `encode!/2`, but returns `{:ok, binary}` / `{:error, exception}`
  instead of raising -- mirrors `Jason.encode/2`'s shape for `with`-based
  call sites.
  """
  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(term, opts \\ []) do
    {:ok, encode!(term, opts)}
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------
  # Pretty-printer -- walks the already-decoded Elixir term and builds the
  # indented structure itself, delegating every leaf (string/number/
  # boolean/nil/atom) to `JSON.encode!/1` so escaping stays spec-correct.
  # ---------------------------------------------------------------------

  defp pretty_encode!(map, _indent)
       when is_map(map) and not is_struct(map) and map_size(map) == 0,
       do: "{}"

  defp pretty_encode!(map, indent) when is_map(map) and not is_struct(map) do
    inner = indent_str(indent + 1)
    outer = indent_str(indent)

    entries =
      Enum.map_join(map, ",\n", fn {k, v} ->
        "#{inner}#{JSON.encode!(to_string(k))}: #{pretty_encode!(v, indent + 1)}"
      end)

    "{\n#{entries}\n#{outer}}"
  end

  defp pretty_encode!([], _indent), do: "[]"

  defp pretty_encode!(list, indent) when is_list(list) do
    inner = indent_str(indent + 1)
    outer = indent_str(indent)

    entries =
      Enum.map_join(list, ",\n", fn v -> "#{inner}#{pretty_encode!(v, indent + 1)}" end)

    "[\n#{entries}\n#{outer}]"
  end

  # Catches scalars (string/number/boolean/nil) as well as any struct
  # (Date/Time/DateTime/NaiveDateTime/Duration, etc.) -- structs are maps,
  # but they must NOT go through the map-indenting clause above, since
  # `JSON.Encoder` already has correct, purpose-built implementations for
  # them (e.g. ISO 8601 strings for calendar types).
  defp pretty_encode!(scalar, _indent), do: JSON.encode!(scalar)

  defp indent_str(level), do: String.duplicate("  ", level)
end
