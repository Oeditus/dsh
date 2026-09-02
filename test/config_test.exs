defmodule DeepSeekHarness.ConfigTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Config

  test "loads config with default values" do
    config = Config.load_config()
    assert is_map(config)
    assert Map.has_key?(config, "model")
  end

  test "defaults per-million-token prices to DeepSeek V3 rates" do
    config = Config.load_config()
    assert config["price_per_million_prompt_tokens"] == 0.14
    assert config["price_per_million_completion_tokens"] == 0.28
  end

  test "allows overriding per-million-token prices in config" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "config_price_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    cfg = %{
      "price_per_million_prompt_tokens" => 1.0,
      "price_per_million_completion_tokens" => 2.0
    }

    assert :ok = Config.save_config(cfg, tmp_dir)
    loaded = Config.load_config(tmp_dir)
    assert loaded["price_per_million_prompt_tokens"] == 1.0
    assert loaded["price_per_million_completion_tokens"] == 2.0

    File.rm_rf!(tmp_dir)
  end

  test "defaults max_tool_depth to 100 and allows workspace override" do
    assert Config.load_config()["max_tool_depth"] == 100

    tmp_dir =
      Path.join(System.tmp_dir!(), "config_depth_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    assert :ok = Config.save_config(%{"max_tool_depth" => 250}, tmp_dir)
    assert Config.load_config(tmp_dir)["max_tool_depth"] == 250

    File.rm_rf!(tmp_dir)
  end

  test "discovers project rules if present or returns empty string" do
    rules = Config.discover_project_rules()
    assert is_binary(rules)
  end

  test "saves and reloads custom configuration" do
    tmp_dir = Path.join(System.tmp_dir!(), "config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    cfg = %{"model" => "deepseek-reasoner", "prompt_format" => "custom> "}
    assert :ok = Config.save_config(cfg, tmp_dir)

    loaded = Config.load_config(tmp_dir)
    assert loaded["model"] == "deepseek-reasoner"
    assert loaded["prompt_format"] == "custom> "

    File.rm_rf!(tmp_dir)
  end

  test "sets per-tool permission policy in config" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "config_perm_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    assert :ok = Config.set_tool_permission("read_file", "allow", tmp_dir)

    loaded = Config.load_config(tmp_dir)
    assert loaded["tool_permissions"]["read_file"] == "allow"

    File.rm_rf!(tmp_dir)
  end
end
