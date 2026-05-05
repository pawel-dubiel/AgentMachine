defmodule AgentMachine.SessionProtocol do
  @moduledoc """
  Parser and encoder for the session daemon JSONL protocol.
  """

  alias AgentMachine.JSON

  @run_keys %{
    "task" => :task,
    "recent_context" => :recent_context,
    "pending_action" => :pending_action,
    "workflow" => :workflow,
    "provider" => :provider,
    "provider_options" => :provider_options,
    "log_file" => :log_file,
    "model" => :model,
    "timeout_ms" => :timeout_ms,
    "max_steps" => :max_steps,
    "max_attempts" => :max_attempts,
    "agentic_persistence_rounds" => :agentic_persistence_rounds,
    "planner_review_mode" => :planner_review_mode,
    "planner_review_max_revisions" => :planner_review_max_revisions,
    "http_timeout_ms" => :http_timeout_ms,
    "pricing" => :pricing,
    "tool_harness" => :tool_harness,
    "tool_harnesses" => :tool_harnesses,
    "tool_timeout_ms" => :tool_timeout_ms,
    "tool_max_rounds" => :tool_max_rounds,
    "tool_root" => :tool_root,
    "tool_approval_mode" => :tool_approval_mode,
    "test_commands" => :test_commands,
    "mcp_config_path" => :mcp_config_path,
    "skills_mode" => :skills_mode,
    "skills_dir" => :skills_dir,
    "skill_names" => :skill_names,
    "allow_skill_scripts" => :allow_skill_scripts,
    "stream_response" => :stream_response,
    "progress_observer" => :progress_observer,
    "context_window_tokens" => :context_window_tokens,
    "context_warning_percent" => :context_warning_percent,
    "context_tokenizer_path" => :context_tokenizer_path,
    "reserved_output_tokens" => :reserved_output_tokens,
    "run_context_compaction" => :run_context_compaction,
    "run_context_compact_percent" => :run_context_compact_percent,
    "max_context_compactions" => :max_context_compactions,
    "router_mode" => :router_mode,
    "router_model_dir" => :router_model_dir,
    "router_timeout_ms" => :router_timeout_ms,
    "router_confidence_threshold" => :router_confidence_threshold,
    "session_tool_timeout_ms" => :session_tool_timeout_ms,
    "session_tool_max_rounds" => :session_tool_max_rounds
  }

  @workflow_values %{"agentic" => :agentic}
  @harness_values %{
    "demo" => :demo,
    "time" => :time,
    "local-files" => :local_files,
    "local_files" => :local_files,
    "code-edit" => :code_edit,
    "code_edit" => :code_edit,
    "mcp" => :mcp,
    "skills" => :skills
  }

  @approval_values %{
    "read-only" => :read_only,
    "read_only" => :read_only,
    "ask-before-write" => :ask_before_write,
    "ask_before_write" => :ask_before_write,
    "auto-approved-safe" => :auto_approved_safe,
    "auto_approved_safe" => :auto_approved_safe,
    "full-access" => :full_access,
    "full_access" => :full_access
  }

  @skills_mode_values %{"off" => :off, "auto" => :auto}
  @compaction_values %{"off" => :off, "on" => :on}
  @router_values %{"deterministic" => :deterministic, "llm" => :llm, "local" => :local}
  @planner_review_values %{"prompt" => :prompt, "jsonl-stdio" => :jsonl_stdio}

  def parse_command!(line) when is_binary(line) do
    payload = JSON.decode!(line)
    require_map!(payload, "session command")

    case require_non_empty_binary!(Map.get(payload, "type"), "type") do
      "user_message" ->
        run = require_map_value!(Map.get(payload, "run"), "run")

        %{
          type: :user_message,
          message_id: require_non_empty_binary!(Map.get(payload, "message_id"), "message_id"),
          run: run_attrs_from_payload!(run),
          log_file: log_file_from_payload!(run),
          session_tool_opts: session_tool_opts_from_payload!(run)
        }

      "permission_decision" ->
        %{type: :permission_decision, line: line}

      "planner_review_decision" ->
        %{type: :planner_review_decision, line: line}

      "send_agent_message" ->
        %{
          type: :send_agent_message,
          message_id: require_non_empty_binary!(Map.get(payload, "message_id"), "message_id"),
          agent_ref: agent_ref_from_payload!(payload),
          content: require_non_empty_binary!(Map.get(payload, "content"), "content"),
          resume: Map.get(payload, "resume", false)
        }

      "read_agent_output" ->
        %{
          type: :read_agent_output,
          request_id: require_non_empty_binary!(Map.get(payload, "request_id"), "request_id"),
          agent_ref: agent_ref_from_payload!(payload),
          limit: positive_integer!(Map.get(payload, "limit", 20), "limit")
        }

      "cancel_agent" ->
        %{
          type: :cancel_agent,
          request_id: require_non_empty_binary!(Map.get(payload, "request_id"), "request_id"),
          agent_ref: agent_ref_from_payload!(payload),
          reason: Map.get(payload, "reason", "cancelled")
        }

      "shutdown" ->
        %{type: :shutdown, reason: Map.get(payload, "reason", "shutdown requested")}

      other ->
        raise ArgumentError, "unsupported session command type: #{inspect(other)}"
    end
  end

  def parse_command!(value) do
    raise ArgumentError, "session command must be a JSON line, got: #{inspect(value)}"
  end

  def run_attrs_from_payload!(payload) do
    require_map!(payload, "run")
    reject_unknown_keys!(payload, @run_keys, "run")

    payload
    |> Map.new(fn {key, value} -> {Map.fetch!(@run_keys, key), value} end)
    |> normalize_run_attrs!()
    |> Map.drop([:log_file, :session_tool_timeout_ms, :session_tool_max_rounds])
  end

  defp log_file_from_payload!(payload) do
    case Map.fetch(payload, "log_file") do
      {:ok, value} -> require_non_empty_binary!(value, "log_file")
      :error -> nil
    end
  end

  def session_tool_opts_from_payload!(payload) do
    require_map!(payload, "run")

    %{
      timeout_ms:
        positive_integer!(Map.get(payload, "session_tool_timeout_ms"), "session_tool_timeout_ms"),
      max_rounds:
        positive_integer!(Map.get(payload, "session_tool_max_rounds"), "session_tool_max_rounds")
    }
  end

  def event_line!(event), do: AgentMachine.ClientRunner.jsonl_event!(event)
  def summary_line!(summary), do: AgentMachine.ClientRunner.jsonl_summary!(summary)

  def response_line!(payload) when is_map(payload) do
    payload
    |> stringify_atom_keys()
    |> JSON.encode!()
  end

  defp normalize_run_attrs!(attrs) do
    attrs
    |> normalize_optional_atom_value!(:workflow, @workflow_values)
    |> Map.put_new(:workflow, :agentic)
    |> normalize_provider!()
    |> normalize_optional_atom_value!(:tool_harness, @harness_values)
    |> normalize_optional_atom_list!(:tool_harnesses, @harness_values)
    |> normalize_optional_atom_value!(:tool_approval_mode, @approval_values)
    |> normalize_optional_atom_value!(:skills_mode, @skills_mode_values)
    |> normalize_optional_atom_value!(:run_context_compaction, @compaction_values)
    |> normalize_optional_atom_value!(:router_mode, @router_values)
    |> normalize_optional_atom_value!(:planner_review_mode, @planner_review_values)
    |> normalize_optional_context_field!(:recent_context)
    |> normalize_optional_context_field!(:pending_action)
    |> normalize_pricing!()
    |> normalize_provider_options!()
  end

  defp normalize_provider!(attrs) do
    Map.update!(attrs, :provider, fn
      "echo" ->
        :echo

      provider when is_binary(provider) ->
        AgentMachine.ProviderCatalog.fetch!(provider)
        provider

      provider ->
        raise ArgumentError, "run :provider must be a string, got: #{inspect(provider)}"
    end)
  end

  defp normalize_optional_context_field!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, nil} ->
        Map.delete(attrs, key)

      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          raise ArgumentError,
                "run #{inspect(key)} must be a non-empty string when supplied, got: #{inspect(value)}"
        end

        Map.put(attrs, key, trimmed)

      {:ok, value} ->
        raise ArgumentError,
              "run #{inspect(key)} must be a non-empty string when supplied, got: #{inspect(value)}"

      :error ->
        attrs
    end
  end

  defp normalize_optional_atom_value!(attrs, key, values) do
    case Map.fetch(attrs, key) do
      {:ok, nil} -> attrs
      {:ok, ""} -> Map.delete(attrs, key)
      {:ok, value} -> Map.put(attrs, key, lookup_atom!(value, values, key))
      :error -> attrs
    end
  end

  defp normalize_optional_atom_list!(attrs, key, values) do
    case Map.fetch(attrs, key) do
      {:ok, nil} ->
        attrs

      {:ok, list} when is_list(list) ->
        Map.put(attrs, key, Enum.map(list, &lookup_atom!(&1, values, key)))

      {:ok, value} ->
        raise ArgumentError, "run #{inspect(key)} must be a list, got: #{inspect(value)}"

      :error ->
        attrs
    end
  end

  defp lookup_atom!(value, values, key) when is_binary(value) do
    case Map.fetch(values, value) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError, "unsupported run #{inspect(key)} value: #{inspect(value)}"
    end
  end

  defp lookup_atom!(value, _values, key) do
    raise ArgumentError, "run #{inspect(key)} must be a string, got: #{inspect(value)}"
  end

  defp normalize_pricing!(%{pricing: pricing} = attrs) when is_map(pricing) do
    pricing =
      Map.new(pricing, fn
        {"input_per_million", value} -> {:input_per_million, value}
        {"output_per_million", value} -> {:output_per_million, value}
        {key, value} when is_atom(key) -> {key, value}
        {key, _value} -> raise ArgumentError, "unsupported pricing key: #{inspect(key)}"
      end)

    Map.put(attrs, :pricing, pricing)
  end

  defp normalize_pricing!(attrs), do: attrs

  defp normalize_provider_options!(%{provider_options: provider_options} = attrs)
       when is_map(provider_options) do
    provider_options =
      Map.new(provider_options, fn
        {key, value} when is_binary(key) and is_binary(value) ->
          {key, value}

        {key, _value} ->
          raise ArgumentError, "unsupported provider_options entry: #{inspect(key)}"
      end)

    Map.put(attrs, :provider_options, provider_options)
  end

  defp normalize_provider_options!(%{provider_options: nil} = attrs),
    do: Map.delete(attrs, :provider_options)

  defp normalize_provider_options!(%{provider_options: provider_options}) do
    raise ArgumentError,
          "run :provider_options must be an object, got: #{inspect(provider_options)}"
  end

  defp normalize_provider_options!(attrs), do: attrs

  defp agent_ref_from_payload!(payload) do
    agent_id = Map.get(payload, "agent_id")
    name = Map.get(payload, "name")

    cond do
      is_binary(agent_id) and byte_size(agent_id) > 0 -> {:agent_id, agent_id}
      is_binary(name) and byte_size(name) > 0 -> {:name, name}
      true -> raise ArgumentError, "session command requires non-empty agent_id or name"
    end
  end

  defp reject_unknown_keys!(payload, allowed, label) do
    unknown = payload |> Map.keys() |> Enum.reject(&Map.has_key?(allowed, &1))

    if unknown != [] do
      raise ArgumentError, "#{label} contains unknown key(s): #{inspect(Enum.sort(unknown))}"
    end
  end

  defp require_map!(value, _label) when is_map(value), do: :ok

  defp require_map!(value, label) do
    raise ArgumentError, "#{label} must be an object, got: #{inspect(value)}"
  end

  defp require_map_value!(value, _label) when is_map(value), do: value

  defp require_map_value!(value, label) do
    raise ArgumentError, "#{label} must be an object, got: #{inspect(value)}"
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "session command #{field} must be a non-empty string, got: #{inspect(value)}"
  end

  defp positive_integer!(value, _field) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, field) do
    raise ArgumentError,
          "session command #{field} must be a positive integer, got: #{inspect(value)}"
  end

  defp stringify_atom_keys(value) when is_map(value) do
    Map.new(value, fn
      {key, item} when is_atom(key) -> {Atom.to_string(key), stringify_atom_keys(item)}
      {key, item} when is_binary(key) -> {key, stringify_atom_keys(item)}
      {key, item} -> {key, stringify_atom_keys(item)}
    end)
  end

  defp stringify_atom_keys(value) when is_list(value), do: Enum.map(value, &stringify_atom_keys/1)
  defp stringify_atom_keys(value), do: value
end
