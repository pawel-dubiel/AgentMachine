defmodule AgentMachine.Providers.OpenRouterChat do
  @moduledoc """
  Minimal OpenRouter chat completions provider.

  Required runtime inputs:

  - `OPENROUTER_API_KEY` environment variable
  - `:http_timeout_ms` option passed by the orchestrator caller
  - explicit agent pricing
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, HTTPSSE, JSON, RunContextPrompt, ToolHarness}

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

  @impl true
  def stream_complete(%Agent{} = agent, opts) do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")
    timeout_ms = Keyword.fetch!(opts, :http_timeout_ms)
    messages = messages(agent, opts)

    body =
      agent
      |> request_body(opts)
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})
      |> JSON.encode!()

    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)},
      {~c"content-type", ~c"application/json"},
      {~c"x-openrouter-title", ~c"AgentMachine"}
    ]

    ensure_started!(:inets)
    ensure_started!(:ssl)

    {:ok, state} =
      Elixir.Agent.start_link(fn -> %{content: "", usage: nil, tool_calls: %{}, error: nil} end)

    result =
      HTTPSSE.post(@url, headers, body, timeout_ms, fn data ->
        handle_stream_data(state, opts, data)
      end)

    stream_state = Elixir.Agent.get(state, & &1)
    Elixir.Agent.stop(state)

    cond do
      match?({:error, _reason}, result) ->
        result

      stream_state.error != nil ->
        {:error, stream_state.error}

      is_nil(stream_state.usage) ->
        {:error, "OpenRouter stream ended without usage"}

      true ->
        message = streamed_message(stream_state)
        tool_calls = ToolHarness.openrouter_tool_calls!(message, opts)
        emit_done(opts)

        {:ok,
         %{
           output: output_text!(message, tool_calls),
           tool_calls: tool_calls,
           tool_state: tool_state(tool_calls, messages, message),
           usage: usage!(%{"usage" => stream_state.usage})
         }}
    end
  end

  @impl true
  def context_budget_request(%Agent{} = agent, opts) do
    {:ok,
     %{
       provider: :openrouter_chat,
       request: budget_request_body(agent, opts),
       breakdown: budget_breakdown(agent, opts)
     }}
  end

  if Mix.env() == :test do
    def request_body_for_test!(%Agent{} = agent, opts), do: request_body(agent, opts)

    def context_budget_request_for_test!(%Agent{} = agent, opts),
      do: context_budget_request(agent, opts)

    def handle_stream_data_for_test(state, opts, data), do: handle_stream_data(state, opts, data)
  end

  defp request_body(%Agent{} = agent, opts) do
    %{
      "model" => agent.model,
      "messages" => messages(agent, opts)
    }
    |> put_response_format(opts)
    |> ToolHarness.put_openrouter_tools!(opts)
  end

  defp put_response_format(body, opts) do
    case Keyword.fetch(opts, :response_format) do
      {:ok, response_format} when is_map(response_format) ->
        Map.put(body, "response_format", response_format)

      {:ok, response_format} ->
        raise ArgumentError,
              "OpenRouter response_format must be a map, got: #{inspect(response_format)}"

      :error ->
        body
    end
  end

  defp budget_request_body(%Agent{} = agent, opts) do
    body = request_body(agent, opts)

    if Keyword.get(opts, :stream_response, false) do
      body
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})
    else
      body
    end
  end

  defp budget_breakdown(%Agent{} = agent, opts) do
    tool_groups = ToolHarness.openrouter_tool_groups!(opts)

    case Keyword.fetch(opts, :tool_continuation) do
      {:ok, _continuation} ->
        %{
          instructions: agent.instructions,
          task_input: nil,
          run_context: nil,
          skills: nil,
          tools: tool_groups.tools,
          mcp_tools: tool_groups.mcp_tools,
          tool_continuation: messages(agent, opts)
        }

      :error ->
        sections = RunContextPrompt.budget_sections(opts)

        %{
          instructions: agent.instructions,
          task_input: agent.input,
          run_context: sections.run_context,
          skills: sections.skills,
          tools: tool_groups.tools,
          mcp_tools: tool_groups.mcp_tools,
          tool_continuation: nil
        }
    end
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

  defp handle_stream_data(_state, _opts, "[DONE]"), do: :halt

  defp handle_stream_data(state, opts, data) do
    decoded = JSON.decode!(data)

    cond do
      is_map(decoded["error"]) ->
        Elixir.Agent.update(state, &Map.put(&1, :error, decoded["error"]))
        :halt

      is_map(decoded["usage"]) ->
        Elixir.Agent.update(state, &Map.put(&1, :usage, decoded["usage"]))

      true ->
        decoded
        |> Map.get("choices", [])
        |> Enum.each(&handle_stream_choice(state, opts, &1))
    end
  end

  defp handle_stream_choice(state, opts, %{"delta" => delta}) when is_map(delta) do
    case Map.get(delta, "content") do
      content when is_binary(content) and content != "" ->
        emit_delta(opts, content)
        Elixir.Agent.update(state, &Map.update!(&1, :content, fn text -> text <> content end))

      _other ->
        :ok
    end

    delta
    |> Map.get("tool_calls", [])
    |> Enum.each(fn call -> Elixir.Agent.update(state, &put_tool_call_delta(&1, call)) end)
  end

  defp handle_stream_choice(_state, _opts, _choice), do: :ok

  defp put_tool_call_delta(state, %{"index" => index} = call) when is_integer(index) do
    state_call = Map.get(state.tool_calls, index, %{id: nil, name: nil, arguments: ""})
    function = Map.get(call, "function", %{})

    state_call =
      state_call
      |> put_if_present(:id, Map.get(call, "id"))
      |> put_if_present(:name, Map.get(function, "name"))
      |> append_if_present(:arguments, Map.get(function, "arguments"))

    %{state | tool_calls: Map.put(state.tool_calls, index, state_call)}
  end

  defp put_tool_call_delta(state, _call), do: state

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp append_if_present(map, _key, nil), do: map
  defp append_if_present(map, _key, ""), do: map
  defp append_if_present(map, key, value), do: Map.update!(map, key, &(&1 <> value))

  defp streamed_message(%{content: content, tool_calls: tool_calls}) do
    message = %{"role" => "assistant", "content" => content}

    calls =
      tool_calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} ->
        %{
          "id" => Map.fetch!(call, :id),
          "type" => "function",
          "function" => %{
            "name" => Map.fetch!(call, :name),
            "arguments" => Map.fetch!(call, :arguments)
          }
        }
      end)

    if calls == [], do: message, else: Map.put(message, "tool_calls", calls)
  end

  defp emit_delta(opts, delta) do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_delta,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      delta: delta,
      at: DateTime.utc_now()
    })
  end

  defp emit_done(opts) do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_done,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      at: DateTime.utc_now()
    })
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
