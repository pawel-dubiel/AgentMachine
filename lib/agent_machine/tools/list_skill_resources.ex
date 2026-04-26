defmodule AgentMachine.Tools.ListSkillResources do
  @moduledoc """
  Lists read-only resources for selected AgentMachine skills.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Skills.ResourceStore

  @impl true
  def permission, do: :skills_resource_read

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "list_skill_resources",
      description:
        "List references, assets, and scripts bundled with skills selected for this run.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when input == %{} do
    {:ok, %{skills: opts |> ResourceStore.selected_skills!() |> ResourceStore.list_resources()}}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}
end
