defmodule AgentMachine.AgentRunner do
  @moduledoc false

  alias AgentMachine.{Agent, AgentResult, DelegationResponse, Usage, UsageLedger}

  def run(%Agent{} = agent, opts) when is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    attempt = Keyword.fetch!(opts, :attempt)
    _run_context = Keyword.fetch!(opts, :run_context)
    started_at = DateTime.utc_now()

    execute(agent, opts, run_id, attempt, started_at)
  end

  defp execute(agent, opts, run_id, attempt, started_at) do
    case agent.provider.complete(agent, opts) do
      {:ok, %{output: output, usage: provider_usage} = payload} when is_binary(output) ->
        payload = DelegationResponse.normalize_payload!(agent, payload)
        output = payload.output
        usage = Usage.from_provider!(agent, run_id, provider_usage)
        next_agents = next_agents_from_payload!(payload)
        artifacts = artifacts_from_payload!(payload)
        tool_results = tool_results_from_payload!(payload, opts)
        :ok = UsageLedger.record!(usage)

        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :ok,
          attempt: attempt,
          output: output,
          next_agents: next_agents,
          artifacts: artifacts,
          tool_results: tool_results,
          usage: usage,
          started_at: started_at,
          finished_at: DateTime.utc_now()
        }

      {:ok, other} ->
        error(
          agent,
          run_id,
          attempt,
          started_at,
          "provider returned invalid success payload: #{inspect(other)}"
        )

      {:error, reason} ->
        error(agent, run_id, attempt, started_at, inspect(reason))

      other ->
        error(
          agent,
          run_id,
          attempt,
          started_at,
          "provider returned invalid payload: #{inspect(other)}"
        )
    end
  rescue
    exception ->
      %AgentResult{
        run_id: run_id,
        agent_id: agent.id,
        status: :error,
        attempt: attempt,
        error: Exception.format(:error, exception, __STACKTRACE__),
        started_at: started_at,
        finished_at: DateTime.utc_now()
      }
  end

  defp error(agent, run_id, attempt, started_at, reason) do
    %AgentResult{
      run_id: run_id,
      agent_id: agent.id,
      status: :error,
      attempt: attempt,
      error: reason,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp next_agents_from_payload!(payload) when is_map(payload) do
    case fetch_optional_payload_field(payload, :next_agents) do
      :error ->
        []

      {:ok, specs} when is_list(specs) ->
        Enum.map(specs, &Agent.new!/1)

      {:ok, specs} ->
        raise ArgumentError,
              "provider next_agents must be a list of agent specs, got: #{inspect(specs)}"
    end
  end

  defp artifacts_from_payload!(payload) when is_map(payload) do
    case fetch_optional_payload_field(payload, :artifacts) do
      :error ->
        %{}

      {:ok, artifacts} when is_map(artifacts) ->
        artifacts

      {:ok, artifacts} ->
        raise ArgumentError, "provider artifacts must be a map, got: #{inspect(artifacts)}"
    end
  end

  defp tool_results_from_payload!(payload, opts) when is_map(payload) do
    case fetch_optional_payload_field(payload, :tool_calls) do
      :error ->
        %{}

      {:ok, tool_calls} when is_list(tool_calls) ->
        allowed_tools = allowed_tools_from_opts!(opts)
        tool_timeout_ms = tool_timeout_ms_from_opts!(opts)

        validate_unique_tool_call_ids!(tool_calls)

        tool_calls
        |> Enum.map(&run_tool_call!(&1, opts, allowed_tools, tool_timeout_ms))
        |> Map.new()

      {:ok, tool_calls} ->
        raise ArgumentError, "provider tool_calls must be a list, got: #{inspect(tool_calls)}"
    end
  end

  defp allowed_tools_from_opts!(opts) do
    case Keyword.fetch(opts, :allowed_tools) do
      {:ok, allowed_tools} when is_list(allowed_tools) ->
        Enum.each(allowed_tools, &require_tool_module!/1)
        allowed_tools

      {:ok, allowed_tools} ->
        raise ArgumentError,
              ":allowed_tools must be a list of tool modules, got: #{inspect(allowed_tools)}"

      :error ->
        raise ArgumentError, "provider tool_calls require explicit :allowed_tools option"
    end
  end

  defp tool_timeout_ms_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_timeout_ms) do
      {:ok, timeout_ms} when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      {:ok, timeout_ms} ->
        raise ArgumentError,
              ":tool_timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"

      :error ->
        raise ArgumentError, "provider tool_calls require explicit :tool_timeout_ms option"
    end
  end

  defp run_tool_call!(tool_call, opts, allowed_tools, tool_timeout_ms) when is_map(tool_call) do
    id = fetch_tool_call_field!(tool_call, :id)
    tool = fetch_tool_call_field!(tool_call, :tool)
    input = fetch_tool_call_field!(tool_call, :input)

    require_non_empty_binary!(id, "tool call id")
    require_tool_module!(tool)
    require_allowed_tool!(tool, allowed_tools)
    require_tool_input!(input)

    case run_tool_with_timeout(tool, input, opts, tool_timeout_ms) do
      {:ok, result} when is_map(result) ->
        {id, result}

      {:ok, result} ->
        raise ArgumentError, "tool #{inspect(tool)} returned invalid result: #{inspect(result)}"

      {:error, reason} ->
        raise RuntimeError,
              "tool #{inspect(tool)} failed for call #{inspect(id)}: #{inspect(reason)}"

      other ->
        raise ArgumentError, "tool #{inspect(tool)} returned invalid payload: #{inspect(other)}"
    end
  end

  defp run_tool_call!(tool_call, _opts, _allowed_tools, _tool_timeout_ms) do
    raise ArgumentError, "tool call must be a map, got: #{inspect(tool_call)}"
  end

  defp run_tool_with_timeout(tool, input, opts, tool_timeout_ms) do
    task = Task.async(fn -> tool.run(input, opts) end)

    case Task.yield(task, tool_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        raise RuntimeError, "tool #{inspect(tool)} timed out after #{tool_timeout_ms}ms"
    end
  end

  defp validate_unique_tool_call_ids!(tool_calls) do
    ids =
      Enum.map(tool_calls, fn
        tool_call when is_map(tool_call) -> fetch_tool_call_field!(tool_call, :id)
        tool_call -> raise ArgumentError, "tool call must be a map, got: #{inspect(tool_call)}"
      end)

    duplicates =
      ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)

    if duplicates != [] do
      raise ArgumentError, "tool call ids must be unique, duplicates: #{inspect(duplicates)}"
    end
  end

  defp fetch_tool_call_field!(tool_call, field) do
    case fetch_optional_payload_field(tool_call, field) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "tool call is missing required field: #{inspect(field)}"
    end
  end

  defp require_non_empty_binary!(value, _name) when is_binary(value) and byte_size(value) > 0 do
    :ok
  end

  defp require_non_empty_binary!(value, name) do
    raise ArgumentError, "#{name} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_tool_module!(tool) when is_atom(tool) do
    if Code.ensure_loaded?(tool) and function_exported?(tool, :run, 2) do
      :ok
    else
      raise ArgumentError,
            "tool must be a loaded module exporting run/2, got: #{inspect(tool)}"
    end
  end

  defp require_tool_module!(tool) do
    raise ArgumentError, "tool must be a module atom, got: #{inspect(tool)}"
  end

  defp require_allowed_tool!(tool, allowed_tools) do
    if tool in allowed_tools do
      :ok
    else
      raise ArgumentError, "tool #{inspect(tool)} is not in :allowed_tools"
    end
  end

  defp require_tool_input!(input) when is_map(input), do: :ok

  defp require_tool_input!(input) do
    raise ArgumentError, "tool input must be a map, got: #{inspect(input)}"
  end

  defp fetch_optional_payload_field(payload, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(payload, field) -> {:ok, Map.fetch!(payload, field)}
      Map.has_key?(payload, string_field) -> {:ok, Map.fetch!(payload, string_field)}
      true -> :error
    end
  end
end
