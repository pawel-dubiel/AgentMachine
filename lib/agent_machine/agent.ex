defmodule AgentMachine.Agent do
  @moduledoc """
  Validated agent specification.

  The required fields are intentionally strict:

  - `:id`
  - `:provider`
  - `:model`
  - `:input`
  - `:pricing`

  `:instructions` and `:metadata` are optional.
  """

  @enforce_keys [:id, :provider, :model, :input, :pricing]
  defstruct [:id, :provider, :model, :input, :instructions, :pricing, :metadata]

  @type t :: %__MODULE__{
          id: binary(),
          provider: module(),
          model: binary(),
          input: binary(),
          instructions: binary() | nil,
          pricing: map(),
          metadata: map() | nil
        }

  @required_fields [:id, :provider, :model, :input, :pricing]

  def new!(%__MODULE__{} = agent) do
    validate!(agent)
  end

  def new!(attrs) when is_map(attrs) do
    attrs
    |> atomize_keys!()
    |> require_fields!()
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  def new!(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new!()
  end

  def new!(attrs) do
    raise ArgumentError, "agent spec must be a map or keyword list, got: #{inspect(attrs)}"
  end

  defp atomize_keys!(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, _value}, _acc ->
        raise ArgumentError, "agent spec keys must be atoms, got key: #{inspect(key)}"
    end)
  end

  defp require_fields!(attrs) do
    missing = Enum.reject(@required_fields, &Map.has_key?(attrs, &1))

    case missing do
      [] -> attrs
      fields -> raise ArgumentError, "agent spec is missing required field(s): #{inspect(fields)}"
    end
  end

  defp validate!(%__MODULE__{} = agent) do
    require_non_empty_binary!(agent.id, :id)
    require_module!(agent.provider, :provider)
    require_non_empty_binary!(agent.model, :model)
    require_non_empty_binary!(agent.input, :input)
    require_optional_binary!(agent.instructions, :instructions)
    require_optional_map!(agent.metadata, :metadata)
    AgentMachine.Pricing.validate!(agent.pricing)
    agent
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0 do
    :ok
  end

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "agent #{inspect(field)} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_module!(value, field) when is_atom(value) do
    if Code.ensure_loaded?(value) and function_exported?(value, :complete, 2) do
      :ok
    else
      raise ArgumentError,
            "agent #{inspect(field)} must be a loaded provider module exporting complete/2, got: #{inspect(value)}"
    end
  end

  defp require_module!(value, field) do
    raise ArgumentError, "agent #{inspect(field)} must be a module atom, got: #{inspect(value)}"
  end

  defp require_optional_binary!(nil, _field), do: :ok

  defp require_optional_binary!(value, _field) when is_binary(value) and byte_size(value) > 0 do
    :ok
  end

  defp require_optional_binary!(value, field) do
    raise ArgumentError,
          "agent #{inspect(field)} must be nil or a non-empty binary, got: #{inspect(value)}"
  end

  defp require_optional_map!(nil, _field), do: :ok
  defp require_optional_map!(value, _field) when is_map(value), do: :ok

  defp require_optional_map!(value, field) do
    raise ArgumentError, "agent #{inspect(field)} must be nil or a map, got: #{inspect(value)}"
  end
end
