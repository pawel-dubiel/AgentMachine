defmodule AgentMachine.Intent do
  @moduledoc false

  @intents [
    :none,
    :file_read,
    :file_mutation,
    :code_mutation,
    :test_command,
    :time,
    :web_browse,
    :tool_use,
    :delegation
  ]

  def intents, do: @intents

  def valid?(intent), do: intent in @intents

  def normalize!(intent, _field) when intent in @intents, do: intent

  def normalize!(intent, field) do
    raise ArgumentError, invalid_message(field, intent)
  end

  defp invalid_message(field, intent) when is_atom(field),
    do: "invalid #{field}: #{inspect(intent)}"

  defp invalid_message(label, intent) when is_binary(label),
    do: "#{label}: #{inspect(intent)}"
end
