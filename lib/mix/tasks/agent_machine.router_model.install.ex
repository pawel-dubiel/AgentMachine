defmodule Mix.Tasks.AgentMachine.RouterModel.Install do
  @moduledoc """
  Installs the local router classifier model files into an explicit directory.
  """

  use Mix.Task

  alias AgentMachine.{JSON, LocalIntentClassifier}

  @shortdoc "Installs local router classifier model files"

  @repo "MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7"
  @base_url ~c"https://huggingface.co/#{@repo}/resolve/main"
  @files [
    "tokenizer.json",
    "config.json",
    "onnx/model_quantized.onnx"
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

    Enum.each(@files, fn relative_path ->
      destination = Path.join(target, relative_path)
      File.mkdir_p!(Path.dirname(destination))
      download_file!(relative_path, destination)
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

  defp download_file!(relative_path, destination) do
    url = @base_url ++ ~c"/" ++ String.to_charlist(relative_path)

    case request_with_redirects(url, @max_redirects) do
      {:ok, body} ->
        File.write!(destination, body)

      {:error, reason} ->
        Mix.raise("failed to download #{relative_path}: #{inspect(reason)}")
    end
  end

  defp request_with_redirects(_url, 0), do: {:error, :too_many_redirects}

  defp request_with_redirects(url, redirects_left) do
    headers = []
    request = {url, headers}
    options = [timeout: 120_000, connect_timeout: 30_000]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _response_headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, response_headers, _body}} when status in 300..399 ->
        case redirect_location(response_headers) do
          nil -> {:error, {:redirect_without_location, status}}
          location -> request_with_redirects(location, redirects_left - 1)
        end

      {:ok, {{_version, status, reason}, _headers, body}} ->
        {:error, {:http_error, status, reason, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redirect_location(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if name |> to_string() |> String.downcase() == "location" do
        value
      end
    end)
    |> case do
      nil -> nil
      value when is_list(value) -> value
      value when is_binary(value) -> String.to_charlist(value)
    end
  end

  defp write_manifest!(target) do
    manifest = %{
      model_repo: @repo,
      classifier_model: LocalIntentClassifier.model_id(),
      files: @files,
      intents: Enum.map(LocalIntentClassifier.intents(), &Atom.to_string/1),
      expected_label: "entailment"
    }

    File.write!(Path.join(target, @manifest_file), JSON.encode!(manifest))
  end

  defp verify_files!(target) do
    missing =
      @files
      |> Enum.reject(fn relative_path -> File.regular?(Path.join(target, relative_path)) end)

    if missing != [] do
      Mix.raise("router model installation is missing required file(s): #{inspect(missing)}")
    end
  end
end
