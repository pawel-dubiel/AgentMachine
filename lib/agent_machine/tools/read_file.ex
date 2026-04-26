defmodule AgentMachine.Tools.ReadFile do
  @moduledoc """
  Local text file reader constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Tools.PathGuard

  @max_bytes_limit 200_000

  @impl true
  def permission, do: :local_files_read

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "read_file",
      description: "Read UTF-8 text from a file under the configured tool root.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "Relative path under the configured root, or an absolute path inside that root."
          },
          "max_bytes" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_bytes_limit
          }
        },
        "required" => ["path", "max_bytes"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    path = input |> fetch_input!("path") |> PathGuard.require_non_empty_binary!("path")
    max_bytes = input |> fetch_input!("max_bytes") |> require_max_bytes!()
    target = PathGuard.existing_target!(root, path)

    require_regular_file!(target)

    {content, truncated} = read_text!(target, max_bytes)
    redaction = Redactor.redact_string(content)

    result = %{
      path: target,
      content: redaction.value,
      bytes: byte_size(redaction.value),
      truncated: truncated
    }

    {:ok, Redactor.put_tool_metadata(result, redaction)}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "read_file input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("path"), do: :path
  defp input_atom_key!("max_bytes"), do: :max_bytes

  defp require_max_bytes!(value) when is_integer(value) and value in 1..@max_bytes_limit do
    value
  end

  defp require_max_bytes!(value) do
    raise ArgumentError,
          "max_bytes must be an integer from 1 to #{@max_bytes_limit}, got: #{inspect(value)}"
  end

  defp require_regular_file!(target) do
    case File.stat!(target) do
      %{type: :regular} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "read_file path must be a regular file, got: #{inspect(type)}"
    end
  end

  defp read_text!(target, max_bytes) do
    data =
      File.open!(target, [:read, :binary], fn file ->
        case IO.binread(file, max_bytes + 1) do
          :eof -> ""
          bytes -> bytes
        end
      end)

    truncated = byte_size(data) > max_bytes
    content = binary_part(data, 0, min(byte_size(data), max_bytes))

    {valid_text!(content, truncated), truncated}
  end

  defp valid_text!(content, _truncated) when is_binary(content) do
    if String.valid?(content) do
      content
    else
      case :unicode.characters_to_binary(content, :utf8, :utf8) do
        {:incomplete, valid_prefix, _rest} ->
          valid_prefix

        _other ->
          raise ArgumentError, "read_file content must be valid UTF-8 text"
      end
    end
  end
end
