defmodule Mix.Tasks.AgentMachine.Run do
  @moduledoc """
  Runs a high-level AgentMachine task.
  """

  use Mix.Task

  @shortdoc "Runs a high-level AgentMachine task"

  @switches [
    workflow: :string,
    recent_context: :string,
    pending_action: :string,
    provider: :string,
    provider_option: :keep,
    model: :string,
    timeout_ms: :integer,
    max_steps: :integer,
    max_attempts: :integer,
    agentic_persistence_rounds: :integer,
    planner_review: :string,
    planner_review_max_revisions: :integer,
    http_timeout_ms: :integer,
    tool_harness: :keep,
    tool_timeout_ms: :integer,
    tool_max_rounds: :integer,
    tool_root: :string,
    tool_approval_mode: :string,
    permission_control: :string,
    test_command: :keep,
    mcp_config: :string,
    skills: :string,
    skills_dir: :string,
    skill: :keep,
    allow_skill_scripts: :boolean,
    input_price_per_million: :float,
    output_price_per_million: :float,
    log_file: :string,
    event_log_file: :string,
    event_session_id: :string,
    json: :boolean,
    jsonl: :boolean,
    stream_response: :boolean,
    progress_observer: :boolean,
    context_window_tokens: :integer,
    context_warning_percent: :integer,
    context_tokenizer_path: :string,
    reserved_output_tokens: :integer,
    run_context_compaction: :string,
    run_context_compact_percent: :integer,
    max_context_compactions: :integer,
    router_mode: :string,
    router_model_dir: :string,
    router_timeout_ms: :integer,
    router_confidence_threshold: :float
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    validate_output_mode!(opts)
    validate_event_log_opts!(opts)
    validate_permission_control_opts!(opts)
    validate_planner_review_opts!(opts)

    attrs = attrs_from_opts(opts, positional)

    with_event_log(opts, fn ->
      with_log_file(opts, &run_and_print(opts, attrs, &1))
    end)
  end

  defp run_and_print(opts, attrs, log_io) do
    cond do
      Keyword.get(opts, :jsonl, false) ->
        output = Process.group_leader()
        event_sink = jsonl_event_sink(output, log_io)

        summary = with_runtime_control(opts, attrs, event_sink)

        summary_line = AgentMachine.ClientRunner.jsonl_summary!(summary)
        IO.puts(output, summary_line)
        write_log_line!(log_io, summary_line)

      Keyword.get(opts, :json, false) ->
        summary = run_with_log_sink(attrs, log_io, opts)

        write_log_line!(log_io, AgentMachine.ClientRunner.jsonl_summary!(summary))
        Mix.shell().info(AgentMachine.ClientRunner.json!(summary))

      true ->
        summary = run_with_log_sink(attrs, log_io, opts)

        write_log_line!(log_io, AgentMachine.ClientRunner.jsonl_summary!(summary))
        print_text_summary(summary)
    end
  end

  defp jsonl_event_sink(output, log_io) do
    fn event ->
      line = AgentMachine.ClientRunner.jsonl_event!(event)
      IO.puts(output, line)
      write_log_line!(log_io, line)
    end
  end

  defp with_runtime_control(opts, attrs, event_sink) do
    if jsonl_runtime_control?(opts) do
      {:ok, control} = AgentMachine.PermissionControl.start_link(input: :stdio)

      try do
        AgentMachine.ClientRunner.run!(
          attrs,
          runtime_control_opts(opts, event_sink, control)
        )
      after
        AgentMachine.PermissionControl.cancel_all(control, "run ended")
      end
    else
      AgentMachine.ClientRunner.run!(attrs, prompt_runtime_opts(opts, event_sink))
    end
  end

  defp run_with_log_sink(attrs, log_io, opts) do
    event_sink = fn event ->
      write_log_line!(log_io, AgentMachine.ClientRunner.jsonl_event!(event))
    end

    AgentMachine.ClientRunner.run!(attrs, prompt_runtime_opts(opts, event_sink))
  end

  defp runtime_control_opts(opts, event_sink, control) do
    [event_sink: event_sink, permission_control: control]
    |> maybe_put_tool_control_callback(opts, control)
    |> maybe_put_jsonl_planner_review_callback(opts, control)
    |> maybe_put_prompt_planner_review_callback(opts)
  end

  defp prompt_runtime_opts(opts, event_sink) do
    [event_sink: event_sink]
    |> maybe_put_prompt_planner_review_callback(opts)
  end

  defp maybe_put_tool_control_callback(callback_opts, opts, control) do
    case Keyword.fetch(opts, :permission_control) do
      {:ok, "jsonl-stdio"} ->
        Keyword.put(callback_opts, :tool_approval_callback, fn context ->
          AgentMachine.PermissionControl.request(control, context)
        end)

      :error ->
        callback_opts
    end
  end

  defp maybe_put_jsonl_planner_review_callback(callback_opts, opts, control) do
    case Keyword.fetch(opts, :planner_review) do
      {:ok, "jsonl-stdio"} ->
        Keyword.put(callback_opts, :planner_review_callback, fn context ->
          AgentMachine.PermissionControl.request(control, context)
        end)

      _other ->
        callback_opts
    end
  end

  defp maybe_put_prompt_planner_review_callback(callback_opts, opts) do
    case Keyword.fetch(opts, :planner_review) do
      {:ok, "prompt"} ->
        Keyword.put(callback_opts, :planner_review_callback, &prompt_planner_review/1)

      _other ->
        callback_opts
    end
  end

  defp jsonl_runtime_control?(opts) do
    Keyword.get(opts, :permission_control) == "jsonl-stdio" or
      Keyword.get(opts, :planner_review) == "jsonl-stdio"
  end

  defp validate_output_mode!(opts) do
    if Keyword.get(opts, :json, false) and Keyword.get(opts, :jsonl, false) do
      Mix.raise("--json and --jsonl cannot be used together")
    end

    if Keyword.get(opts, :stream_response, false) and not Keyword.get(opts, :jsonl, false) do
      Mix.raise("--stream-response requires --jsonl")
    end

    if Keyword.get(opts, :progress_observer, false) and not Keyword.get(opts, :jsonl, false) do
      Mix.raise("--progress-observer requires --jsonl")
    end
  end

  defp with_log_file(opts, callback) when is_function(callback, 1) do
    case Keyword.fetch(opts, :log_file) do
      {:ok, path} ->
        path = require_non_empty_path!(path, "--log-file")

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

  defp with_event_log(opts, callback) when is_function(callback, 0) do
    case Keyword.fetch(opts, :event_log_file) do
      {:ok, path} ->
        path = require_non_empty_path!(path, "--event-log-file")

        AgentMachine.EventLog.configure!(path, %{
          session_id: Keyword.get(opts, :event_session_id),
          source: "mix agent_machine.run"
        })

        try do
          callback.()
        after
          AgentMachine.EventLog.close()
        end

      :error ->
        callback.()
    end
  end

  defp validate_event_log_opts!(opts) do
    if Keyword.has_key?(opts, :event_session_id) and not Keyword.has_key?(opts, :event_log_file) do
      Mix.raise("--event-session-id requires --event-log-file")
    end
  end

  defp validate_permission_control_opts!(opts) do
    case Keyword.fetch(opts, :permission_control) do
      :error ->
        :ok

      {:ok, "jsonl-stdio"} ->
        unless Keyword.get(opts, :jsonl, false) do
          Mix.raise("--permission-control jsonl-stdio requires --jsonl")
        end

      {:ok, value} ->
        Mix.raise("--permission-control must be jsonl-stdio, got: #{inspect(value)}")
    end
  end

  defp validate_planner_review_opts!(opts) do
    case {Keyword.fetch(opts, :planner_review),
          Keyword.fetch(opts, :planner_review_max_revisions)} do
      {:error, :error} ->
        :ok

      {:error, {:ok, _revisions}} ->
        Mix.raise("--planner-review-max-revisions requires --planner-review")

      {{:ok, mode}, :error} when mode in ["prompt", "jsonl-stdio"] ->
        Mix.raise("--planner-review #{mode} requires --planner-review-max-revisions")

      {{:ok, "jsonl-stdio"}, {:ok, revisions}} ->
        require_positive_revision_limit!(revisions)

        unless Keyword.get(opts, :jsonl, false) do
          Mix.raise("--planner-review jsonl-stdio requires --jsonl")
        end

      {{:ok, "prompt"}, {:ok, revisions}} ->
        require_positive_revision_limit!(revisions)

      {{:ok, mode}, _revisions} ->
        Mix.raise("--planner-review must be prompt or jsonl-stdio, got: #{inspect(mode)}")
    end
  end

  defp require_positive_revision_limit!(value) when is_integer(value) and value > 0, do: :ok

  defp require_positive_revision_limit!(value) do
    Mix.raise("--planner-review-max-revisions must be a positive integer, got: #{inspect(value)}")
  end

  defp require_non_empty_path!(path, _flag) when is_binary(path) and byte_size(path) > 0, do: path

  defp require_non_empty_path!(path, flag) do
    Mix.raise("#{flag} must be a non-empty path, got: #{inspect(path)}")
  end

  defp write_log_line!(nil, _line), do: :ok

  defp write_log_line!(io, line) do
    IO.write(io, [line, ?\n])
  end

  defp attrs_from_opts(opts, positional) do
    workflow = workflow_from_opts!(opts)

    %{
      task: task_from_positional!(positional),
      workflow: workflow,
      recent_context: Keyword.get(opts, :recent_context),
      pending_action: Keyword.get(opts, :pending_action),
      provider: provider_from_opts!(opts),
      provider_options: provider_options_from_opts!(opts),
      model: Keyword.get(opts, :model),
      timeout_ms: fetch_required_option!(opts, :timeout_ms),
      max_steps: fetch_required_option!(opts, :max_steps),
      max_attempts: fetch_required_option!(opts, :max_attempts),
      agentic_persistence_rounds: Keyword.get(opts, :agentic_persistence_rounds),
      planner_review_mode: planner_review_mode_from_opts!(opts),
      planner_review_max_revisions: Keyword.get(opts, :planner_review_max_revisions),
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
      stream_response: Keyword.get(opts, :stream_response, false),
      progress_observer: Keyword.get(opts, :progress_observer, false),
      context_window_tokens: Keyword.get(opts, :context_window_tokens),
      context_warning_percent: Keyword.get(opts, :context_warning_percent),
      context_tokenizer_path: Keyword.get(opts, :context_tokenizer_path),
      reserved_output_tokens: Keyword.get(opts, :reserved_output_tokens),
      run_context_compaction: run_context_compaction_from_opts!(opts),
      run_context_compact_percent: Keyword.get(opts, :run_context_compact_percent),
      max_context_compactions: Keyword.get(opts, :max_context_compactions),
      router_mode: router_mode_from_opts!(opts),
      router_model_dir: Keyword.get(opts, :router_model_dir),
      router_timeout_ms: Keyword.get(opts, :router_timeout_ms),
      router_confidence_threshold: Keyword.get(opts, :router_confidence_threshold)
    }
  end

  defp task_from_positional!([task]) when is_binary(task) and byte_size(task) > 0, do: task

  defp task_from_positional!(positional) do
    Mix.raise("expected exactly one non-empty task argument, got: #{inspect(positional)}")
  end

  defp planner_review_mode_from_opts!(opts) do
    case Keyword.fetch(opts, :planner_review) do
      {:ok, "prompt"} -> :prompt
      {:ok, "jsonl-stdio"} -> :jsonl_stdio
      :error -> nil
    end
  end

  defp workflow_from_opts!(opts) do
    case Keyword.fetch(opts, :workflow) do
      {:ok, "agentic"} ->
        :agentic

      {:ok, workflow} ->
        Mix.raise("--workflow must be agentic or omitted, got: #{inspect(workflow)}")

      :error ->
        :agentic
    end
  end

  defp provider_from_opts!(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, "echo"} ->
        :echo

      {:ok, provider} ->
        AgentMachine.ProviderCatalog.fetch!(provider)
        provider

      :error ->
        Mix.raise("missing required --provider option")
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

  defp tool_harnesses_from_opts!(opts) do
    case Keyword.get_values(opts, :tool_harness) do
      [] -> nil
      harnesses -> Enum.map(harnesses, &tool_harness_from_string!/1)
    end
  end

  defp tool_harness_from_string!("demo"), do: :demo
  defp tool_harness_from_string!("time"), do: :time
  defp tool_harness_from_string!("local-files"), do: :local_files
  defp tool_harness_from_string!("code-edit"), do: :code_edit
  defp tool_harness_from_string!("mcp"), do: :mcp
  defp tool_harness_from_string!("skills"), do: :skills

  defp tool_harness_from_string!(harness) do
    Mix.raise(
      "--tool-harness must be demo, time, local-files, code-edit, mcp, or skills, got: #{inspect(harness)}"
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

  defp router_mode_from_opts!(opts) do
    case Keyword.fetch(opts, :router_mode) do
      {:ok, "deterministic"} ->
        :deterministic

      {:ok, "llm"} ->
        :llm

      {:ok, "local"} ->
        :local

      {:ok, mode} ->
        Mix.raise("--router-mode must be deterministic, llm, or local, got: #{inspect(mode)}")

      :error ->
        :llm
    end
  end

  defp run_context_compaction_from_opts!(opts) do
    case Keyword.fetch(opts, :run_context_compaction) do
      {:ok, "on"} ->
        :on

      {:ok, "off"} ->
        :off

      {:ok, mode} ->
        Mix.raise("--run-context-compaction must be on or off, got: #{inspect(mode)}")

      :error ->
        :off
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
    print_execution_strategy(summary.execution_strategy || summary.workflow_route)
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

  defp print_execution_strategy(nil), do: :ok

  defp print_execution_strategy(%{requested: requested, selected: selected} = route) do
    Mix.shell().info("Execution strategy: #{requested} -> #{selected}")
    Mix.shell().info("  reason: #{Map.get(route, :reason) || "(none)"}")
    Mix.shell().info("  strategy: #{Map.get(route, :strategy) || "(none)"}")
    Mix.shell().info("  tool intent: #{Map.get(route, :tool_intent) || "(none)"}")
    Mix.shell().info("  tools exposed: #{Map.get(route, :tools_exposed)}")
    Mix.shell().info("  classifier: #{Map.get(route, :classifier) || "(none)"}")
    Mix.shell().info("  classifier model: #{Map.get(route, :classifier_model) || "(none)"}")
    Mix.shell().info("  classified intent: #{Map.get(route, :classified_intent) || "(none)"}")
    Mix.shell().info("  confidence: #{Map.get(route, :confidence) || "(none)"}")
  end

  defp prompt_planner_review(context) do
    IO.puts(:stderr, "")
    IO.puts(:stderr, "Planner review requested: #{Map.fetch!(context, :request_id)}")
    IO.puts(:stderr, "Planner: #{Map.fetch!(context, :planner_id)}")
    IO.puts(:stderr, "Reason: #{Map.get(context, :reason) || "(none)"}")
    IO.puts(:stderr, "Proposed workers:")

    context
    |> Map.get(:proposed_agents, [])
    |> Enum.each(fn agent ->
      depends_on = Map.get(agent, :depends_on, [])
      input = Map.get(agent, :input, "")
      suffix = if depends_on == [], do: "", else: " depends_on=#{Enum.join(depends_on, ",")}"
      IO.puts(:stderr, "  - #{Map.fetch!(agent, :id)}#{suffix}: #{input}")
    end)

    prompt_planner_review_decision()
  end

  defp prompt_planner_review_decision do
    IO.write(:stderr, "Approve, decline, or revise? [a/d/r] ")

    case read_prompt_line() do
      "a" ->
        {:approved, "approved from terminal prompt"}

      "approve" ->
        {:approved, "approved from terminal prompt"}

      "d" ->
        {:denied, "declined from terminal prompt"}

      "decline" ->
        {:denied, "declined from terminal prompt"}

      "r" ->
        prompt_planner_review_feedback()

      "revise" ->
        prompt_planner_review_feedback()

      other ->
        IO.puts(:stderr, "Expected a, d, or r; got #{inspect(other)}")
        prompt_planner_review_decision()
    end
  end

  defp prompt_planner_review_feedback do
    IO.write(:stderr, "Revision feedback: ")

    case read_prompt_line() do
      "" ->
        IO.puts(:stderr, "Revision feedback must be non-empty")
        prompt_planner_review_feedback()

      feedback ->
        {:revision_requested, feedback}
    end
  end

  defp read_prompt_line do
    case IO.read(:stdio, :line) do
      data when is_binary(data) -> data |> String.trim()
      :eof -> raise "planner review prompt input reached EOF"
      {:error, reason} -> raise "planner review prompt input failed: #{inspect(reason)}"
    end
  end
end
