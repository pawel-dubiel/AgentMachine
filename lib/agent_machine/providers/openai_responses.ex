defmodule AgentMachine.Providers.OpenAIResponses do
  @moduledoc """
  Minimal OpenAI Responses API provider.

  Required runtime inputs:

  - `OPENAI_API_KEY` environment variable
  - `:http_timeout_ms` option passed by the orchestrator caller
  - explicit agent pricing
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON, RunContextPrompt, ToolHarness}

  @url ~c"https://api.openai.com/v1/responses"

  @impl true
  def complete(%Agent{} = agent, opts) do
    api_key = System.fetch_env!("OPENAI_API_KEY")
    timeout_ms = Keyword.fetch!(opts, :http_timeout_ms)

    body = agent |> request_body(opts) |> JSON.encode!()

    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)},
      {~c"content-type", ~c"application/json"}
    ]

    ensure_started!(:inets)
    ensure_started!(:ssl)

    case :httpc.request(
           :post,
           {@url, headers, ~c"application/json", body},
           [{:timeout, timeout_ms}],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        decoded = JSON.decode!(response_body)
        tool_calls = ToolHarness.openai_tool_calls!(decoded, opts)

        {:ok,
         %{
           output: output_text!(decoded, tool_calls),
           tool_calls: tool_calls,
           tool_state: tool_state(decoded, tool_calls),
           usage: usage!(decoded)
         }}

      {:ok, {{_version, status, reason}, _headers, response_body}} ->
        {:error, %{status: status, reason: reason, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  if Mix.env() == :test do
    def request_body_for_test!(%Agent{} = agent, opts), do: request_body(agent, opts)
  end

  defp request_body(%Agent{} = agent, opts) do
    agent
    |> base_request_body(opts)
    |> put_optional("instructions", agent.instructions)
    |> put_optional("metadata", agent.metadata)
    |> ToolHarness.put_openai_tools!(opts)
  end

  defp base_request_body(%Agent{} = agent, opts) do
    case Keyword.fetch(opts, :tool_continuation) do
      {:ok, continuation} ->
        continuation_request_body!(agent, continuation)

      :error ->
        %{"model" => agent.model, "input" => input(agent, opts)}
    end
  end

  defp continuation_request_body!(%Agent{} = agent, %{
         state: %{response_id: response_id},
         results: results
       })
       when is_binary(response_id) and is_list(results) do
    %{
      "model" => agent.model,
      "previous_response_id" => response_id,
      "input" => Enum.map(results, &function_call_output!/1)
    }
  end

  defp continuation_request_body!(_agent, continuation) do
    raise ArgumentError, "invalid OpenAI tool continuation: #{inspect(continuation)}"
  end

  defp function_call_output!(%{id: id, result: result}) when is_binary(id) and is_map(result) do
    %{
      "type" => "function_call_output",
      "call_id" => id,
      "output" => JSON.encode!(result)
    }
  end

  defp function_call_output!(result) do
    raise ArgumentError, "invalid OpenAI tool result: #{inspect(result)}"
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp input(agent, opts) do
    case RunContextPrompt.text(opts) do
      "" -> agent.input
      context -> agent.input <> "\n\nRun context:\n" <> context
    end
  end

  defp ensure_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
    end
  end

  defp output_text!(%{"output_text" => text}, _tool_calls) when is_binary(text), do: text

  defp output_text!(%{"output" => output}, tool_calls) when is_list(output) do
    text =
      output
      |> collect_output_text([])
      |> Enum.reverse()
      |> Enum.join("\n")

    output_or_tool_call_placeholder!(text, tool_calls, "OpenAI")
  end

  defp output_text!(response, _tool_calls) do
    raise ArgumentError, "OpenAI response did not contain output text: #{inspect(response)}"
  end

  defp output_or_tool_call_placeholder!(text, tool_calls, provider) do
    cond do
      text != "" -> text
      tool_calls != [] -> "requested #{length(tool_calls)} #{provider} tool call(s)"
      true -> raise ArgumentError, "#{provider} response did not contain output text"
    end
  end

  defp tool_state(_response, []), do: nil

  defp tool_state(%{"id" => response_id}, _tool_calls) when is_binary(response_id) do
    %{response_id: response_id}
  end

  defp tool_state(response, _tool_calls) do
    raise ArgumentError, "OpenAI tool response did not contain id: #{inspect(response)}"
  end

  defp usage!(%{"usage" => usage}) when is_map(usage), do: usage

  defp usage!(response) do
    raise ArgumentError, "OpenAI response did not contain usage: #{inspect(response)}"
  end

  defp collect_output_text([], acc), do: acc

  defp collect_output_text([%{"content" => content} | rest], acc) when is_list(content) do
    collect_output_text(rest, collect_content_text(content, acc))
  end

  defp collect_output_text([_other | rest], acc), do: collect_output_text(rest, acc)

  defp collect_content_text([], acc), do: acc

  defp collect_content_text([%{"type" => "output_text", "text" => text} | rest], acc)
       when is_binary(text) do
    collect_content_text(rest, [text | acc])
  end

  defp collect_content_text([%{"type" => "refusal", "refusal" => text} | rest], acc)
       when is_binary(text) do
    collect_content_text(rest, [text | acc])
  end

  defp collect_content_text([_other | rest], acc), do: collect_content_text(rest, acc)
end
