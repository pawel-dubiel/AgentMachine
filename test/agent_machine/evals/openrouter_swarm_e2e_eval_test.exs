defmodule AgentMachine.OpenRouterSwarmE2EEvalTest do
  use ExUnit.Case, async: false

  alias AgentMachine.ClientRunner

  @moduletag :paid_openrouter_swarm_e2e_eval
  @moduletag timeout: 3_600_000

  @models [
    "moonshotai/kimi-k2.6",
    "openai/gpt-oss-120b",
    "stepfun/step-3.5-flash"
  ]

  @pricing %{input_per_million: 0.0, output_per_million: 0.0}
  @variant_ids ["experimental", "minimal", "robust"]
  @test_command "elixir sort_check.exs"

  setup_all do
    unless System.get_env("AGENT_MACHINE_PAID_SWARM_E2E") == "1" do
      flunk("AGENT_MACHINE_PAID_SWARM_E2E=1 is required for paid swarm e2e evals")
    end

    case System.fetch_env("OPENROUTER_API_KEY") do
      {:ok, key} when byte_size(key) > 0 ->
        :ok

      _missing ->
        flunk("OPENROUTER_API_KEY is required for paid OpenRouter swarm e2e evals")
    end
  end

  test "models complete full swarm planning, tool use, evaluation, and finalization" do
    reports = Enum.map(@models, &evaluate_model/1)

    IO.puts("\n" <> format_reports(reports))

    failures = Enum.reject(reports, &(&1.status == :passed))

    assert failures == [],
           "paid OpenRouter swarm e2e eval failures:\n#{format_reports(reports)}\n\n#{inspect(failures, pretty: true)}"
  end

  defp evaluate_model(model) do
    root = paid_tmp_root!(model)
    parent = self()
    flush_approval_contexts()

    on_exit(fn -> File.rm_rf(root) end)

    callback = fn context ->
      send(parent, {:swarm_e2e_approval_context, model, context})

      if valid_approval_context?(context) do
        :approved
      else
        {:denied, "swarm e2e eval only approves swarm variant write/command requests"}
      end
    end

    summary =
      try do
        {:ok,
         ClientRunner.run!(
           %{
             task: swarm_task(),
             workflow: :agentic,
             provider: :openrouter,
             model: model,
             timeout_ms: 480_000,
             max_steps: 8,
             max_attempts: 1,
             http_timeout_ms: 240_000,
             pricing: @pricing,
             tool_harnesses: [:code_edit],
             tool_root: root,
             tool_timeout_ms: 90_000,
             tool_max_rounds: 8,
             tool_approval_mode: :ask_before_write,
             test_commands: [@test_command]
           },
           tool_approval_callback: callback
         )}
      rescue
        exception ->
          {:error, Exception.message(exception)}
      end

    approvals = drain_approval_contexts(model, [])
    report = build_report(model, root, approvals, summary)
    File.rm_rf(root)
    report
  end

  defp swarm_task do
    """
    Use swarm to build exactly three isolated Elixir sorting variants:
    minimal, robust, and experimental.

    Each variant must create sort_check.exs in its own assigned workspace using apply_patch.
    Filesystem and code-edit tools are rooted at the assigned workspace, so variants should
    write relative path sort_check.exs and should not include the workspace path in the patch.

    Each sort_check.exs must define a sorting function and executable checks for:
    empty list, singleton list, already sorted list, negatives, duplicates, and mixed integers.

    After writing the file, each variant must run exactly:
    #{@test_command}

    The evaluator must compare correctness, simplicity, maintainability, testability, risk,
    and recommend one variant. Do not merge anything back to the original project.
    """
    |> String.trim()
  end

  defp build_report(model, root, approvals, {:error, error}) do
    %{
      model: model,
      status: :failed,
      failure_stage: :exception,
      error: error,
      planner_json_valid?: false,
      variants_created: [],
      apply_patch_calls: 0,
      apply_patch_successes: 0,
      run_test_command_calls: 0,
      command_passes: 0,
      evaluator_ran?: false,
      finalizer_ran?: false,
      root_escape_detected?: root_escape_detected?(root),
      approval_requests: length(approvals)
    }
  end

  defp build_report(model, root, approvals, {:ok, summary}) do
    report = %{
      model: model,
      summary_status: summary.status,
      error: summary.error,
      planner_json_valid?: planner_json_valid?(summary),
      variants_created: variants_created(summary),
      apply_patch_calls: count_tool_events(summary, "tool_call_started", "apply_patch"),
      apply_patch_successes: count_tool_events(summary, "tool_call_finished", "apply_patch"),
      run_test_command_calls: count_tool_events(summary, "tool_call_started", "run_test_command"),
      command_passes: count_command_passes(summary),
      evaluator_ran?: evaluator_ran?(summary),
      finalizer_ran?: finalizer_ran?(summary),
      root_escape_detected?: root_escape_detected?(root),
      approval_requests: length(approvals)
    }

    failure_stage = failure_stage(report)

    report
    |> Map.put(:failure_stage, failure_stage)
    |> Map.put(:status, if(is_nil(failure_stage), do: :passed, else: :failed))
  end

  defp failure_stage(report) do
    checks = [
      {:run, report.summary_status == "completed"},
      {:planner, report.planner_json_valid?},
      {:planner, Enum.sort(report.variants_created) == @variant_ids},
      {:variant_tools, report.apply_patch_successes >= 3},
      {:variant_tools, report.run_test_command_calls >= 3},
      {:tests, report.command_passes >= 3},
      {:evaluator, report.evaluator_ran?},
      {:finalizer, report.finalizer_ran?},
      {:workspace_isolation, not report.root_escape_detected?}
    ]

    checks
    |> Enum.find_value(fn {stage, passed?} -> if passed?, do: nil, else: stage end)
  end

  defp planner_json_valid?(summary) do
    summary.workflow_route.selected == "agentic" and
      summary.workflow_route.strategy == "swarm" and
      get_in(summary.results, ["planner", :decision, :mode]) == "swarm"
  end

  defp variants_created(summary) do
    summary.events
    |> Enum.filter(fn event ->
      event[:type] == "agent_started" and event[:agent_machine_role] == "swarm_variant"
    end)
    |> Enum.map(& &1[:variant_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp count_tool_events(summary, event_type, tool_name) do
    Enum.count(summary.events, fn event ->
      event[:type] == event_type and event[:tool] == tool_name and
        event[:agent_machine_role] == "swarm_variant"
    end)
  end

  defp count_command_passes(summary) do
    summary.results
    |> Map.values()
    |> Enum.flat_map(fn result ->
      result
      |> Map.get(:tool_results, %{})
      |> Map.values()
    end)
    |> Enum.count(&exit_status_zero?/1)
  end

  defp exit_status_zero?(%{exit_status: 0}), do: true
  defp exit_status_zero?(%{"exit_status" => 0}), do: true
  defp exit_status_zero?(_result), do: false

  defp evaluator_ran?(summary) do
    Enum.any?(summary.events, fn event ->
      event[:type] == "agent_finished" and event[:agent_machine_role] == "swarm_evaluator" and
        event[:status] == "ok"
    end)
  end

  defp finalizer_ran?(summary), do: get_in(summary.results, ["finalizer", :status]) == "ok"

  defp root_escape_detected?(root) do
    root
    |> File.ls!()
    |> Enum.reject(&(&1 == ".agent_machine"))
    |> Enum.any?()
  end

  defp valid_approval_context?(context) when is_map(context) do
    context.agent_machine_role == "swarm_variant" and
      is_binary(context.swarm_id) and context.swarm_id != "" and
      context.variant_id in @variant_ids and
      is_binary(context.workspace) and
      String.contains?(context.workspace, ".agent_machine/swarm/") and
      context.risk in [:write, :command] and
      context.tool in [AgentMachine.Tools.ApplyPatch, AgentMachine.Tools.RunTestCommand]
  end

  defp flush_approval_contexts do
    receive do
      {:swarm_e2e_approval_context, _model, _context} -> flush_approval_contexts()
    after
      0 -> :ok
    end
  end

  defp drain_approval_contexts(model, acc) do
    receive do
      {:swarm_e2e_approval_context, ^model, context} ->
        drain_approval_contexts(model, [context | acc])

      {:swarm_e2e_approval_context, _other_model, _context} ->
        drain_approval_contexts(model, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp paid_tmp_root!(model) do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-swarm-e2e-#{safe_model_name(model)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end

  defp safe_model_name(model) do
    String.replace(model, ~r/[^a-zA-Z0-9_.-]+/, "-")
  end

  defp format_reports(reports) do
    rows =
      Enum.map(reports, fn report ->
        [
          report.model,
          report.status,
          report.failure_stage || "-",
          report.planner_json_valid?,
          Enum.join(report.variants_created, ","),
          report.apply_patch_calls,
          report.apply_patch_successes,
          report.run_test_command_calls,
          report.command_passes,
          report.evaluator_ran?,
          report.finalizer_ran?,
          report.root_escape_detected?,
          report.approval_requests,
          report[:error] || ""
        ]
      end)

    headers = [
      "model",
      "status",
      "failure_stage",
      "planner_json",
      "variants",
      "patch_calls",
      "patch_ok",
      "test_calls",
      "test_ok",
      "evaluator",
      "finalizer",
      "root_escape",
      "approvals",
      "error"
    ]

    format_table([headers | rows])
  end

  defp format_table(rows) do
    widths =
      rows
      |> Enum.zip()
      |> Enum.map(fn values ->
        values
        |> Tuple.to_list()
        |> Enum.map(&(&1 |> to_string() |> String.length()))
        |> Enum.max()
      end)

    Enum.map_join(rows, "\n", &format_row(&1, widths))
  end

  defp format_row(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map_join(" | ", fn {value, width} ->
      value |> to_string() |> String.pad_trailing(width)
    end)
  end
end
