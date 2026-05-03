defmodule AgentMachine.ModelOutputJSONTest do
  use ExUnit.Case, async: true

  alias AgentMachine.ModelOutputJSON

  test "decodes strict JSON objects" do
    assert ModelOutputJSON.decode_object!(~S({"ok":true}), "model response") == %{"ok" => true}
  end

  test "decodes model JSON object wrapped in markdown or prose" do
    payload = """
    **Router decision**

    ```json
    {"text":"brace } inside string","nested":{"ok":true}}
    ```
    """

    assert ModelOutputJSON.decode_object!(payload, "model response") == %{
             "text" => "brace } inside string",
             "nested" => %{"ok" => true}
           }
  end

  test "fails fast when model output has no JSON object" do
    assert_raise ArgumentError, ~r/invalid model response/, fn ->
      ModelOutputJSON.decode_object!("**not json**", "model response")
    end
  end

  test "fails fast when model output is not a JSON object" do
    assert_raise ArgumentError, ~r/model response must be a JSON object/, fn ->
      ModelOutputJSON.decode_object!("[1,2,3]", "model response")
    end
  end
end
