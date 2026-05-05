defmodule AgentMachine.ExecutionPlanner do
  @moduledoc """
  Internal strategy planner for the single public agentic runtime.
  """

  alias AgentMachine.{RunSpec, WorkflowRouter}

  @planned_forcing_reasons [
    {:planner_review_mode, "planner_review_requires_planned_strategy"},
    {:agentic_persistence_rounds, "agentic_persistence_requires_planned_strategy"}
  ]

  def plan!(%RunSpec{} = spec) do
    spec
    |> route_with_private_classifier!()
    |> normalize_strategy!()
    |> maybe_force_planned_strategy(spec)
  end

  defp route_with_private_classifier!(%RunSpec{} = spec) do
    spec
    |> Map.put(:workflow, :auto)
    |> maybe_use_local_router()
    |> WorkflowRouter.route!()
  end

  defp maybe_use_local_router(%RunSpec{provider: :echo, router_mode: :llm} = spec),
    do: %{spec | router_mode: :deterministic}

  defp maybe_use_local_router(spec), do: spec

  defp normalize_strategy!(%{strategy: "swarm"} = route), do: strategy(route, "swarm")
  defp normalize_strategy!(%{"strategy" => "swarm"} = route), do: strategy(route, "swarm")
  defp normalize_strategy!(%{selected: "agentic"} = route), do: strategy(route, "planned")
  defp normalize_strategy!(%{"selected" => "agentic"} = route), do: strategy(route, "planned")
  defp normalize_strategy!(%{selected: "tool"} = route), do: strategy(route, "tool")
  defp normalize_strategy!(%{"selected" => "tool"} = route), do: strategy(route, "tool")
  defp normalize_strategy!(%{selected: "chat"} = route), do: strategy(route, "direct")
  defp normalize_strategy!(%{"selected" => "chat"} = route), do: strategy(route, "direct")

  defp normalize_strategy!(route) do
    raise ArgumentError, "execution planner received unsupported route: #{inspect(route)}"
  end

  defp strategy(route, strategy) do
    route
    |> Map.put(:requested, "agentic")
    |> Map.put(:selected, strategy)
    |> Map.put(:strategy, strategy)
  end

  defp maybe_force_planned_strategy(%{strategy: "swarm"} = plan, _spec), do: plan

  defp maybe_force_planned_strategy(plan, spec) do
    case Enum.find(@planned_forcing_reasons, fn {field, _reason} -> Map.get(spec, field) end) do
      nil ->
        plan

      {_field, reason} ->
        plan
        |> Map.put(:selected, "planned")
        |> Map.put(:strategy, "planned")
        |> Map.put(:reason, reason)
    end
  end
end
