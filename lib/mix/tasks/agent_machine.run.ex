defmodule Mix.Tasks.AgentMachine.Run do
  @moduledoc """
  Runs a high-level AgentMachine task.
  """

  use Mix.Task

  @shortdoc "Runs a high-level AgentMachine task"

  @switches [
    workflow: :string,
    provider: :string,
    model: :string,
    timeout_ms: :integer,
    max_steps: :integer,
    max_attempts: :integer,
    http_timeout_ms: :integer,
    input_price_per_million: :float,
    output_price_per_million: :float,
    json: :boolean,
    jsonl: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    validate_output_mode!(opts)

    attrs = attrs_from_opts(opts, positional)

    cond do
      Keyword.get(opts, :jsonl, false) ->
        output = Process.group_leader()

        summary =
          AgentMachine.ClientRunner.run!(attrs,
            event_sink: fn event ->
              IO.puts(output, AgentMachine.ClientRunner.jsonl_event!(event))
            end
          )

        IO.puts(output, AgentMachine.ClientRunner.jsonl_summary!(summary))

      Keyword.get(opts, :json, false) ->
        summary = AgentMachine.ClientRunner.run!(attrs)
        Mix.shell().info(AgentMachine.ClientRunner.json!(summary))

      true ->
        summary = AgentMachine.ClientRunner.run!(attrs)
        print_text_summary(summary)
    end
  end

  defp validate_output_mode!(opts) do
    if Keyword.get(opts, :json, false) and Keyword.get(opts, :jsonl, false) do
      Mix.raise("--json and --jsonl cannot be used together")
    end
  end

  defp attrs_from_opts(opts, positional) do
    %{
      task: task_from_positional!(positional),
      workflow: workflow_from_opts!(opts),
      provider: provider_from_opts!(opts),
      model: Keyword.get(opts, :model),
      timeout_ms: fetch_required_option!(opts, :timeout_ms),
      max_steps: fetch_required_option!(opts, :max_steps),
      max_attempts: fetch_required_option!(opts, :max_attempts),
      http_timeout_ms: Keyword.get(opts, :http_timeout_ms),
      pricing: pricing_from_opts(opts)
    }
  end

  defp task_from_positional!([task]) when is_binary(task) and byte_size(task) > 0, do: task

  defp task_from_positional!(positional) do
    Mix.raise("expected exactly one non-empty task argument, got: #{inspect(positional)}")
  end

  defp workflow_from_opts!(opts) do
    case Keyword.fetch(opts, :workflow) do
      {:ok, "basic"} ->
        :basic

      {:ok, "agentic"} ->
        :agentic

      {:ok, workflow} ->
        Mix.raise("--workflow must be basic or agentic, got: #{inspect(workflow)}")

      :error ->
        Mix.raise("missing required --workflow option")
    end
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

  defp fetch_required_option!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Mix.raise("missing required --#{option_name(key)} option")
    end
  end

  defp pricing_from_opts(opts) do
    case {Keyword.fetch(opts, :input_price_per_million),
          Keyword.fetch(opts, :output_price_per_million)} do
      {{:ok, input}, {:ok, output}} ->
        %{input_per_million: input, output_per_million: output}

      {:error, :error} ->
        nil

      _other ->
        Mix.raise(
          "--input-price-per-million and --output-price-per-million must be provided together"
        )
    end
  end

  defp option_name(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp print_text_summary(summary) do
    Mix.shell().info("Run #{summary.run_id}: #{summary.status}")
    Mix.shell().info("")
    Mix.shell().info("Final output:")
    Mix.shell().info(summary.final_output || "(none)")
    Mix.shell().info("")
    Mix.shell().info("Usage:")
    Mix.shell().info("  agents: #{summary.usage.agents}")
    Mix.shell().info("  input tokens: #{summary.usage.input_tokens}")
    Mix.shell().info("  output tokens: #{summary.usage.output_tokens}")
    Mix.shell().info("  total tokens: #{summary.usage.total_tokens}")
    Mix.shell().info("  cost usd: #{summary.usage.cost_usd}")
  end
end
