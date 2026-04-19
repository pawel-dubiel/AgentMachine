defmodule AgentMachine.Providers.OpenRouterChat do
  @moduledoc """
  Minimal OpenRouter chat completions provider.

  Required runtime inputs:

  - `OPENROUTER_API_KEY` environment variable
  - `:http_timeout_ms` option passed by the orchestrator caller
  - explicit agent pricing
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON}

  @url ~c"https://openrouter.ai/api/v1/chat/completions"

  @impl true
  def complete(%Agent{} = agent, opts) do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")
    timeout_ms = Keyword.fetch!(opts, :http_timeout_ms)

    body =
      %{
        "model" => agent.model,
        "messages" => messages(agent)
      }
      |> JSON.encode!()

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

        {:ok,
         %{
           output: output_text!(decoded),
           usage: usage!(decoded)
         }}

      {:ok, {{_version, status, reason}, _headers, response_body}} ->
        {:error, %{status: status, reason: reason, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp messages(%Agent{instructions: nil, input: input}) do
    [
      %{"role" => "user", "content" => input}
    ]
  end

  defp messages(%Agent{instructions: instructions, input: input}) do
    [
      %{"role" => "system", "content" => instructions},
      %{"role" => "user", "content" => input}
    ]
  end

  defp ensure_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
    end
  end

  defp output_text!(%{"choices" => choices}) when is_list(choices) do
    choices
    |> List.first()
    |> choice_text!()
  end

  defp output_text!(response) do
    raise ArgumentError, "OpenRouter response did not contain choices: #{inspect(response)}"
  end

  defp choice_text!(%{"message" => %{"content" => content}}) when is_binary(content), do: content

  defp choice_text!(choice) do
    raise ArgumentError,
          "OpenRouter response choice did not contain message content: #{inspect(choice)}"
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
