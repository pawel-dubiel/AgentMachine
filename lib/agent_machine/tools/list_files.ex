defmodule AgentMachine.Tools.ListFiles do
  @moduledoc """
  Non-recursive local directory lister constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.PathGuard

  @max_entries_limit 500

  @impl true
  def permission, do: :local_files_list

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "list_files",
      description: "List direct children of a directory under the configured tool root.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "Relative path under the configured root, or an absolute path inside that root."
          },
          "max_entries" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_entries_limit
          }
        },
        "required" => ["path", "max_entries"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    path = input |> fetch_input!("path") |> PathGuard.require_non_empty_binary!("path")
    max_entries = input |> fetch_input!("max_entries") |> require_max_entries!()
    target = PathGuard.existing_target!(root, path)

    require_directory!(target)

    names = target |> File.ls!() |> Enum.sort()
    {visible_names, truncated} = take_with_truncation(names, max_entries)

    {:ok,
     %{
       path: target,
       entries: Enum.map(visible_names, &entry!(target, &1)),
       truncated: truncated
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
      true -> raise ArgumentError, "list_files input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("path"), do: :path
  defp input_atom_key!("max_entries"), do: :max_entries

  defp require_max_entries!(value) when is_integer(value) and value in 1..@max_entries_limit do
    value
  end

  defp require_max_entries!(value) do
    raise ArgumentError,
          "max_entries must be an integer from 1 to #{@max_entries_limit}, got: #{inspect(value)}"
  end

  defp require_directory!(target) do
    case File.stat!(target) do
      %{type: :directory} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "list_files path must be a directory, got: #{inspect(type)}"
    end
  end

  defp take_with_truncation(names, max_entries) do
    visible = Enum.take(names, max_entries)
    {visible, length(names) > max_entries}
  end

  defp entry!(root, name) do
    path = Path.join(root, name)
    stat = File.lstat!(path)

    %{
      name: name,
      path: path,
      type: Atom.to_string(stat.type),
      size: stat.size
    }
  end
end
