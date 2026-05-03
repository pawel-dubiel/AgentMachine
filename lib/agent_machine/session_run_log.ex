defmodule AgentMachine.SessionRunLog do
  @moduledoc false

  alias AgentMachine.ClientRunner

  def prepare!(nil), do: :ok

  def prepare!(path) do
    path = validate_path!(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  def write_event(nil, _event), do: :ok

  def write_event(path, event) when is_map(event) do
    write_line!(path, ClientRunner.jsonl_event!(event))
  end

  def write_summary(nil, _summary), do: :ok

  def write_summary(path, summary) when is_map(summary) do
    write_line!(path, ClientRunner.jsonl_summary!(summary))
  end

  def validate_path!(nil), do: nil

  def validate_path!(path) when is_binary(path) and byte_size(path) > 0, do: path

  def validate_path!(path) do
    raise ArgumentError, "session run log_file must be a non-empty binary, got: #{inspect(path)}"
  end

  defp write_line!(path, line) do
    path = validate_path!(path)
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:append, :utf8]) do
      {:ok, io} ->
        try do
          IO.write(io, [line, ?\n])
        after
          File.close(io)
        end

      {:error, reason} ->
        raise ArgumentError, "failed to open session run log #{inspect(path)}: #{inspect(reason)}"
    end
  end
end
