defmodule AgentMachine.WorkflowRouter do
  @moduledoc false

  alias AgentMachine.RunSpec

  @valid_intents AgentMachine.LocalIntentClassifier.intents()

  @enforce_keys [
    :requested_workflow,
    :task,
    :tool_harnesses,
    :approval_mode,
    :test_commands,
    :pending_action,
    :recent_context
  ]
  defstruct [
    :requested_workflow,
    :task,
    :tool_harnesses,
    :approval_mode,
    :test_commands,
    :pending_action,
    :recent_context,
    router_mode: :deterministic,
    router_model_dir: nil,
    router_timeout_ms: nil,
    router_confidence_threshold: nil,
    classifier_module: AgentMachine.LocalIntentClassifier
  ]

  def route!(%RunSpec{} = spec) do
    %__MODULE__{
      requested_workflow: spec.workflow,
      task: spec.task,
      tool_harnesses: spec.tool_harnesses || [],
      approval_mode: spec.tool_approval_mode,
      test_commands: spec.test_commands || [],
      pending_action: nil,
      recent_context: nil,
      router_mode: spec.router_mode,
      router_model_dir: spec.router_model_dir,
      router_timeout_ms: spec.router_timeout_ms,
      router_confidence_threshold: spec.router_confidence_threshold
    }
    |> route!()
  end

  def route!(%__MODULE__{requested_workflow: :chat} = input) do
    reject_chat_tools!(input)
    route(:chat, :chat, "explicit_chat_workflow", :none, false, deterministic_meta(:none))
  end

  def route!(%__MODULE__{requested_workflow: :basic} = input) do
    intent = deterministic_intent(input)

    route(
      :basic,
      :basic,
      "explicit_basic_workflow",
      intent,
      tools_configured?(input),
      deterministic_meta(intent)
    )
  end

  def route!(%__MODULE__{requested_workflow: :agentic} = input) do
    intent = deterministic_intent(input)

    route(
      :agentic,
      :agentic,
      "explicit_agentic_workflow",
      intent,
      tools_configured?(input),
      deterministic_meta(intent)
    )
  end

  def route!(%__MODULE__{requested_workflow: :auto} = input), do: route_auto!(input)

  def route!(%__MODULE__{requested_workflow: workflow}) do
    raise ArgumentError,
          "workflow router requested_workflow must be :chat, :basic, :agentic, or :auto, got: #{inspect(workflow)}"
  end

  def route!(other) do
    raise ArgumentError,
          "workflow router input must be a RunSpec or WorkflowRouter struct, got: #{inspect(other)}"
  end

  defp route_auto!(input) do
    classified = classify_intent!(input)

    case classified.intent do
      :none ->
        route(:auto, :chat, none_reason(classified), :none, false, classifier_meta(classified))

      :delegation ->
        route(
          :auto,
          :agentic,
          "explicit_delegation_intent",
          :delegation,
          tools_configured?(input),
          classifier_meta(classified)
        )

      :file_read ->
        require_read_capability!(input)

        route(
          :auto,
          :basic,
          "read_intent_with_filesystem_harness",
          :file_read,
          true,
          classifier_meta(classified)
        )

      :time ->
        route_time_intent(input, classified)

      :tool_use ->
        require_any_tool_capability!(input)

        route(
          :auto,
          :basic,
          "tool_intent_with_configured_harness",
          :tool_use,
          true,
          classifier_meta(classified)
        )

      :file_mutation ->
        require_write_capability!(input)

        route(
          :auto,
          :agentic,
          write_reason(input),
          :file_mutation,
          true,
          classifier_meta(classified)
        )

      :code_mutation ->
        require_code_edit_capability!(input)

        route(
          :auto,
          :agentic,
          "code_mutation_intent_with_code_edit_harness",
          :code_mutation,
          true,
          classifier_meta(classified)
        )

      :test_command ->
        require_test_capability!(input)

        route(
          :auto,
          :agentic,
          "test_intent_with_code_edit_full_access",
          :test_command,
          true,
          classifier_meta(classified)
        )
    end
  end

  defp route(requested, selected, reason, tool_intent, tools_exposed, classifier_meta) do
    %{
      requested: Atom.to_string(requested),
      selected: Atom.to_string(selected),
      reason: reason,
      tool_intent: Atom.to_string(tool_intent),
      tools_exposed: tools_exposed
    }
    |> Map.merge(classifier_meta)
  end

  defp reject_chat_tools!(input) do
    if tools_configured?(input) do
      raise ArgumentError, "workflow :chat does not accept tool harness options"
    end
  end

  defp classify_intent!(%__MODULE__{router_mode: :deterministic} = input) do
    intent = deterministic_intent(input)

    %{
      intent: intent,
      classified_intent: intent,
      classifier: "deterministic",
      classifier_model: nil,
      confidence: nil,
      reason: "deterministic_intent_rules"
    }
  end

  defp classify_intent!(%__MODULE__{router_mode: :local} = input) do
    input.classifier_module.classify!(%{
      task: input.task,
      pending_action: input.pending_action,
      recent_context: input.recent_context,
      model_dir: input.router_model_dir,
      timeout_ms: input.router_timeout_ms,
      confidence_threshold: input.router_confidence_threshold
    })
    |> validate_classifier_result!()
  end

  defp classify_intent!(%__MODULE__{router_mode: mode}) do
    raise ArgumentError,
          "workflow router :router_mode must be :deterministic or :local, got: #{inspect(mode)}"
  end

  defp deterministic_intent(input) do
    text = effective_text(input)

    cond do
      delegation_intent?(text) -> :delegation
      test_intent?(text) -> :test_command
      code_mutation_intent?(text) -> :code_mutation
      file_mutation_intent?(text) -> :file_mutation
      file_read_intent?(text) -> :file_read
      time_intent?(text) -> :time
      tool_use_intent?(text) -> :tool_use
      true -> :none
    end
  end

  defp deterministic_meta(intent) do
    %{
      classifier: "deterministic",
      classifier_model: nil,
      confidence: nil,
      classified_intent: Atom.to_string(intent)
    }
  end

  defp validate_classifier_result!(%{} = result) do
    intent = Map.get(result, :intent)
    classified_intent = Map.get(result, :classified_intent)
    classifier = Map.get(result, :classifier)
    classifier_model = Map.get(result, :classifier_model)
    confidence = Map.get(result, :confidence)
    reason = Map.get(result, :reason)

    validate_classifier_intent!(intent, :intent)
    validate_classifier_intent!(classified_intent, :classified_intent)
    validate_classifier_name!(classifier)
    validate_optional_binary!(classifier_model, :classifier_model)
    validate_optional_number!(confidence, :confidence)
    validate_optional_binary!(reason, :reason)

    %{
      intent: intent,
      classified_intent: classified_intent,
      classifier: classifier,
      classifier_model: classifier_model,
      confidence: confidence,
      reason: reason
    }
  end

  defp validate_classifier_result!(result) do
    raise ArgumentError,
          "local router classifier must return a map, got: #{inspect(result)}"
  end

  defp validate_classifier_intent!(intent, _field) when intent in @valid_intents, do: :ok

  defp validate_classifier_intent!(intent, field) do
    raise ArgumentError,
          "local router classifier returned invalid #{field}: #{inspect(intent)}"
  end

  defp validate_classifier_name!(classifier) when is_binary(classifier) and classifier != "",
    do: :ok

  defp validate_classifier_name!(classifier) do
    raise ArgumentError,
          "local router classifier returned invalid classifier: #{inspect(classifier)}"
  end

  defp validate_optional_binary!(nil, _field), do: :ok
  defp validate_optional_binary!(value, _field) when is_binary(value), do: :ok

  defp validate_optional_binary!(value, field) do
    raise ArgumentError,
          "local router classifier returned invalid #{field}: #{inspect(value)}"
  end

  defp validate_optional_number!(nil, _field), do: :ok
  defp validate_optional_number!(value, _field) when is_number(value), do: :ok

  defp validate_optional_number!(value, field) do
    raise ArgumentError,
          "local router classifier returned invalid #{field}: #{inspect(value)}"
  end

  defp classifier_meta(classified) do
    %{
      classifier: Map.fetch!(classified, :classifier),
      classifier_model: Map.get(classified, :classifier_model),
      confidence: Map.get(classified, :confidence),
      classified_intent: classified |> Map.fetch!(:classified_intent) |> Atom.to_string()
    }
  end

  defp none_reason(%{classifier: "local", reason: reason}) when is_binary(reason), do: reason
  defp none_reason(_classified), do: "no_tool_or_mutation_intent_detected"

  defp effective_text(%__MODULE__{task: task, pending_action: pending_action})
       when is_binary(pending_action) do
    if affirmative_followup?(task), do: pending_action <> "\n" <> task, else: task
  end

  defp effective_text(%__MODULE__{task: task, recent_context: recent_context})
       when is_binary(recent_context) do
    if contextual_followup?(task), do: recent_context <> "\n" <> task, else: task
  end

  defp effective_text(%__MODULE__{task: task}) when is_binary(task), do: task

  defp affirmative_followup?(text) when is_binary(text) do
    normalized = normalize(text)
    normalized in ["yes", "yes do it", "do it", "go ahead", "ok", "okay", "please do it"]
  end

  defp contextual_followup?(text) when is_binary(text) do
    normalized = normalize(text)

    contains_any?(normalized, [
      "this file",
      "that file",
      "this dir",
      "that dir",
      "this directory",
      "that directory",
      "inside this",
      "inside that"
    ])
  end

  defp delegation_intent?(text) do
    text
    |> normalize()
    |> contains_any?(["use agents", "use subagents", "delegate", "worker", "workers"])
  end

  defp test_intent?(text) do
    normalized = normalize(text)

    contains_any?(normalized, [
      "run test",
      "run tests",
      "mix test",
      "go test",
      "npm test",
      "cargo test",
      "pytest"
    ])
  end

  defp code_mutation_intent?(text) do
    normalized = normalize(text)
    mutation_intent?(normalized) and code_reference?(normalized)
  end

  defp file_mutation_intent?(text) do
    normalized = normalize(text)
    mutation_intent?(normalized) and file_reference?(normalized)
  end

  defp file_read_intent?(text) do
    normalized = normalize(text)

    contains_any?(normalized, [
      "read ",
      "list ",
      "show ",
      "check ",
      "look ",
      "look at ",
      "review ",
      "analyze ",
      "search ",
      "find ",
      "inspect ",
      "what does this file",
      "what does the file",
      "inside this dir",
      "inside this directory"
    ]) and file_reference?(normalized)
  end

  defp time_intent?(text) do
    text
    |> normalize()
    |> contains_any?(["what time", "current time", "time is it", "today's date", "current date"])
  end

  defp tool_use_intent?(text) do
    text
    |> normalize()
    |> contains_any?(["use tool", "call tool", "with mcp", "using mcp"])
  end

  defp mutation_intent?(text) do
    contains_any?(text, [
      "create",
      "make",
      "write",
      "append",
      "replace",
      "edit",
      "update",
      "delete",
      "remove",
      "rename",
      "patch",
      "fix"
    ])
  end

  defp code_reference?(text) do
    contains_any?(text, [
      "code",
      "patch",
      "lib/",
      "test/",
      ".ex",
      ".exs",
      ".go",
      ".js",
      ".ts",
      "mix.exs"
    ])
  end

  defp file_reference?(text) do
    contains_any?(text, [
      "file",
      "folder",
      "directory",
      "dir",
      "path",
      "readme",
      ".md",
      ".txt",
      ".json",
      ".html",
      "~/",
      "/users/",
      "/tmp/"
    ])
  end

  defp require_read_capability!(input) do
    unless has_any_harness?(input, [:local_files, :code_edit]) do
      raise ArgumentError,
            "auto workflow detected local read/search intent but no read-capable tool harness is configured"
    end
  end

  defp route_time_intent(input, classified) do
    cond do
      has_any_harness?(input, [:time, :demo]) ->
        route(
          :auto,
          :basic,
          time_reason(input),
          :time,
          true,
          classifier_meta(classified)
        )

      tools_configured?(input) ->
        route(
          :auto,
          :basic,
          "time_intent_with_auto_time_harness",
          :time,
          true,
          classifier_meta(classified)
        )

      true ->
        route(
          :auto,
          :chat,
          "time_intent_without_time_harness",
          :time,
          false,
          classifier_meta(classified)
        )
    end
  end

  defp time_reason(input) do
    if has_any_harness?(input, [:time]) do
      "time_intent_with_time_harness"
    else
      "time_intent_with_demo_harness"
    end
  end

  defp require_any_tool_capability!(input) do
    unless tools_configured?(input) do
      raise ArgumentError,
            "auto workflow detected tool intent but no tool harness is configured"
    end
  end

  defp require_write_capability!(input) do
    unless has_any_harness?(input, [:local_files, :code_edit]) do
      raise ArgumentError,
            "auto workflow detected mutation intent but no write-capable tool harness is configured"
    end
  end

  defp require_code_edit_capability!(input) do
    unless has_any_harness?(input, [:code_edit]) do
      raise ArgumentError,
            "auto workflow detected code mutation intent but :code_edit tool harness is not configured"
    end
  end

  defp require_test_capability!(input) do
    cond do
      not has_any_harness?(input, [:code_edit]) ->
        raise ArgumentError,
              "auto workflow detected test intent but :code_edit tool harness is not configured"

      input.approval_mode != :full_access ->
        raise ArgumentError,
              "auto workflow detected test intent but :tool_approval_mode must be :full_access"

      input.test_commands == [] ->
        raise ArgumentError,
              "auto workflow detected test intent but no allowlisted :test_commands are configured"

      true ->
        :ok
    end
  end

  defp write_reason(input) do
    if has_any_harness?(input, [:code_edit]) do
      "filesystem_mutation_intent_with_code_edit_harness"
    else
      "filesystem_mutation_intent_with_local_files_harness"
    end
  end

  defp has_any_harness?(%__MODULE__{tool_harnesses: harnesses}, expected),
    do: Enum.any?(harnesses, &(&1 in expected))

  defp tools_configured?(%__MODULE__{tool_harnesses: harnesses}), do: harnesses != []

  defp normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\/\.\-_~]+/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))
end
