defmodule AgentMachine.Tools.WriteFile do
  @moduledoc """
  Local file writer constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

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
          "content" => %{"type" => "string"}
        },
        "required" => ["path", "content"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = opts |> Keyword.fetch!(:tool_root) |> require_non_empty_binary!(:tool_root)
    path = input |> fetch_input!("path") |> require_non_empty_binary!("path")
    content = input |> fetch_input!("content") |> require_binary!("content")

    root = Path.expand(root)
    target = target_path(root, path)

    if inside_root?(target, root) do
      target |> Path.dirname() |> File.mkdir_p!()
      File.write!(target, content)
      {:ok, %{path: target, bytes: byte_size(content)}}
    else
      {:error, {:outside_tool_root, target, root}}
    end
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

  defp require_binary!(value, _field) when is_binary(value), do: value

  defp require_binary!(value, field) do
    raise ArgumentError, "#{field} must be a binary, got: #{inspect(value)}"
  end

  defp target_path(root, path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, root)
    end
  end

  defp inside_root?(target, root), do: target == root or String.starts_with?(target, root <> "/")
end
