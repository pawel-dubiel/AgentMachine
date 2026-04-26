defmodule AgentMachine.SSETest do
  use ExUnit.Case, async: true

  alias AgentMachine.SSE

  test "parses data events across chunks" do
    state = SSE.new()

    {state, events} = SSE.parse_chunk(state, "data: {\"a\":")
    assert events == []

    {state, events} = SSE.parse_chunk(state, "1}\n\ndata: [DONE]\n\n")
    assert events == ["{\"a\":1}", "[DONE]"]

    {_state, events} = SSE.flush(state)
    assert events == []
  end

  test "joins multi-line data events" do
    {_state, events} = SSE.parse_chunk(SSE.new(), "event: message\ndata: one\ndata: two\n\n")

    assert events == ["one\ntwo"]
  end
end
