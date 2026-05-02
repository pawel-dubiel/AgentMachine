defmodule AgentMachine.SessionTranscript do
  @moduledoc """
  JSONL persistence for session context and per-agent sidechain transcripts.
  """

  alias AgentMachine.{JSON, Secrets.Redactor}

  @safe_segment_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @record_types MapSet.new([
                  "metadata",
                  "user_message",
                  "assistant_message",
                  "tool_call",
                  "tool_result",
                  "summary",
                  "notification",
                  "error"
                ])

  def session_context_path(session_dir, session_id) do
    Path.join(session_root!(session_dir, session_id), "context.jsonl")
  end

  def agent_path(session_dir, session_id, agent_id) do
    root = session_root!(session_dir, session_id)
    agent_id = validate_agent_id!(agent_id)
    path = Path.join([root, "agents", agent_id <> ".jsonl"])
    ensure_inside!(path, root, "agent transcript path")
  end

  def validate_session_id!(session_id), do: safe_segment!(session_id, "session_id")

  def validate_agent_id!(agent_id), do: safe_segment!(agent_id, "agent_id")

  def validate_session_dir!(session_dir) do
    session_dir
    |> require_non_empty_binary!("session_dir")
    |> Path.expand()
  end

  def append_session!(session_dir, session_id, record) when is_map(record) do
    append_path!(session_context_path(session_dir, session_id), record)
  end

  def append_agent!(session_dir, session_id, agent_id, record)
      when is_binary(agent_id) and is_map(record) do
    append_path!(agent_path(session_dir, session_id, agent_id), record)
  end

  def load_agent!(session_dir, session_id, agent_id) when is_binary(agent_id) do
    load_path!(agent_path(session_dir, session_id, agent_id))
  end

  def tail_agent!(session_dir, session_id, agent_id, limit)
      when is_binary(agent_id) and is_integer(limit) and limit > 0 do
    session_dir
    |> load_agent!(session_id, agent_id)
    |> Enum.take(-limit)
  end

  def tail_agent!(_session_dir, _session_id, _agent_id, limit) do
    raise ArgumentError,
          "transcript tail limit must be a positive integer, got: #{inspect(limit)}"
  end

  def load_path!(path) when is_binary(path) do
    case File.read(path) do
      {:ok, ""} ->
        []

      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.map(fn {line, line_no} -> decode_record!(path, line, line_no) end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise ArgumentError, "failed to read transcript #{inspect(path)}: #{inspect(reason)}"
    end
  end

  def bounded_text(records, max_bytes)
      when is_list(records) and is_integer(max_bytes) and max_bytes > 0 do
    records
    |> JSON.encode!()
    |> binary_part(0, min(byte_size(JSON.encode!(records)), max_bytes))
  end

  defp append_path!(path, record) do
    record = normalize_record!(record)
    File.mkdir_p!(Path.dirname(path))

    line =
      record
      |> Redactor.redact_output()
      |> Map.fetch!(:value)
      |> JSON.encode!()

    File.write!(path, [line, ?\n], [:append])
    :ok
  end

  defp decode_record!(path, line, line_no) do
    record = JSON.decode!(line)

    unless is_map(record) do
      raise ArgumentError,
            "invalid transcript #{inspect(path)} line #{line_no}: JSONL record must be an object"
    end

    normalize_record!(record)
  rescue
    exception in ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "invalid transcript #{inspect(path)} line #{line_no}: #{Exception.message(exception)}"
              ],
              __STACKTRACE__
  end

  defp normalize_record!(record) when is_map(record) do
    type = require_non_empty_binary!(Map.get(record, "type") || Map.get(record, :type), "type")

    unless MapSet.member?(@record_types, type) do
      raise ArgumentError, "unsupported transcript record type #{inspect(type)}"
    end

    at = Map.get(record, "at") || Map.get(record, :at) || DateTime.utc_now()

    record
    |> stringify_keys()
    |> Map.put("type", type)
    |> Map.put("at", normalize_time!(at))
  end

  defp normalize_record!(record) do
    raise ArgumentError, "transcript record must be a map, got: #{inspect(record)}"
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_binary(key) ->
        {key, value}

      {key, _value} ->
        raise ArgumentError, "transcript record key must be atom or string, got: #{inspect(key)}"
    end)
  end

  defp session_root!(session_dir, session_id) do
    session_dir = validate_session_dir!(session_dir)

    root =
      session_dir
      |> Path.join(validate_session_id!(session_id))
      |> Path.expand()

    ensure_inside!(root, session_dir, "session root")
  end

  defp normalize_time!(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp normalize_time!(time) when is_binary(time) and byte_size(time) > 0, do: time

  defp normalize_time!(time) do
    raise ArgumentError,
          "transcript record at must be a DateTime or non-empty string, got: #{inspect(time)}"
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError, "transcript #{field} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp safe_segment!(value, field) do
    value = require_non_empty_binary!(value, field)

    if Regex.match?(@safe_segment_pattern, value) do
      value
    else
      raise ArgumentError,
            "transcript #{field} must be a safe path segment containing only letters, numbers, ., _ or -, got: #{inspect(value)}"
    end
  end

  defp ensure_inside!(path, root, label) do
    path = Path.expand(path)
    root = Path.expand(root)

    if path == root or String.starts_with?(path, root <> "/") do
      path
    else
      raise ArgumentError,
            "transcript #{label} escaped configured session directory: #{inspect(path)}"
    end
  end
end
