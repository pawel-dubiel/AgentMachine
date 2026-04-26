defmodule AgentMachine.Tools.AppendFile do
  @moduledoc """
  Local file appender constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.{PathGuard, ToolResultSummary}

  @max_bytes_limit 200_000

  @impl true
  def permission, do: :local_files_append

  @impl true
  def approval_risk, do: :write

  @impl true
  def definition do
    %{
      name: "append_file",
      description:
        "Append UTF-8 text content to an existing file under the configured tool root.",
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
    path = input |> fetch_input!("path") |> PathGuard.require_non_empty_binary!("path")
    content = input |> fetch_input!("content") |> require_content!()
    target = PathGuard.existing_writable_target!(root, path, "append_file path")

    stat = require_regular_file!(target)
    before_content = File.read!(target)
    require_final_size!(stat.size, byte_size(content))

    File.write!(target, content, [:append])
    after_content = before_content <> content

    summary =
      ToolResultSummary.from_file_states(
        "append_file",
        root,
        target,
        before_content,
        after_content
      )

    {:ok,
     Map.merge(summary, %{
       path: ToolResultSummary.relative_path!(root, target),
       bytes: byte_size(content),
       total_bytes: stat.size + byte_size(content)
     })}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "append_file input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("path"), do: :path
  defp input_atom_key!("content"), do: :content

  defp require_content!(value) when is_binary(value) and byte_size(value) <= @max_bytes_limit,
    do: value

  defp require_content!(value) when is_binary(value) do
    raise ArgumentError,
          "content must be at most #{@max_bytes_limit} bytes, got: #{byte_size(value)}"
  end

  defp require_content!(value) do
    raise ArgumentError, "content must be a binary, got: #{inspect(value)}"
  end

  defp require_regular_file!(target) do
    case File.stat!(target) do
      %{type: :regular} ->
        File.stat!(target)

      %{type: type} ->
        raise ArgumentError, "append_file path must be a regular file, got: #{inspect(type)}"
    end
  end

  defp require_final_size!(current_size, append_size)
       when current_size + append_size <= @max_bytes_limit,
       do: :ok

  defp require_final_size!(current_size, append_size) do
    raise ArgumentError,
          "append_file result must be at most #{@max_bytes_limit} bytes, got: #{current_size + append_size}"
  end
end
