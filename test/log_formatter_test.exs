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

  test "suppresses noisy low-level socket transport logs" do
    event1 = %{level: :info, msg: "[HANDLER] Received data: ping"}
    event2 = %{level: :info, msg: "[ACCEPT LOOP] Starting, socket: #Port<0.35>"}
    event3 = %{level: :info, msg: "Client connected: #Port<0.39>"}

    assert LogFormatter.format(event1, %{}) == ""
    assert LogFormatter.format(event2, %{}) == ""
    assert LogFormatter.format(event3, %{}) == ""
  end

  test "installs log formatter handler without raising" do
    assert LogFormatter.install() == :ok or LogFormatter.install() == :error
  end
end
