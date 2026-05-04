defmodule Mix.Tasks.AgentMachine.Providers do
  @moduledoc """
  Prints AgentMachine's ReqLLM provider catalog.
  """

  use Mix.Task

  alias AgentMachine.ProviderCatalog

  @shortdoc "Prints ReqLLM provider catalog data"

  @switches [
    json: :boolean,
    provider: :string,
    provider_option: :keep,
    include_unsupported: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    unless Keyword.get(opts, :json, false) do
      Mix.raise("agent_machine.providers requires --json")
    end

    payload =
      case positional do
        [] -> providers_payload(opts)
        ["models"] -> models_payload(opts)
        other -> Mix.raise("unsupported agent_machine.providers arguments: #{inspect(other)}")
      end

    Mix.shell().info(ProviderCatalog.encode_json!(payload))
  end

  defp providers_payload(opts) do
    providers = Enum.map(ProviderCatalog.providers(), &ProviderCatalog.provider_json/1)

    unsupported =
      if Keyword.get(opts, :include_unsupported, false) do
        Enum.map(
          ProviderCatalog.unsupported_requested_providers(),
          &ProviderCatalog.unsupported_json/1
        )
      else
        []
      end

    %{providers: providers, unsupported_requested_providers: unsupported}
  end

  defp models_payload(opts) do
    provider = provider_from_opts!(opts)
    provider_options = provider_options_from_opts!(opts)

    %{
      provider: provider,
      models:
        provider
        |> ProviderCatalog.list_models!(provider_options)
        |> Enum.map(&ProviderCatalog.model_json/1)
    }
  end

  defp provider_from_opts!(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} ->
        ProviderCatalog.fetch!(provider)
        provider

      :error ->
        Mix.raise("agent_machine.providers models requires --provider")
    end
  end

  defp provider_options_from_opts!(opts) do
    opts
    |> Keyword.get_values(:provider_option)
    |> Map.new(&provider_option_pair!/1)
  end

  defp provider_option_pair!(value) when is_binary(value) do
    case String.split(value, "=", parts: 2) do
      [key, option_value] when key != "" and option_value != "" ->
        {key, option_value}

      _other ->
        Mix.raise(
          "--provider-option must be key=value with non-empty key and value, got: #{inspect(value)}"
        )
    end
  end
end
