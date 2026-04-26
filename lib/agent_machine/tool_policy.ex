defmodule AgentMachine.ToolPolicy do
  @moduledoc """
  Explicit permission policy for tool execution.
  """

  @enforce_keys [:permissions]
  defstruct [:harness, :permissions]

  @type t :: %__MODULE__{harness: atom() | nil, permissions: MapSet.t(atom())}

  def new!(attrs) when is_map(attrs) do
    permissions =
      attrs
      |> Map.fetch!(:permissions)
      |> permissions!()

    %__MODULE__{
      harness: Map.get(attrs, :harness),
      permissions: permissions
    }
  end

  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

  def new!(attrs) do
    raise ArgumentError, "tool policy must be a map or keyword list, got: #{inspect(attrs)}"
  end

  def permit!(%__MODULE__{} = policy, tool) do
    permission = tool_permission!(tool)

    if MapSet.member?(policy.permissions, permission) do
      :ok
    else
      raise ArgumentError,
            "tool #{inspect(tool)} requires permission #{inspect(permission)} not granted by tool policy"
    end
  end

  def permit!(policy, _tool) do
    raise ArgumentError,
          ":tool_policy must be an AgentMachine.ToolPolicy, got: #{inspect(policy)}"
  end

  def tool_permission!(tool) when is_atom(tool) do
    unless Code.ensure_loaded?(tool) and function_exported?(tool, :permission, 0) do
      raise ArgumentError, "tool #{inspect(tool)} must export permission/0 for execution"
    end

    case tool.permission() do
      permission when is_atom(permission) and not is_nil(permission) ->
        permission

      permission ->
        raise ArgumentError,
              "tool #{inspect(tool)} permission/0 must return an atom, got: #{inspect(permission)}"
    end
  end

  def tool_permission!(tool) do
    raise ArgumentError, "tool must be a module atom, got: #{inspect(tool)}"
  end

  defp permissions!(permissions) when is_list(permissions) and permissions != [] do
    Enum.each(permissions, fn
      permission when is_atom(permission) and not is_nil(permission) ->
        :ok

      permission ->
        raise ArgumentError, "tool permission must be an atom, got: #{inspect(permission)}"
    end)

    MapSet.new(permissions)
  end

  defp permissions!(permissions) do
    raise ArgumentError,
          "tool policy :permissions must be a non-empty list, got: #{inspect(permissions)}"
  end
end
