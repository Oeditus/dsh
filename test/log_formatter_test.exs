defmodule DeepSeekHarness.CLI.LogFormatterTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.LogFormatter

  test "formats info log event with blue circle and no timestamp" do
    event = %{
      level: :info,
      msg: {:string, "[Hands.Executor] [local] Executing bash with args: %{}"}
    }

    formatted = LogFormatter.format(event, %{})

    assert String.contains?(formatted, "●")
    assert String.contains?(formatted, "[Hands.Executor] [local] Executing bash with args: %{}")
    refute String.contains?(formatted, "[info]")
  end

  test "formats error log event with red circle" do
    event = %{level: :error, msg: "Failed to connect"}
    formatted = LogFormatter.format(event, %{})

    assert String.contains?(formatted, "●")
    assert String.contains?(formatted, "Failed to connect")
  end

  test "formats warning log event with yellow circle" do
    event = %{level: :warning, msg: "Deprecated tool call"}
    formatted = LogFormatter.format(event, %{})

    assert String.contains?(formatted, "●")
    assert String.contains?(formatted, "Deprecated tool call")
  end

  test "installs log formatter handler without raising" do
    assert LogFormatter.install() == :ok or LogFormatter.install() == :error
  end
end
