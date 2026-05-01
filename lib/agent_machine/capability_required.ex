defmodule AgentMachine.CapabilityRequired do
  @moduledoc """
  Structured fail-fast error for runtime capability requirements.
  """

  defexception [
    :reason,
    :intent,
    :required_harness,
    :required_harnesses,
    :required_approval_modes,
    :required_mcp_tool,
    :requested_root,
    :detail,
    :message
  ]

  @type t :: %__MODULE__{
          reason: atom(),
          intent: atom(),
          required_harness: atom() | nil,
          required_harnesses: [atom()] | nil,
          required_approval_modes: [atom()] | nil,
          required_mcp_tool: binary() | nil,
          requested_root: binary() | nil,
          detail: binary() | nil,
          message: binary()
        }

  def exception(attrs) when is_list(attrs) do
    attrs = Map.new(attrs)
    reason = required_atom!(attrs, :reason)
    intent = required_atom!(attrs, :intent)

    %__MODULE__{
      reason: reason,
      intent: intent,
      required_harness: optional_atom!(attrs, :required_harness),
      required_harnesses: optional_atom_list!(attrs, :required_harnesses),
      required_approval_modes: optional_atom_list!(attrs, :required_approval_modes),
      required_mcp_tool: optional_binary!(attrs, :required_mcp_tool),
      requested_root: optional_binary!(attrs, :requested_root),
      detail: optional_binary!(attrs, :detail),
      message: Map.get(attrs, :message) || message_for(reason, attrs)
    }
  end

  def to_map(%__MODULE__{} = error) do
    %{
      reason: Atom.to_string(error.reason),
      intent: Atom.to_string(error.intent),
      message: error.message,
      required_harness: harness_name(error.required_harness),
      required_harnesses: names(error.required_harnesses, &harness_name/1),
      required_approval_modes: names(error.required_approval_modes, &approval_name/1),
      required_mcp_tool: error.required_mcp_tool,
      requested_root: error.requested_root,
      detail: error.detail
    }
    |> drop_empty()
  end

  def event(%__MODULE__{} = error) do
    error
    |> to_map()
    |> Map.put(:type, :capability_required)
  end

  defp required_atom!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "capability requirement #{inspect(key)} must be an atom, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "capability requirement is missing #{inspect(key)}"
    end
  end

  defp optional_atom!(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        nil

      value when is_atom(value) ->
        value

      value ->
        raise ArgumentError,
              "capability requirement #{inspect(key)} must be an atom, got: #{inspect(value)}"
    end
  end

  defp optional_atom_list!(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        nil

      values when is_list(values) ->
        Enum.map(values, fn
          value when is_atom(value) and not is_nil(value) ->
            value

          value ->
            raise ArgumentError,
                  "capability requirement #{inspect(key)} must contain atoms, got: #{inspect(value)}"
        end)

      value ->
        raise ArgumentError,
              "capability requirement #{inspect(key)} must be a list, got: #{inspect(value)}"
    end
  end

  defp optional_binary!(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        nil

      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError,
              "capability requirement #{inspect(key)} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp message_for(:missing_read_harness, _attrs),
    do:
      "auto workflow detected local read/search intent but no read-capable tool harness is configured"

  defp message_for(:missing_tool_harness, _attrs),
    do: "auto workflow detected tool intent but no tool harness is configured"

  defp message_for(:missing_read_only_tool_capability, attrs) do
    detail = Map.get(attrs, :detail)
    suffix = if is_binary(detail), do: ": #{detail}", else: ""
    "auto workflow detected tool intent but no read-only tool capability is configured" <> suffix
  end

  defp message_for(:missing_write_harness, _attrs),
    do: "auto workflow detected mutation intent but no write-capable tool harness is configured"

  defp message_for(:missing_code_edit_harness, _attrs),
    do:
      "auto workflow detected code mutation intent but :code_edit tool harness is not configured"

  defp message_for(:missing_test_code_edit_harness, _attrs),
    do: "auto workflow detected test intent but :code_edit tool harness is not configured"

  defp message_for(:missing_test_approval, _attrs),
    do:
      "auto workflow detected test intent but :tool_approval_mode must be :full_access or :ask_before_write with permission control"

  defp message_for(:missing_test_commands, _attrs),
    do: "auto workflow detected test intent but no allowlisted :test_commands are configured"

  defp message_for(:missing_browser_mcp, _attrs),
    do: "auto workflow detected web browse intent but no MCP browser network tool is configured"

  defp message_for(:missing_browser_approval, _attrs),
    do:
      "auto workflow detected web browse intent but :tool_approval_mode must be :full_access or :ask_before_write with permission control for network-risk MCP browser tools"

  defp message_for(reason, _attrs), do: "runtime capability required: #{inspect(reason)}"

  defp names(nil, _fun), do: nil
  defp names(values, fun), do: Enum.map(values, fun)

  defp harness_name(nil), do: nil
  defp harness_name(:local_files), do: "local-files"
  defp harness_name(:code_edit), do: "code-edit"
  defp harness_name(harness) when is_atom(harness), do: Atom.to_string(harness)

  defp approval_name(:read_only), do: "read-only"
  defp approval_name(:ask_before_write), do: "ask-before-write"
  defp approval_name(:auto_approved_safe), do: "auto-approved-safe"
  defp approval_name(:full_access), do: "full-access"
  defp approval_name(mode) when is_atom(mode), do: Atom.to_string(mode)

  defp drop_empty(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, ""} -> true
      _entry -> false
    end)
  end
end
