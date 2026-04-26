defmodule AgentMachine.Providers.OpenRouterChat do
  @moduledoc """
  Minimal OpenRouter chat completions provider.

  Required runtime inputs:

  - `OPENROUTER_API_KEY` environment variable
  - `:http_timeout_ms` option passed by the orchestrator caller
  - explicit agent pricing
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON, RunContextPrompt, ToolHarness}

  @url ~c"https://openrouter.ai/api/v1/chat/completions"

  @impl true
  def complete(%Agent{} = agent, opts) do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")
    timeout_ms = Keyword.fetch!(opts, :http_timeout_ms)

    body = agent |> request_body(opts) |> JSON.encode!()

    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)},
      {~c"content-type", ~c"application/json"},
      {~c"x-openrouter-title", ~c"AgentMachine"}
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
        message = message!(decoded)
        tool_calls = ToolHarness.openrouter_tool_calls!(message, opts)

        {:ok,
         %{
           output: output_text!(message, tool_calls),
           tool_calls: tool_calls,
           tool_state: tool_state(tool_calls, messages(agent, opts), message),
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
    %{
      "model" => agent.model,
      "messages" => messages(agent, opts)
    }
    |> ToolHarness.put_openrouter_tools!(opts)
  end

  defp messages(%Agent{} = agent, opts) do
    case Keyword.fetch(opts, :tool_continuation) do
      {:ok, continuation} -> continuation_messages!(continuation)
      :error -> initial_messages(agent, opts)
    end
  end

  defp initial_messages(%Agent{instructions: nil} = agent, opts) do
    [
      %{"role" => "user", "content" => input(agent, opts)}
    ]
  end

  defp initial_messages(%Agent{instructions: instructions} = agent, opts) do
    [
      %{"role" => "system", "content" => instructions},
      %{"role" => "user", "content" => input(agent, opts)}
    ]
  end

  defp continuation_messages!(%{state: %{messages: messages}, results: results})
       when is_list(messages) and is_list(results) do
    messages ++ Enum.map(results, &tool_result_message!/1)
  end

  defp continuation_messages!(continuation) do
    raise ArgumentError, "invalid OpenRouter tool continuation: #{inspect(continuation)}"
  end

  defp tool_result_message!(%{id: id, result: result}) when is_binary(id) and is_map(result) do
    %{
      "role" => "tool",
      "tool_call_id" => id,
      "content" => JSON.encode!(result)
    }
  end

  defp tool_result_message!(result) do
    raise ArgumentError, "invalid OpenRouter tool result: #{inspect(result)}"
  end

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

  defp message!(%{"choices" => choices}) when is_list(choices) do
    choices |> List.first() |> choice_message!()
  end

  defp message!(response) do
    raise ArgumentError, "OpenRouter response did not contain choices: #{inspect(response)}"
  end

  defp choice_message!(%{"message" => message}) when is_map(message), do: message

  defp choice_message!(choice) do
    raise ArgumentError,
          "OpenRouter response choice did not contain a message: #{inspect(choice)}"
  end

  defp tool_state([], _messages, _message), do: nil

  defp tool_state(_tool_calls, messages, message) do
    %{messages: messages ++ [message]}
  end

  defp output_text!(%{"content" => content}, _tool_calls)
       when is_binary(content) and content != "" do
    content
  end

  defp output_text!(_message, tool_calls) when tool_calls != [] do
    "requested #{length(tool_calls)} OpenRouter tool call(s)"
  end

  defp output_text!(message, _tool_calls) do
    raise ArgumentError,
          "OpenRouter response message did not contain content: #{inspect(message)}"
  end

  defp usage!(%{"usage" => usage}) when is_map(usage) do
    %{
      input_tokens: fetch_usage_integer!(usage, "prompt_tokens"),
      output_tokens: fetch_usage_integer!(usage, "completion_tokens"),
      total_tokens: fetch_usage_integer!(usage, "total_tokens")
    }
  end

  defp usage!(response) do
    raise ArgumentError, "OpenRouter response did not contain usage: #{inspect(response)}"
  end

  defp fetch_usage_integer!(usage, field) do
    value = Map.fetch!(usage, field)

    if is_integer(value) and value >= 0 do
      value
    else
      raise ArgumentError,
            "OpenRouter usage #{field} must be a non-negative integer, got: #{inspect(value)}"
    end
  end
end
