defmodule AgentMachine.ReqLLMClient do
  @moduledoc false

  def generate_text(model, context, opts), do: ReqLLM.generate_text(model, context, opts)

  def stream_text(model, context, opts), do: ReqLLM.stream_text(model, context, opts)

  def process_stream(stream_response, opts),
    do: ReqLLM.StreamResponse.process_stream(stream_response, opts)

  def classify_response(response), do: ReqLLM.Response.classify(response)
end
