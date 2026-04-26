defmodule AgentMachine.Skills.Registry do
  @moduledoc false

  alias AgentMachine.JSON
  alias AgentMachine.Skills.Manifest

  def default_path do
    :code.priv_dir(:agent_machine)
    |> to_string()
    |> Path.join("skills/registry.json")
  end

  def load!(path \\ default_path()) do
    {body, base_dir} = read_registry!(path)

    case JSON.decode!(body) do
      %{"skills" => skills} when is_list(skills) ->
        skills
        |> Enum.map(&entry!(&1, base_dir))
        |> reject_duplicate_names!()
        |> Enum.sort_by(& &1.name)

      decoded ->
        raise ArgumentError,
              "skill registry must contain a skills array, got: #{inspect(decoded)}"
    end
  end

  def find!(name, path \\ default_path()) do
    name = Manifest.validate_name!(name)

    case Enum.find(load!(path), &(&1.name == name)) do
      nil -> raise ArgumentError, "skill registry does not contain #{inspect(name)}"
      entry -> entry
    end
  end

  defp read_registry!(path) when is_binary(path) and byte_size(path) > 0 do
    if String.starts_with?(path, "http://") or String.starts_with?(path, "https://") do
      {read_url!(path), nil}
    else
      expanded = Path.expand(path)
      {File.read!(expanded), Path.dirname(expanded)}
    end
  rescue
    exception in [File.Error] ->
      reraise ArgumentError,
              [
                message:
                  "failed to read skill registry #{inspect(path)}: #{Exception.message(exception)}"
              ],
              __STACKTRACE__
  end

  defp read_registry!(path) do
    raise ArgumentError, "skill registry path must be a non-empty binary, got: #{inspect(path)}"
  end

  defp read_url!(url) do
    ensure_started!(:inets)
    ensure_started!(:ssl)

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 30_000}],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        body

      {:ok, {{_version, status, reason}, _headers, body}} ->
        raise ArgumentError,
              "failed to fetch skill registry #{inspect(url)}: HTTP #{status} #{inspect(reason)} #{inspect(body)}"

      {:error, reason} ->
        raise ArgumentError, "failed to fetch skill registry #{inspect(url)}: #{inspect(reason)}"
    end
  end

  defp entry!(entry, base_dir) when is_map(entry) do
    name = entry |> Map.fetch!("name") |> Manifest.validate_name!()

    description =
      require_non_empty_binary!(Map.fetch!(entry, "description"), "registry description")

    source = source!(Map.fetch!(entry, "source"), base_dir)

    %{
      name: name,
      description: description,
      source: source
    }
  rescue
    exception in [KeyError] ->
      reraise ArgumentError,
              [message: "invalid skill registry entry: #{Exception.message(exception)}"],
              __STACKTRACE__
  end

  defp entry!(entry, _base_dir) do
    raise ArgumentError, "skill registry entry must be an object, got: #{inspect(entry)}"
  end

  defp source!(%{"type" => "local", "path" => path}, base_dir) do
    path = require_non_empty_binary!(path, "local registry source path")

    expanded =
      cond do
        Path.type(path) == :absolute -> Path.expand(path)
        is_binary(base_dir) -> Path.expand(path, base_dir)
        true -> raise ArgumentError, "relative local registry source requires a file registry"
      end

    %{type: :local, path: expanded}
  end

  defp source!(%{"type" => "git", "repo" => repo, "ref" => ref, "path" => path}, _base_dir) do
    %{
      type: :git,
      repo: require_non_empty_binary!(repo, "git registry source repo"),
      ref: require_non_empty_binary!(ref, "git registry source ref"),
      path: Manifest.safe_relative_path!(path, "git registry source path")
    }
  end

  defp source!(source, _base_dir) do
    raise ArgumentError,
          "skill registry source must be local or git with required fields, got: #{inspect(source)}"
  end

  defp reject_duplicate_names!(entries) do
    duplicates =
      entries
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "skill registry contains duplicate names: #{inspect(duplicates)}"
    end

    entries
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp ensure_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
    end
  end
end
