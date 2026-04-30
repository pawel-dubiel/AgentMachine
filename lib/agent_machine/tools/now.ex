defmodule AgentMachine.Tools.Now do
  @moduledoc """
  Safe tool that returns the current UTC time.
  """

  @behaviour AgentMachine.Tool

  @impl true
  def permission, do: :time_read

  @impl true
  def approval_risk, do: :read

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
    utc = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {:ok,
     %{
       utc: utc,
       timezone: "UTC",
       summary: %{tool: "now", status: "ok", utc: utc, timezone: "UTC"}
     }}
  end

  def run(input, _opts) do
    {:error, {:invalid_input, input}}
  end
end
