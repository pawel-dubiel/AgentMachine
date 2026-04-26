defmodule AgentMachine.Tools.FileInfo do
  @moduledoc """
  Local file metadata reader constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.PathGuard

  @impl true
  def permission, do: :local_files_info

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "file_info",
      description: "Inspect metadata for one path under the configured tool root.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "Relative path under the configured root, or an absolute path inside that root."
          }
        },
        "required" => ["path"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    path = input |> fetch_input!("path") |> PathGuard.require_non_empty_binary!("path")
    target = PathGuard.inspectable_target!(root, path, "file_info path")
    stat = File.lstat!(target)

    {:ok,
     %{
       path: target,
       type: Atom.to_string(stat.type),
       size: stat.size,
       mode: stat.mode,
       mtime: format_datetime(stat.mtime)
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
      true -> raise ArgumentError, "file_info input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("path"), do: :path

  defp format_datetime({{year, month, day}, {hour, minute, second}}) do
    "#{pad(year, 4)}-#{pad(month, 2)}-#{pad(day, 2)}T#{pad(hour, 2)}:#{pad(minute, 2)}:#{pad(second, 2)}"
  end

  defp pad(value, length), do: value |> Integer.to_string() |> String.pad_leading(length, "0")
end
