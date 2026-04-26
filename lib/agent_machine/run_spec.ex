defmodule AgentMachine.RunSpec do
  @moduledoc """
  High-level run request used by clients.
  """

  @enforce_keys [:task, :workflow, :provider, :timeout_ms, :max_steps, :max_attempts]
  defstruct [
    :task,
    :workflow,
    :provider,
    :model,
    :timeout_ms,
    :max_steps,
    :max_attempts,
    :http_timeout_ms,
    :pricing,
    :tool_harness,
    :tool_timeout_ms,
    :tool_max_rounds,
    :tool_root,
    :tool_approval_mode
  ]

  @type t :: %__MODULE__{
          task: binary(),
          workflow: :basic | :agentic,
          provider: :echo | :openai | :openrouter,
          model: binary() | nil,
          timeout_ms: pos_integer(),
          max_steps: pos_integer(),
          max_attempts: pos_integer(),
          http_timeout_ms: pos_integer() | nil,
          pricing: map() | nil,
          tool_harness: :demo | :local_files | :code_edit | nil,
          tool_timeout_ms: pos_integer() | nil,
          tool_max_rounds: pos_integer() | nil,
          tool_root: binary() | nil,
          tool_approval_mode:
            :read_only | :ask_before_write | :auto_approved_safe | :full_access | nil
        }

  def new!(attrs) when is_map(attrs) do
    attrs
    |> atomize_keys!()
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  def new!(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new!()
  end

  def new!(attrs) do
    raise ArgumentError, "run spec must be a map or keyword list, got: #{inspect(attrs)}"
  end

  defp validate!(%__MODULE__{} = spec) do
    require_non_empty_binary!(spec.task, :task)
    require_workflow!(spec.workflow)
    require_provider!(spec.provider)
    require_positive_integer!(spec.timeout_ms, :timeout_ms)
    require_positive_integer!(spec.max_steps, :max_steps)
    require_positive_integer!(spec.max_attempts, :max_attempts)
    validate_provider_options!(spec)
    validate_tool_options!(spec)
    spec
  end

  defp validate_provider_options!(%__MODULE__{provider: :echo}), do: :ok

  defp validate_provider_options!(%__MODULE__{provider: provider} = spec)
       when provider in [:openai, :openrouter] do
    require_non_empty_binary!(spec.model, :model)
    require_positive_integer!(spec.http_timeout_ms, :http_timeout_ms)
    AgentMachine.Pricing.validate!(spec.pricing)
  end

  defp atomize_keys!(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, _value}, _acc ->
        raise ArgumentError, "run spec keys must be atoms, got key: #{inspect(key)}"
    end)
  end

  defp require_workflow!(workflow) when workflow in [:basic, :agentic], do: :ok

  defp require_workflow!(workflow) do
    raise ArgumentError,
          "run spec :workflow must be :basic or :agentic, got: #{inspect(workflow)}"
  end

  defp require_provider!(provider) when provider in [:echo, :openai, :openrouter], do: :ok

  defp require_provider!(provider) do
    raise ArgumentError,
          "run spec :provider must be :echo, :openai, or :openrouter, got: #{inspect(provider)}"
  end

  defp validate_tool_options!(%__MODULE__{
         tool_harness: nil,
         tool_timeout_ms: nil,
         tool_max_rounds: nil,
         tool_root: nil,
         tool_approval_mode: nil
       }),
       do: :ok

  defp validate_tool_options!(%__MODULE__{tool_harness: nil} = spec) do
    raise ArgumentError,
          "run spec tool options require :tool_harness, got :tool_timeout_ms #{inspect(spec.tool_timeout_ms)}, :tool_max_rounds #{inspect(spec.tool_max_rounds)}, and :tool_root #{inspect(spec.tool_root)}"
  end

  defp validate_tool_options!(%__MODULE__{
         tool_harness: :demo,
         tool_timeout_ms: timeout_ms,
         tool_max_rounds: max_rounds,
         tool_approval_mode: approval_mode
       }) do
    require_positive_integer!(timeout_ms, :tool_timeout_ms)
    require_positive_integer!(max_rounds, :tool_max_rounds)
    require_tool_approval_mode!(approval_mode)
  end

  defp validate_tool_options!(%__MODULE__{
         tool_harness: harness,
         tool_timeout_ms: timeout_ms,
         tool_max_rounds: max_rounds,
         tool_root: root,
         tool_approval_mode: approval_mode
       })
       when harness in [:local_files, :code_edit] do
    require_positive_integer!(timeout_ms, :tool_timeout_ms)
    require_positive_integer!(max_rounds, :tool_max_rounds)
    require_non_empty_binary!(root, :tool_root)
    require_tool_approval_mode!(approval_mode)
  end

  defp validate_tool_options!(%__MODULE__{tool_harness: harness}) do
    raise ArgumentError,
          "run spec :tool_harness must be :demo, :local_files, or :code_edit, got: #{inspect(harness)}"
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0 do
    :ok
  end

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "run spec #{inspect(field)} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_positive_integer!(value, _field) when is_integer(value) and value > 0 do
    :ok
  end

  defp require_positive_integer!(value, field) do
    raise ArgumentError,
          "run spec #{inspect(field)} must be a positive integer, got: #{inspect(value)}"
  end

  defp require_tool_approval_mode!(mode)
       when mode in [:read_only, :ask_before_write, :auto_approved_safe, :full_access],
       do: :ok

  defp require_tool_approval_mode!(mode) do
    raise ArgumentError,
          "run spec :tool_approval_mode must be :read_only, :ask_before_write, :auto_approved_safe, or :full_access, got: #{inspect(mode)}"
  end
end
