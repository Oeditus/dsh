defmodule DeepSeekHarness.Plugin.Behaviour do
  @moduledoc """
  Defines the behaviour contract for DeepSeek Harness (DSH) plugins.
  Plugins allow dynamic extension of tools and session hooks.
  Supports hot-code swapping without dropping active session state.
  """

  @type tool_param_schema :: %{
          type: String.t(),
          properties: map(),
          required: list(String.t())
        }

  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          parameters: tool_param_schema(),
          execute: (map() -> {:ok, String.t() | map()} | {:error, String.t()})
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback tools() :: [tool_def()]

  @optional_callbacks [tools: 0]
end
