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
    tool_max_rounds: :integer,
    tool_root: :string,
    tool_approval_mode: :string,
    test_command: :string,
    mcp_config: :string,
    skills: :string,
    skills_dir: :string,
    skill: :string,
    allow_skill_scripts: :boolean,
    input_price_per_million: :float,
    output_price_per_million: :float,
    log_file: :string,
    json: :boolean,
    jsonl: :boolean,
    stream_response: :boolean
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

    if Keyword.get(opts, :stream_response, false) and not Keyword.get(opts, :jsonl, false) do
      Mix.raise("--stream-response requires --jsonl")
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
      tool_harnesses: tool_harnesses_from_opts!(opts),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms),
      tool_max_rounds: Keyword.get(opts, :tool_max_rounds),
      tool_root: Keyword.get(opts, :tool_root),
      tool_approval_mode: tool_approval_mode_from_opts!(opts),
      test_commands: test_commands_from_opts(opts),
      mcp_config_path: Keyword.get(opts, :mcp_config),
      skills_mode: skills_mode_from_opts!(opts),
      skills_dir: skills_dir_from_opts(opts),
      skill_names: Keyword.get_values(opts, :skill),
      allow_skill_scripts: Keyword.get(opts, :allow_skill_scripts, false),
      stream_response: Keyword.get(opts, :stream_response, false)
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

  defp tool_harnesses_from_opts!(opts) do
    case Keyword.get_values(opts, :tool_harness) do
      [] -> nil
      harnesses -> Enum.map(harnesses, &tool_harness_from_string!/1)
    end
  end

  defp tool_harness_from_string!("demo"), do: :demo
  defp tool_harness_from_string!("local-files"), do: :local_files
  defp tool_harness_from_string!("code-edit"), do: :code_edit
  defp tool_harness_from_string!("mcp"), do: :mcp
  defp tool_harness_from_string!("skills"), do: :skills

  defp tool_harness_from_string!(harness) do
    Mix.raise(
      "--tool-harness must be demo, local-files, code-edit, mcp, or skills, got: #{inspect(harness)}"
    )
  end

  defp skills_mode_from_opts!(opts) do
    case Keyword.fetch(opts, :skills) do
      {:ok, "off"} ->
        :off

      {:ok, "auto"} ->
        :auto

      {:ok, mode} ->
        Mix.raise("--skills must be off or auto, got: #{inspect(mode)}")

      :error ->
        :off
    end
  end

  defp skills_dir_from_opts(opts) do
    case Keyword.fetch(opts, :skills_dir) do
      {:ok, path} -> path
      :error -> System.get_env("AGENT_MACHINE_SKILLS_DIR")
    end
  end

  defp tool_approval_mode_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_approval_mode) do
      {:ok, "read-only"} ->
        :read_only

      {:ok, "ask-before-write"} ->
        :ask_before_write

      {:ok, "auto-approved-safe"} ->
        :auto_approved_safe

      {:ok, "full-access"} ->
        :full_access

      {:ok, mode} ->
        Mix.raise(
          "--tool-approval-mode must be read-only, ask-before-write, auto-approved-safe, or full-access, got: #{inspect(mode)}"
        )

      :error ->
        nil
    end
  end

  defp test_commands_from_opts(opts) do
    case Keyword.get_values(opts, :test_command) do
      [] -> nil
      commands -> commands
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
