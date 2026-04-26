defmodule AgentMachine.Skills.Prompt do
  @moduledoc false

  alias AgentMachine.Skills.Manifest

  def context(selected) when is_list(selected) do
    selected
    |> Enum.map(fn %{skill: %Manifest{} = skill, reason: reason} ->
      skill
      |> Manifest.prompt_entry()
      |> Map.put(:reason, reason)
    end)
  end
end
