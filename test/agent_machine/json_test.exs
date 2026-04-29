defmodule AgentMachine.JSONTest do
  use ExUnit.Case, async: true

  alias AgentMachine.JSON

  test "round-trips basic JSON values" do
    value = %{
      "model" => "test",
      "input" => "hello\nworld",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3},
      "items" => [true, false, nil, 1.5]
    }

    assert JSON.decode!(JSON.encode!(value)) == value
  end

  test "decodes nested output text payload" do
    payload = """
    {
      "output": [
        {
          "type": "message",
          "content": [
            {"type": "output_text", "text": "done"}
          ]
        }
      ],
      "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
    }
    """

    assert %{"output" => [%{"content" => [%{"text" => "done"}]}]} = JSON.decode!(payload)
  end

  test "decodes escaped UTF-16 surrogate pairs" do
    assert JSON.decode!(~S({"emoji":"\uD83C\uDF26"})) == %{"emoji" => <<0x1F326::utf8>>}
  end

  test "rejects invalid escaped UTF-16 surrogates" do
    assert_raise ArgumentError, ~r/high surrogate/, fn ->
      JSON.decode!(~S({"emoji":"\uD83C"}))
    end

    assert_raise ArgumentError, ~r/lone low surrogate/, fn ->
      JSON.decode!(~S({"emoji":"\uDF26"}))
    end
  end
end
