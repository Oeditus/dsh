defmodule DeepSeekHarness.ClipboardTest do
  use ExUnit.Case, async: true
  alias DeepSeekHarness.Clipboard

  test "fetch_image/0 returns ok or error without crashing" do
    result = Clipboard.fetch_image()

    assert match?({:ok, _mime, _bytes}, result) or match?({:error, _reason}, result)
  end

  test "fetch_text/0 returns ok or error without crashing" do
    result = Clipboard.fetch_text()

    assert match?({:ok, _text}, result) or match?({:error, _reason}, result)
  end
end
