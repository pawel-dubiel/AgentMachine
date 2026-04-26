defmodule AgentMachine.Tools.Now do
  @moduledoc """
  Safe demo tool that returns the current UTC time.
  """

  @behaviour AgentMachine.Tool

  @impl true
  def permission, do: :demo_time

  @impl true
  def definition do
    %{
      name: "now",
      description: "Return the current UTC timestamp.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, _opts) when input == %{} do
    {:ok, %{utc: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}}
  end

  def run(input, _opts) do
    {:error, {:invalid_input, input}}
  end
end
