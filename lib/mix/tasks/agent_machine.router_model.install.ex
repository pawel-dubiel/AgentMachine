defmodule Mix.Tasks.AgentMachine.RouterModel.Install do
  @moduledoc """
  Installs the local router classifier model files into an explicit directory.
  """

  use Mix.Task

  alias AgentMachine.{JSON, LocalIntentClassifier}

  @shortdoc "Installs local router classifier model files"

  @repo "MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7"
  @revision "08e97d4626c80790e50f75da74ed1fecfda644af"
  @base_url "https://huggingface.co/#{@repo}/resolve/#{@revision}"
  @allowed_download_hosts MapSet.new([
                            "huggingface.co",
                            "cdn-lfs.huggingface.co",
                            "cas-bridge.xethub.hf.co"
                          ])
  @files [
    %{
      path: "tokenizer.json",
      sha256: "e23095eb61ba944c7be3a5d3e8ec19e37ce7ced0daa03550bde03e83c21b3f8a"
    },
    %{
      path: "config.json",
      sha256: "bc7b85f164a17c1b007d87fb99d3676f4a4d2e6511d2288dd3f5334dc0f34e6b"
    },
    %{
      path: "onnx/model_quantized.onnx",
      sha256: "18307c3bcb5d896a624c077af061b259d341829f3d13c8b3d49a044e28d4fe6a"
    }
  ]
  @manifest_file "agent_machine_router_model.json"
  @max_redirects 5

  @switches [
    target: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    if positional != [] do
      Mix.raise(
        "agent_machine.router_model.install does not accept positional arguments: #{inspect(positional)}"
      )
    end

    target = target_from_opts!(opts)
    :inets.start()
    :ssl.start()
    File.mkdir_p!(target)

    Enum.each(@files, fn %{path: relative_path} = spec ->
      destination = Path.join(target, relative_path)
      File.mkdir_p!(Path.dirname(destination))
      download_file!(spec, destination)
      Mix.shell().info("installed #{relative_path}")
    end)

    write_manifest!(target)
    verify_files!(target)

    Mix.shell().info("router model installed in #{target}")
  end

  defp target_from_opts!(opts) do
    case Keyword.fetch(opts, :target) do
      {:ok, target} when is_binary(target) and byte_size(target) > 0 ->
        Path.expand(target)

      {:ok, target} ->
        Mix.raise("--target must be a non-empty path, got: #{inspect(target)}")

      :error ->
        Mix.raise("missing required --target option")
    end
  end

  @doc false
  def model_revision, do: @revision

  @doc false
  def file_specs, do: @files

  @doc false
  def validate_download_url!(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and MapSet.member?(@allowed_download_hosts, uri.host) do
      url
    else
      Mix.raise("unsafe router model download URL: #{inspect(url)}")
    end
  end

  def validate_download_url!(url) do
    Mix.raise("router model download URL must be a binary, got: #{inspect(url)}")
  end

  @doc false
  def verify_download_body!(relative_path, body) when is_binary(body) do
    expected = expected_sha256!(relative_path)
    actual = sha256(body)

    if actual == expected do
      body
    else
      Mix.raise(
        "router model #{relative_path} SHA-256 mismatch: expected #{expected}, got #{actual}"
      )
    end
  end

  def verify_download_body!(_relative_path, body) do
    Mix.raise("router model download body must be a binary, got: #{inspect(body)}")
  end

  defp download_file!(%{path: relative_path}, destination) do
    url = @base_url <> "/" <> relative_path

    case request_with_redirects(url, @max_redirects) do
      {:ok, body} ->
        body = verify_download_body!(relative_path, body)
        File.write!(destination, body)

      {:error, reason} ->
        Mix.raise("failed to download #{relative_path}: #{inspect(reason)}")
    end
  end

  defp request_with_redirects(_url, 0), do: {:error, :too_many_redirects}

  defp request_with_redirects(url, redirects_left) do
    url = validate_download_url!(url)
    headers = []
    request = {String.to_charlist(url), headers}
    options = [timeout: 120_000, connect_timeout: 30_000]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _response_headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, response_headers, _body}} when status in 300..399 ->
        case redirect_location(response_headers, url) do
          nil -> {:error, {:redirect_without_location, status}}
          location -> request_with_redirects(location, redirects_left - 1)
        end

      {:ok, {{_version, status, reason}, _headers, body}} ->
        {:error, {:http_error, status, reason, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redirect_location(headers, current_url) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if name |> to_string() |> String.downcase() == "location" do
        value
      end
    end)
    |> case do
      nil -> nil
      value when is_list(value) -> current_url |> URI.merge(to_string(value)) |> URI.to_string()
      value when is_binary(value) -> current_url |> URI.merge(value) |> URI.to_string()
    end
  end

  defp write_manifest!(target) do
    manifest = %{
      model_repo: @repo,
      model_revision: @revision,
      classifier_model: LocalIntentClassifier.model_id(),
      files: file_paths(),
      file_sha256: Map.new(@files, &{&1.path, &1.sha256}),
      intents: Enum.map(LocalIntentClassifier.intents(), &Atom.to_string/1),
      expected_label: "entailment"
    }

    File.write!(Path.join(target, @manifest_file), JSON.encode!(manifest))
  end

  defp verify_files!(target) do
    missing =
      file_paths()
      |> Enum.reject(fn relative_path -> File.regular?(Path.join(target, relative_path)) end)

    if missing != [] do
      Mix.raise("router model installation is missing required file(s): #{inspect(missing)}")
    end

    Enum.each(@files, fn %{path: relative_path, sha256: expected} ->
      actual =
        target
        |> Path.join(relative_path)
        |> File.read!()
        |> sha256()

      if actual != expected do
        Mix.raise(
          "installed router model #{relative_path} SHA-256 mismatch: expected #{expected}, got #{actual}"
        )
      end
    end)
  end

  defp file_paths do
    Enum.map(@files, & &1.path)
  end

  defp expected_sha256!(relative_path) do
    case Enum.find(@files, &(&1.path == relative_path)) do
      %{sha256: sha256} -> sha256
      nil -> Mix.raise("unknown router model file: #{inspect(relative_path)}")
    end
  end

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end
end
