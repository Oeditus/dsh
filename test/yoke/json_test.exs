defmodule Yoke.JsonTest do
  use ExUnit.Case, async: true

  alias Yoke.Json

  describe "decode/1 and decode!/1" do
    test "decodes a valid JSON object" do
      assert {:ok, %{"a" => 1}} = Json.decode(~s({"a":1}))
      assert %{"a" => 1} = Json.decode!(~s({"a":1}))
    end

    test "returns an error tuple for invalid JSON" do
      assert {:error, _reason} = Json.decode("not json")
    end
  end

  describe "encode!/2 without :pretty" do
    test "produces compact output" do
      assert Json.encode!(%{"a" => 1, "b" => [1, 2]}) == ~s({"a":1,"b":[1,2]})
    end
  end

  describe "encode!/2 with pretty: true" do
    test "indents nested maps and lists" do
      json = Json.encode!(%{"a" => 1, "b" => [1, 2]}, pretty: true)

      assert json == """
             {
               "a": 1,
               "b": [
                 1,
                 2
               ]
             }\
             """

      assert {:ok, decoded} = Json.decode(json)
      assert decoded == %{"a" => 1, "b" => [1, 2]}
    end

    test "renders empty maps and lists compactly" do
      assert Json.encode!(%{}, pretty: true) == "{}"
      assert Json.encode!([], pretty: true) == "[]"
    end

    test "delegates struct encoding (e.g. DateTime) to JSON.Encoder instead of treating it as a plain map" do
      dt = ~U[2026-01-01 00:00:00Z]

      json = Json.encode!(%{"at" => dt}, pretty: true)

      assert json == """
             {
               "at": "2026-01-01T00:00:00Z"
             }\
             """
    end
  end

  describe "encode/2" do
    test "returns {:ok, binary}" do
      assert {:ok, ~s({"a":1})} = Json.encode(%{"a" => 1})
    end
  end
end
