defmodule AgentMachine.Providers.OpenAIResponses do
  @moduledoc """
  Minimal OpenAI Responses API provider.

  Required runtime inputs:

  - `OPENAI_API_KEY` environment variable
  - `:http_timeout_ms` option passed by the orchestrator caller
  - explicit agent pricing
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON}

  @url ~c"https://api.openai.com/v1/responses"

  @impl true
  def complete(%Agent{} = agent, opts) do
    api_key = System.fetch_env!("OPENAI_API_KEY")
    timeout_ms = Keyword.fetch!(opts, :http_timeout_ms)

    body =
      %{"model" => agent.model, "input" => agent.input}
      |> put_optional("instructions", agent.instructions)
      |> put_optional("metadata", agent.metadata)
      |> JSON.encode!()

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

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp ensure_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
    end
  end

  defp output_text!(%{"output_text" => text}) when is_binary(text), do: text

  defp output_text!(%{"output" => output}) when is_list(output) do
    text =
      output
      |> collect_output_text([])
      |> Enum.reverse()
      |> Enum.join("\n")

    if text == "" do
      raise ArgumentError, "OpenAI response did not contain output text"
    else
      text
    end
  end

  defp output_text!(response) do
    raise ArgumentError, "OpenAI response did not contain output text: #{inspect(response)}"
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
