defmodule DeepSeekHarnessTest do
  use ExUnit.Case

  test "starts a session via top-level API and sends message" do
    {:ok, session_pid} = DeepSeekHarness.start_session(session_id: "api_test")
    assert is_pid(session_pid)

    {:ok, response} = DeepSeekHarness.send_message(session_pid, "What tools do you have?")
    assert is_binary(response.content)
  end
end
