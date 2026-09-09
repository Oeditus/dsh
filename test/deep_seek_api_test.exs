defmodule DeepSeekHarness.DeepSeekAPITest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Client.DeepSeekAPI

  test "returns mock chat completion in offline mode" do
    messages = [%{"role" => "user", "content" => "Hello DeepSeek"}]

    assert {:ok, %{content: content}} =
             DeepSeekAPI.chat_completion(messages, [], model: "deepseek-chat")

    assert is_binary(content)
  end

  test "extracts reasoning content for deepseek-reasoner R1 model" do
    messages = [%{"role" => "user", "content" => "Explain quantum physics"}]

    assert {:ok, %{content: content, reasoning_content: reasoning}} =
             DeepSeekAPI.chat_completion(messages, [], model: "deepseek-reasoner")

    assert is_binary(content)
    assert is_binary(reasoning)
  end

  describe "build_config/1 max_tokens handling" do
    test "defaults max_tokens to nil when not provided" do
      cfg = DeepSeekAPI.build_config([])
      assert cfg.max_tokens == nil
    end

    test "captures an explicit max_tokens opt" do
      cfg = DeepSeekAPI.build_config(max_tokens: 64_000)
      assert cfg.max_tokens == 64_000
    end

    test "preserves max_tokens through chat_completion opts" do
      messages = [%{"role" => "user", "content" => "Hello"}]

      assert {:ok, %{content: content}} =
               DeepSeekAPI.chat_completion(messages, [], max_tokens: 64_000)

      assert is_binary(content)
    end
  end

  describe "OpenRouter and local model helpers" do
    test "normalize_endpoint/1 appends /chat/completions or /v1/chat/completions correctly" do
      assert DeepSeekAPI.normalize_endpoint("https://api.deepseek.com/chat/completions") ==
               "https://api.deepseek.com/chat/completions"

      assert DeepSeekAPI.normalize_endpoint("https://openrouter.ai/api/v1") ==
               "https://openrouter.ai/api/v1/chat/completions"

      assert DeepSeekAPI.normalize_endpoint("http://localhost:11434") ==
               "http://localhost:11434/v1/chat/completions"
    end

    test "local_endpoint?/1 identifies localhost and local IP addresses" do
      assert DeepSeekAPI.local_endpoint?("http://localhost:11434/v1/chat/completions") == true
      assert DeepSeekAPI.local_endpoint?("http://127.0.0.1:1234/v1/chat/completions") == true
      assert DeepSeekAPI.local_endpoint?("https://openrouter.ai/api/v1/chat/completions") == false
      assert DeepSeekAPI.local_endpoint?("https://api.deepseek.com/chat/completions") == false
    end

    test "build_config/1 automatically sets dummy api_key for local endpoints" do
      cfg = DeepSeekAPI.build_config(endpoint: "http://localhost:11434")
      assert cfg.endpoint == "http://localhost:11434/v1/chat/completions"
      assert cfg.api_key == "not-needed"
    end
  end
end
