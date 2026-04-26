defmodule AgentMachine.Tools.WriteFile do
  @moduledoc """
  Local file writer constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool
  alias AgentMachine.Tools.PathGuard

  @max_bytes_limit 200_000

  @impl true
  def permission, do: :local_files_write

  @impl true
  def definition do
    %{
      name: "write_file",
      description: "Write UTF-8 text content to a file under the configured tool root.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "Relative path under the configured root, or an absolute path inside that root."
          },
          "content" => %{"type" => "string", "maxLength" => @max_bytes_limit}
        },
        "required" => ["path", "content"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    path = input |> fetch_input!("path") |> require_non_empty_binary!("path")
    content = input |> fetch_input!("content") |> require_content!()
    target = PathGuard.writable_target!(root, path)

    File.write!(target, content)
    {:ok, %{path: target, bytes: byte_size(content)}}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "write_file input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("path"), do: :path
  defp input_atom_key!("content"), do: :content

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError, "#{field} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_content!(value) when is_binary(value) and byte_size(value) <= @max_bytes_limit,
    do: value

  defp require_content!(value) when is_binary(value) do
    raise ArgumentError,
          "content must be at most #{@max_bytes_limit} bytes, got: #{byte_size(value)}"
  end

  defp require_content!(value) do
    raise ArgumentError, "content must be a binary, got: #{inspect(value)}"
  end
end
