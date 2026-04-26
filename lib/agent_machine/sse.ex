defmodule AgentMachine.SSE do
  @moduledoc false

  def new, do: %{buffer: ""}

  def parse_chunk(%{buffer: buffer} = state, chunk) when is_binary(chunk) do
    text = String.replace(buffer <> chunk, "\r\n", "\n")
    {blocks, rest} = split_blocks(text)

    events =
      blocks
      |> Enum.map(&data_from_block/1)
      |> Enum.reject(&(&1 == ""))

    {%{state | buffer: rest}, events}
  end

  def flush(%{buffer: ""} = state), do: {state, []}

  def flush(%{buffer: buffer} = state) do
    event = data_from_block(buffer)
    events = if event == "", do: [], else: [event]
    {%{state | buffer: ""}, events}
  end

  defp split_blocks(text) do
    parts = String.split(text, "\n\n")

    if String.ends_with?(text, "\n\n") do
      {Enum.reject(parts, &(&1 == "")), ""}
    else
      {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  defp data_from_block(block) do
    block
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, "data:") ->
          [line |> String.replace_prefix("data:", "") |> String.trim_leading()]

        String.starts_with?(line, ":") ->
          []

        true ->
          []
      end
    end)
    |> Enum.join("\n")
    |> String.trim()
  end
end
