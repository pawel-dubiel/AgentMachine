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
    tool_harness: :string,
    tool_timeout_ms: :integer,
    input_price_per_million: :float,
    output_price_per_million: :float,
    log_file: :string,
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

    with_log_file(opts, fn log_io ->
      cond do
        Keyword.get(opts, :jsonl, false) ->
          output = Process.group_leader()

          summary =
            AgentMachine.ClientRunner.run!(attrs,
              event_sink: fn event ->
                line = AgentMachine.ClientRunner.jsonl_event!(event)
                IO.puts(output, line)
                write_log_line!(log_io, line)
              end
            )

          summary_line = AgentMachine.ClientRunner.jsonl_summary!(summary)
          IO.puts(output, summary_line)
          write_log_line!(log_io, summary_line)

        Keyword.get(opts, :json, false) ->
          summary =
            AgentMachine.ClientRunner.run!(attrs,
              event_sink: fn event ->
                write_log_line!(log_io, AgentMachine.ClientRunner.jsonl_event!(event))
              end
            )

          write_log_line!(log_io, AgentMachine.ClientRunner.jsonl_summary!(summary))
          Mix.shell().info(AgentMachine.ClientRunner.json!(summary))

        true ->
          summary =
            AgentMachine.ClientRunner.run!(attrs,
              event_sink: fn event ->
                write_log_line!(log_io, AgentMachine.ClientRunner.jsonl_event!(event))
              end
            )

          write_log_line!(log_io, AgentMachine.ClientRunner.jsonl_summary!(summary))
          print_text_summary(summary)
      end
    end)
  end

  defp validate_output_mode!(opts) do
    if Keyword.get(opts, :json, false) and Keyword.get(opts, :jsonl, false) do
      Mix.raise("--json and --jsonl cannot be used together")
    end
  end

  defp with_log_file(opts, callback) when is_function(callback, 1) do
    case Keyword.fetch(opts, :log_file) do
      {:ok, path} ->
        path = require_non_empty_log_path!(path)

        case File.open(path, [:write, :utf8]) do
          {:ok, io} ->
            try do
              callback.(io)
            after
              File.close(io)
            end

          {:error, reason} ->
            Mix.raise("failed to open --log-file #{inspect(path)}: #{inspect(reason)}")
        end

      :error ->
        callback.(nil)
    end
  end

  defp require_non_empty_log_path!(path) when is_binary(path) and byte_size(path) > 0, do: path

  defp require_non_empty_log_path!(path) do
    Mix.raise("--log-file must be a non-empty path, got: #{inspect(path)}")
  end

  defp write_log_line!(nil, _line), do: :ok

  defp write_log_line!(io, line) do
    IO.write(io, [line, ?\n])
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
      pricing: pricing_from_opts(opts),
      tool_harness: tool_harness_from_opts!(opts),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms)
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

  defp tool_harness_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_harness) do
      {:ok, "demo"} -> :demo
      {:ok, harness} -> Mix.raise("--tool-harness must be demo, got: #{inspect(harness)}")
      :error -> nil
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
