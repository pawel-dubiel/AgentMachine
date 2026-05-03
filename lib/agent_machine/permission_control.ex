defmodule AgentMachine.PermissionControl do
  @moduledoc """
  Routes interactive runtime decisions for a running CLI/TUI session.

  The runtime remains responsible for deciding what a request means and for
  emitting audit events. This process only owns pending request correlation and
  the JSONL control input stream.
  """

  use GenServer

  alias AgentMachine.JSON

  @type decision ::
          {:approved, binary()}
          | {:denied, binary()}
          | {:revision_requested, binary()}
          | {:cancelled, binary()}

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def request(pid, context) when is_pid(pid) and is_map(context) do
    GenServer.call(pid, {:request, context}, :infinity)
  end

  def cancel_all(pid, reason) when is_pid(pid) and is_binary(reason) do
    GenServer.call(pid, {:cancel_all, reason})
  end

  def decide(pid, line) when is_pid(pid) and is_binary(line) do
    send(pid, {:permission_control_line, line})
    :ok
  end

  def parse_decision!(line) when is_binary(line) do
    line
    |> JSON.decode!()
    |> decision_from_payload!()
  end

  @impl true
  def init(opts) do
    input = Keyword.get(opts, :input, :stdio)

    if input == false do
      {:ok, %{pending: %{}, reader_ref: nil, reader_pid: nil, closed_reason: nil}}
    else
      owner = self()

      reader =
        Task.async(fn ->
          read_loop(input, owner)
        end)

      {:ok, %{pending: %{}, reader_ref: reader.ref, reader_pid: reader.pid, closed_reason: nil}}
    end
  end

  @impl true
  def handle_call({:request, context}, from, state) do
    request_id = Map.fetch!(context, :request_id)

    cond do
      is_binary(state.closed_reason) ->
        {:reply, {:cancelled, state.closed_reason}, state}

      Map.has_key?(state.pending, request_id) ->
        {:reply, {:denied, "duplicate permission request_id #{inspect(request_id)}"}, state}

      true ->
        {:noreply, %{state | pending: Map.put(state.pending, request_id, from)}}
    end
  end

  def handle_call({:cancel_all, reason}, _from, state) do
    state = close_control(state, reason)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:permission_control_line, line}, state) do
    case parse_decision(line) do
      {:ok, request_id, decision} ->
        case Map.pop(state.pending, request_id) do
          {nil, pending} ->
            reason = "permission decision referenced unknown request_id #{inspect(request_id)}"
            {:noreply, close_control(%{state | pending: pending}, reason)}

          {from, pending} ->
            GenServer.reply(from, decision)
            {:noreply, %{state | pending: pending}}
        end

      {:error, reason} ->
        {:noreply, close_control(state, reason)}
    end
  end

  def handle_info({:permission_control_closed, reason}, state) do
    {:noreply, close_control(state, reason)}
  end

  def handle_info({ref, _result}, %{reader_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, close_control(state, "permission control input closed")}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reader_ref: ref} = state)
      when is_reference(ref) do
    {:noreply, close_control(state, "permission control reader exited: #{inspect(reason)}")}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp read_loop(input, owner) do
    case IO.read(input, :line) do
      data when is_binary(data) ->
        send(owner, {:permission_control_line, String.trim_trailing(data)})
        read_loop(input, owner)

      :eof ->
        send(owner, {:permission_control_closed, "permission control input reached EOF"})

      {:error, reason} ->
        send(
          owner,
          {:permission_control_closed, "permission control input failed: #{inspect(reason)}"}
        )
    end
  end

  defp parse_decision(line) do
    {request_id, decision} = decision_from_payload!(JSON.decode!(line))
    {:ok, request_id, decision}
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
    exception in KeyError -> {:error, Exception.message(exception)}
  end

  defp decision_from_payload!(%{"type" => "permission_decision"} = payload) do
    request_id = require_non_empty_binary!(Map.get(payload, "request_id"), "request_id")
    reason = Map.get(payload, "reason", "")

    decision =
      case Map.get(payload, "decision") do
        "approve" ->
          {:approved, reason}

        "deny" ->
          {:denied, reason}

        other ->
          raise ArgumentError,
                "permission decision must be approve or deny, got: #{inspect(other)}"
      end

    {request_id, decision}
  end

  defp decision_from_payload!(%{"type" => "planner_review_decision"} = payload) do
    request_id = require_non_empty_binary!(Map.get(payload, "request_id"), "request_id")
    reason = Map.get(payload, "reason", "")

    decision =
      case Map.get(payload, "decision") do
        "approve" ->
          {:approved, reason}

        "decline" ->
          {:denied, reason}

        "deny" ->
          {:denied, reason}

        "revise" ->
          feedback = require_non_empty_binary!(Map.get(payload, "feedback"), "feedback")
          {:revision_requested, feedback}

        other ->
          raise ArgumentError,
                "planner review decision must be approve, decline, or revise, got: #{inspect(other)}"
      end

    {request_id, decision}
  end

  defp decision_from_payload!(payload) do
    raise ArgumentError,
          "permission control input must be a permission_decision or planner_review_decision object, got: #{inspect(payload)}"
  end

  defp reply_all(state, decision) do
    Enum.each(state.pending, fn {_request_id, from} -> GenServer.reply(from, decision) end)
    %{state | pending: %{}}
  end

  defp close_control(state, reason) do
    state
    |> reply_all({:cancelled, reason})
    |> Map.put(:closed_reason, reason)
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "permission decision #{field} must be a non-empty binary, got: #{inspect(value)}"
  end
end
