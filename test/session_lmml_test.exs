defmodule DeepSeekHarness.Brain.SessionLmmlTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Brain.SessionLmml

  describe "encode/2" do
    test "produces a valid lmml narrative with manifest and message embeds" do
      session_state = %{
        session_id: "abc",
        model: "deepseek-chat",
        permission_mode: :ask_confirm,
        step_count: 2,
        total_prompt_tokens: 10,
        total_completion_tokens: 20,
        messages: [
          %{"role" => "system", "content" => "sys"},
          %{"role" => "user", "content" => "hi"}
        ],
        snapshots: []
      }

      assert {:ok, narrative} = SessionLmml.encode(session_state, "abc")
      assert String.contains?(narrative, "# DSH Conversation: abc")
      assert String.contains?(narrative, "@@@manifest.json")
      assert String.contains?(narrative, "@@@message.0.json")
      assert String.contains?(narrative, "@@@message.1.json")
      assert String.contains?(narrative, "## USER")
      assert String.contains?(narrative, "## SYSTEM")
      assert String.contains?(narrative, "hi")
    end

    test "renders a human-readable view of multimodal and tool-call messages" do
      session_state = %{
        session_id: "x",
        model: "deepseek-chat",
        permission_mode: :ask_confirm,
        step_count: 0,
        total_prompt_tokens: 0,
        total_completion_tokens: 0,
        messages: [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAA"}},
              %{"type" => "text", "text" => "What is this?"}
            ]
          },
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{"id" => "c1", "type" => "function", "function" => %{"name" => "bash"}}
            ]
          }
        ],
        snapshots: []
      }

      assert {:ok, narrative} = SessionLmml.encode(session_state, "x")
      assert String.contains?(narrative, "[Image: data:image/png;base64,AAA]")
      assert String.contains?(narrative, "What is this?")
      assert String.contains?(narrative, "tool calls: bash")
    end
  end

  describe "decode/1" do
    test "round-trips a session_state losslessly" do
      messages = [
        %{"role" => "system", "content" => "You are an expert."},
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi!", "reasoning_content" => "thinking"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "c1",
              "type" => "function",
              "function" => %{"name" => "bash", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "c1", "content" => "out"}
      ]

      session_state = %{
        session_id: "roundtrip",
        model: "deepseek-reasoner",
        permission_mode: :auto_approve,
        step_count: 4,
        total_prompt_tokens: 100,
        total_completion_tokens: 50,
        messages: messages,
        snapshots: [
          %{
            id: "cp_1",
            label: "Checkpoint",
            timestamp: "2026-08-17T08:00:00Z",
            model: "deepseek-chat",
            messages: [%{"role" => "user", "content" => "earlier"}]
          }
        ]
      }

      {:ok, narrative} = SessionLmml.encode(session_state, "roundtrip")
      assert {:ok, decoded} = SessionLmml.decode(narrative)

      assert decoded["messages"] == messages
      assert decoded["session_id"] == "roundtrip"
      assert decoded["model"] == "deepseek-reasoner"
      assert decoded["permission_mode"] == "auto_approve"
      assert decoded["step_count"] == 4
      assert decoded["total_prompt_tokens"] == 100
      assert decoded["total_completion_tokens"] == 50
      assert [snap] = decoded["snapshots"]
      assert snap["label"] == "Checkpoint"
      assert snap["messages"] == [%{"role" => "user", "content" => "earlier"}]
    end

    test "defaults missing manifest fields" do
      narrative = """
      # DSH Conversation: minimal

      @@@manifest.json
      {}
      @@@

      ## USER

      @@@message.0.json
      {"role":"user","content":"hi"}
      @@@
      """

      assert {:ok, decoded} = SessionLmml.decode(narrative)
      assert decoded["messages"] == [%{"role" => "user", "content" => "hi"}]
      assert decoded["model"] == "deepseek-chat"
      assert decoded["permission_mode"] == "ask_confirm"
      assert decoded["step_count"] == 0
      assert decoded["snapshots"] == []
    end

    test "rejects an invalid message embed" do
      narrative = """
      # DSH Conversation: bad

      @@@manifest.json
      {}
      @@@

      ## USER

      @@@message.0.json
      not valid json
      @@@
      """

      assert {:error, _reason} = SessionLmml.decode(narrative)
    end

    test "decodes from a Lmml.Bundle directly" do
      {:ok, narrative} =
        SessionLmml.encode(
          %{
            session_id: "bundle",
            model: "deepseek-chat",
            permission_mode: :ask_confirm,
            step_count: 0,
            total_prompt_tokens: 0,
            total_completion_tokens: 0,
            messages: [%{"role" => "user", "content" => "from bundle"}],
            snapshots: []
          },
          "bundle"
        )

      {:ok, bundle} = Lmml.Bundle.new_text("bundle.lmml", narrative)
      assert {:ok, decoded} = SessionLmml.decode(bundle)
      assert decoded["messages"] == [%{"role" => "user", "content" => "from bundle"}]
    end
  end
end
