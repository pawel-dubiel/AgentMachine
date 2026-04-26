defmodule AgentMachine.Tools.ReplaceInFile do
  @moduledoc """
  Exact text replacement constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.PathGuard

  @max_file_bytes 200_000
  @max_replacement_bytes 200_000
  @max_replacements 100

  @impl true
  def permission, do: :local_files_replace

  @impl true
  def approval_risk, do: :write

  @impl true
  def definition do
    %{
      name: "replace_in_file",
      description:
        "Replace exact UTF-8 text in one existing file under the configured tool root.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "Relative path under the configured root, or an absolute path inside that root."
          },
          "old_text" => %{"type" => "string", "minLength" => 1},
          "new_text" => %{"type" => "string", "maxLength" => @max_replacement_bytes},
          "expected_replacements" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_replacements
          }
        },
        "required" => ["path", "old_text", "new_text", "expected_replacements"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    path = input |> fetch_input!("path") |> PathGuard.require_non_empty_binary!("path")
    old_text = input |> fetch_input!("old_text") |> require_old_text!()
    new_text = input |> fetch_input!("new_text") |> require_new_text!()

    expected_replacements =
      input |> fetch_input!("expected_replacements") |> require_expected_replacements!()

    target = PathGuard.existing_writable_target!(root, path, "replace_in_file path")
    require_regular_file!(target)

    content = read_text!(target)
    actual_replacements = replacement_count(content, old_text)
    require_replacement_count!(actual_replacements, expected_replacements)

    updated = String.replace(content, old_text, new_text, global: true)
    require_updated_size!(updated)
    File.write!(target, updated)

    {:ok,
     %{
       path: target,
       replacements: actual_replacements,
       bytes: byte_size(updated)
     }}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "replace_in_file input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("path"), do: :path
  defp input_atom_key!("old_text"), do: :old_text
  defp input_atom_key!("new_text"), do: :new_text
  defp input_atom_key!("expected_replacements"), do: :expected_replacements

  defp require_old_text!(value) when is_binary(value) and byte_size(value) > 0, do: value

  defp require_old_text!(value) do
    raise ArgumentError, "old_text must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_new_text!(value)
       when is_binary(value) and byte_size(value) <= @max_replacement_bytes,
       do: value

  defp require_new_text!(value) when is_binary(value) do
    raise ArgumentError,
          "new_text must be at most #{@max_replacement_bytes} bytes, got: #{byte_size(value)}"
  end

  defp require_new_text!(value) do
    raise ArgumentError, "new_text must be a binary, got: #{inspect(value)}"
  end

  defp require_expected_replacements!(value)
       when is_integer(value) and value in 1..@max_replacements,
       do: value

  defp require_expected_replacements!(value) do
    raise ArgumentError,
          "expected_replacements must be an integer from 1 to #{@max_replacements}, got: #{inspect(value)}"
  end

  defp require_regular_file!(target) do
    case File.stat!(target) do
      %{type: :regular} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "replace_in_file path must be a regular file, got: #{inspect(type)}"
    end
  end

  defp read_text!(target) do
    case File.stat!(target) do
      %{size: size} when size <= @max_file_bytes ->
        content = File.read!(target)

        if String.valid?(content) do
          content
        else
          raise ArgumentError, "replace_in_file content must be valid UTF-8 text"
        end

      %{size: size} ->
        raise ArgumentError,
              "replace_in_file file must be at most #{@max_file_bytes} bytes, got: #{size}"
    end
  end

  defp replacement_count(content, old_text) do
    content
    |> :binary.matches(old_text)
    |> length()
  end

  defp require_replacement_count!(actual, expected) when actual == expected, do: :ok

  defp require_replacement_count!(actual, expected) do
    raise ArgumentError,
          "expected #{expected} replacements but found #{actual}"
  end

  defp require_updated_size!(updated) when byte_size(updated) <= @max_file_bytes, do: :ok

  defp require_updated_size!(updated) do
    raise ArgumentError,
          "replace_in_file result must be at most #{@max_file_bytes} bytes, got: #{byte_size(updated)}"
  end
end
