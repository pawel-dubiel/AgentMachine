defmodule AgentMachine.JSON do
  @moduledoc false

  def encode!(value) do
    case Jason.encode(value) do
      {:ok, encoded} ->
        encoded

      {:error, error} ->
        raise ArgumentError, "unsupported JSON value: #{Exception.message(error)}"
    end
  end

  def decode!(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, decoded} -> decoded
      {:error, error} -> raise ArgumentError, "invalid JSON: #{Exception.message(error)}"
    end
  end

  def decode!(value) do
    raise ArgumentError, "JSON input must be a binary, got: #{inspect(value)}"
  end
end
