defmodule AgentMachine.Tools.CreateDir do
  @moduledoc """
  Local directory creator constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.PathGuard

  @impl true
  def definition do
    %{
      name: "create_dir",
      description: "Create one directory under the configured tool root.",
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
    target = PathGuard.target!(root, path)

    case File.lstat(target) do
      {:ok, %{type: :symlink}} ->
        {:error, "create_dir path must not be a symlink: #{inspect(target)}"}

      {:ok, %{type: :directory}} ->
        {:ok, %{path: PathGuard.existing_target!(root, target), created: false}}

      {:ok, %{type: type}} ->
        {:error, "create_dir path must be a directory or missing, got: #{inspect(type)}"}

      {:error, :enoent} ->
        create_missing_dir!(root, target)

      {:error, reason} ->
        {:error, "could not inspect create_dir path #{inspect(target)}: #{inspect(reason)}"}
    end
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "create_dir input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("path"), do: :path

  defp create_missing_dir!(root, target) do
    parent = Path.dirname(target)
    real_parent = existing_parent!(root, parent)
    require_directory!(real_parent, "parent")

    File.mkdir!(target)
    {:ok, %{path: PathGuard.existing_target!(root, target), created: true}}
  end

  defp existing_parent!(root, parent) do
    case File.lstat(parent) do
      {:ok, _stat} ->
        PathGuard.existing_target!(root, parent)

      {:error, :enoent} ->
        raise ArgumentError, "parent directory does not exist: #{inspect(parent)}"

      {:error, reason} ->
        raise ArgumentError,
              "could not inspect parent directory #{inspect(parent)}: #{inspect(reason)}"
    end
  end

  defp require_directory!(target, label) do
    case File.stat!(target) do
      %{type: :directory} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "#{label} must be a directory, got: #{inspect(type)}"
    end
  end
end
