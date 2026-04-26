defmodule AgentMachine.Secrets.Redactor do
  @moduledoc """
  Central redaction helpers for values that leave the runtime boundary.

  This is intentionally pattern-based and conservative. It protects common
  accidental leaks in logs, summaries, events, and read-tool output without
  changing raw execution inputs.
  """

  @redaction_key :redaction

  @typedoc false
  @type result :: %{
          value: term(),
          redacted: boolean(),
          count: non_neg_integer(),
          reasons: [String.t()]
        }

  @doc """
  Redacts a single string and returns metadata about what changed.
  """
  def redact_string(text) when is_binary(text) do
    {value, count, reasons} =
      Enum.reduce(patterns(), {text, 0, MapSet.new()}, fn pattern, {current, count, reasons} ->
        {redacted, matches, reason} = apply_pattern(current, pattern)
        {redacted, count + matches, maybe_put_reason(reasons, matches, reason)}
      end)

    %{
      value: value,
      redacted: count > 0,
      count: count,
      reasons: reasons |> MapSet.to_list() |> Enum.sort()
    }
  end

  @doc """
  Redacts a JSON-serializable value and adds top-level redaction metadata when
  anything changed.
  """
  def redact_output(value) do
    result = redact_value(value)

    %{
      result
      | value: maybe_attach_metadata(result.value, result.count, result.reasons)
    }
  end

  @doc """
  Redacts a JSON-serializable value without adding metadata.
  """
  def redact_value(value) do
    do_redact_value(value)
  end

  @doc """
  Adds common redaction fields to a tool result map when string redaction
  happened inside that tool's returned content.
  """
  def put_tool_metadata(map, %{redacted: false}) when is_map(map), do: map

  def put_tool_metadata(map, %{redacted: true, count: count, reasons: reasons})
      when is_map(map) do
    map
    |> Map.put(:redacted, true)
    |> Map.put(:redaction_count, count)
    |> Map.put(:redaction_reasons, reasons)
  end

  defp do_redact_value(text) when is_binary(text), do: redact_string(text)

  defp do_redact_value(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value) do
    unchanged(value)
  end

  defp do_redact_value(%DateTime{} = value), do: unchanged(value)

  defp do_redact_value(value) when is_list(value) do
    value
    |> Enum.map(&do_redact_value/1)
    |> combine_collection()
  end

  defp do_redact_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} ->
      result = do_redact_value(item)
      {{key, result.value}, result}
    end)
    |> combine_map()
  end

  defp do_redact_value(value), do: unchanged(value)

  defp combine_collection(results) do
    %{
      value: Enum.map(results, & &1.value),
      redacted: Enum.any?(results, & &1.redacted),
      count: Enum.reduce(results, 0, &(&1.count + &2)),
      reasons: merge_reasons(results)
    }
  end

  defp combine_map(results) do
    %{
      value:
        Map.new(results, fn {{key, value}, _result} ->
          {key, value}
        end),
      redacted: Enum.any?(results, fn {_entry, result} -> result.redacted end),
      count: Enum.reduce(results, 0, fn {_entry, result}, count -> result.count + count end),
      reasons: merge_reasons(Enum.map(results, fn {_entry, result} -> result end))
    }
  end

  defp merge_reasons(results) do
    results
    |> Enum.flat_map(& &1.reasons)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_attach_metadata(value, 0, _reasons), do: value

  defp maybe_attach_metadata(value, count, reasons) when is_map(value) do
    Map.put(value, @redaction_key, %{redacted: true, count: count, reasons: reasons})
  end

  defp maybe_attach_metadata(value, count, reasons) do
    %{
      value: value,
      redaction: %{redacted: true, count: count, reasons: reasons}
    }
  end

  defp unchanged(value), do: %{value: value, redacted: false, count: 0, reasons: []}

  defp maybe_put_reason(reasons, 0, _reason), do: reasons
  defp maybe_put_reason(reasons, _count, reason), do: MapSet.put(reasons, Atom.to_string(reason))

  defp apply_pattern(text, {reason, regex, :whole}) do
    matches = match_count(regex, text)
    {Regex.replace(regex, text, "[REDACTED:#{reason}]"), matches, reason}
  end

  defp apply_pattern(text, {reason, regex, :keep_prefix}) do
    matches = match_count(regex, text)
    {Regex.replace(regex, text, "\\1[REDACTED:#{reason}]"), matches, reason}
  end

  defp apply_pattern(text, {reason, regex, :keep_optional_quotes}) do
    matches = match_count(regex, text)
    {Regex.replace(regex, text, "\\1\\2[REDACTED:#{reason}]\\2"), matches, reason}
  end

  defp apply_pattern(text, {reason, regex, :keep_suffix}) do
    matches = match_count(regex, text)
    {Regex.replace(regex, text, "\\1[REDACTED:#{reason}]\\3"), matches, reason}
  end

  defp match_count(regex, text), do: regex |> Regex.scan(text) |> length()

  defp patterns do
    [
      {:private_key, ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s,
       :whole},
      {:authorization_header, ~r/(?im)(\bauthorization\s*:\s*(?:bearer|basic)\s+)([^\s]+)/,
       :keep_prefix},
      {:bearer_token, ~r/(?i)(\bbearer\s+)([A-Za-z0-9._~+\/=-]{12,})/, :keep_prefix},
      {:secret_assignment,
       ~r/(?im)^(\s*[A-Z0-9_.-]*(?:SECRET|TOKEN|PASSWORD|PASS|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY)[A-Z0-9_.-]*\s*[:=]\s*)(["']?)([^"'\s#]+)(?:\2)/,
       :keep_optional_quotes},
      {:json_secret_field,
       ~r/(?i)("[^"]*(?:secret|token|password|api[_-]?key|access[_-]?key|private[_-]?key)[^"]*"\s*:\s*")([^"]+)(")/,
       :keep_suffix},
      {:openai_api_key, ~r/\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/, :whole},
      {:github_token, ~r/\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,})\b/,
       :whole},
      {:aws_access_key_id, ~r/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/, :whole}
    ]
  end
end
