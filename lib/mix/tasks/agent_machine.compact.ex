defmodule Mix.Tasks.AgentMachine.Compact do
  @moduledoc """
  Compacts conversation context through the configured provider.
  """

  use Mix.Task

  alias AgentMachine.{ContextCompactor, JSON}
  alias AgentMachine.Secrets.Redactor

  @shortdoc "Compacts conversation context"

  @switches [
    provider: :string,
    model: :string,
    http_timeout_ms: :integer,
    input_price_per_million: :float,
    output_price_per_million: :float,
    input_file: :string,
    json: :boolean
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
        "agent_machine.compact does not accept positional arguments: #{inspect(positional)}"
      )
    end

    unless Keyword.get(opts, :json, false) do
      Mix.raise("agent_machine.compact requires --json")
    end

    payload = read_input_file!(Keyword.get(opts, :input_file))

    result =
      payload
      |> conversation_messages!()
      |> ContextCompactor.compact_conversation!(
        provider: provider_from_opts!(opts),
        model: model_from_opts!(opts),
        http_timeout_ms: http_timeout_ms_from_opts!(opts),
        pricing: pricing_from_opts!(opts)
      )

    output = %{
      status: "ok",
      summary: result.summary,
      covered_items: result.covered_items,
      usage: result.usage_summary
    }

    redacted = output |> Redactor.redact_output() |> Map.fetch!(:value)
    Mix.shell().info(JSON.encode!(redacted))
  end

  defp read_input_file!(nil), do: Mix.raise("missing required --input-file option")

  defp read_input_file!(path) when is_binary(path) and byte_size(path) > 0 do
    case File.read(path) do
      {:ok, content} ->
        JSON.decode!(content)

      {:error, reason} ->
        Mix.raise("failed to read --input-file #{inspect(path)}: #{inspect(reason)}")
    end
  end

  defp read_input_file!(path),
    do: Mix.raise("--input-file must be a non-empty path, got: #{inspect(path)}")

  defp conversation_messages!(%{"type" => "conversation", "messages" => messages})
       when is_list(messages),
       do: messages

  defp conversation_messages!(payload) do
    Mix.raise(
      "--input-file must contain JSON object with type \"conversation\" and a messages list, got: #{inspect(payload)}"
    )
  end

  defp provider_from_opts!(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, "echo"} ->
        :echo

      {:ok, "openai"} ->
        :openai

      {:ok, "openrouter"} ->
        :openrouter

      {:ok, provider} ->
        Mix.raise("--provider must be echo, openai, or openrouter, got: #{inspect(provider)}")

      :error ->
        Mix.raise("missing required --provider option")
    end
  end

  defp model_from_opts!(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} when is_binary(model) and byte_size(model) > 0 -> model
      {:ok, model} -> Mix.raise("--model must be a non-empty string, got: #{inspect(model)}")
      :error -> Mix.raise("missing required --model option")
    end
  end

  defp http_timeout_ms_from_opts!(opts) do
    case Keyword.fetch(opts, :http_timeout_ms) do
      {:ok, timeout_ms} when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      {:ok, timeout_ms} ->
        Mix.raise("--http-timeout-ms must be a positive integer, got: #{inspect(timeout_ms)}")

      :error ->
        Mix.raise("missing required --http-timeout-ms option")
    end
  end

  defp pricing_from_opts!(opts) do
    case {Keyword.fetch(opts, :input_price_per_million),
          Keyword.fetch(opts, :output_price_per_million)} do
      {{:ok, input}, {:ok, output}} ->
        %{input_per_million: input, output_per_million: output}

      {:error, :error} ->
        Mix.raise("missing required pricing options")

      _other ->
        Mix.raise(
          "--input-price-per-million and --output-price-per-million must be provided together"
        )
    end
  end
end
