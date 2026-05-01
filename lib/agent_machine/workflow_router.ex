defmodule AgentMachine.WorkflowRouter do
  @moduledoc false

  alias AgentMachine.{CapabilityRequired, RunSpec}

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
    :tool_root,
    :provider,
    :model,
    :pricing,
    :http_timeout_ms,
    :approval_mode,
    :test_commands,
    :pending_action,
    :recent_context,
    :mcp_config,
    router_mode: :deterministic,
    router_model_dir: nil,
    router_timeout_ms: nil,
    router_confidence_threshold: nil,
    classifier_module: AgentMachine.LocalIntentClassifier,
    llm_router_module: AgentMachine.LLMRouter
  ]

  def route!(%RunSpec{} = spec) do
    %__MODULE__{
      requested_workflow: spec.workflow,
      task: spec.task,
      tool_harnesses: spec.tool_harnesses || [],
      tool_root: spec.tool_root,
      provider: spec.provider,
      model: spec.model,
      pricing: spec.pricing,
      http_timeout_ms: spec.http_timeout_ms,
      approval_mode: spec.tool_approval_mode,
      test_commands: spec.test_commands || [],
      pending_action: nil,
      recent_context: nil,
      mcp_config: spec.mcp_config,
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
    swarm? = swarm_requested?(input)

    route(
      :agentic,
      :agentic,
      if(swarm?,
        do: "user_requested_multiple_solution_variants",
        else: "explicit_agentic_workflow"
      ),
      intent,
      tools_configured?(input),
      deterministic_meta(intent),
      strategy_meta(swarm?)
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

    if swarm_requested?(input) do
      route_auto_swarm_intent(input, classified)
    else
      route_auto_intent(input, classified.intent, classified)
    end
  end

  defp route_auto_swarm_intent(input, classified) do
    intent = Map.fetch!(classified, :intent)
    require_swarm_capability!(input, intent)

    route(
      :auto,
      :agentic,
      "user_requested_multiple_solution_variants",
      intent,
      swarm_tools_exposed?(input, intent),
      classifier_meta(classified),
      %{strategy: "swarm"}
    )
  end

  defp route_auto_intent(_input, :none, classified) do
    route(:auto, :chat, none_reason(classified), :none, false, classifier_meta(classified))
  end

  defp route_auto_intent(input, :delegation, classified) do
    route(
      :auto,
      :agentic,
      "explicit_delegation_intent",
      :delegation,
      tools_configured?(input),
      classifier_meta(classified)
    )
  end

  defp route_auto_intent(input, :file_read, classified) do
    require_read_capability!(input)

    route(
      :auto,
      :tool,
      "read_intent_with_read_only_tool",
      :file_read,
      true,
      classifier_meta(classified)
    )
  end

  defp route_auto_intent(input, :time, classified), do: route_time_intent(input, classified)

  defp route_auto_intent(input, :web_browse, classified) do
    if local_web_browse_without_target?(input, classified) do
      route(
        :auto,
        :chat,
        "local_classifier_web_browse_without_web_target",
        :none,
        false,
        classifier_meta(classified)
      )
    else
      require_browser_mcp_capability!(input)

      route(
        :auto,
        :agentic,
        "web_browse_intent_with_mcp_browser",
        :web_browse,
        true,
        classifier_meta(classified)
      )
    end
  end

  defp route_auto_intent(input, :tool_use, classified) do
    if shell_capable_code_edit?(input) do
      route(
        :auto,
        :agentic,
        "tool_intent_with_code_edit_shell",
        :tool_use,
        true,
        classifier_meta(classified)
      )
    else
      require_read_only_tool_capability!(input, :tool_use)

      route(
        :auto,
        :tool,
        "tool_intent_with_read_only_tool",
        :tool_use,
        true,
        classifier_meta(classified)
      )
    end
  end

  defp route_auto_intent(input, :file_mutation, classified) do
    require_write_capability!(input)

    route(
      :auto,
      :agentic,
      write_reason(input),
      :file_mutation,
      true,
      classifier_meta(classified)
    )
  end

  defp route_auto_intent(input, :code_mutation, classified) do
    require_code_edit_capability!(input)

    route(
      :auto,
      :agentic,
      "code_mutation_intent_with_code_edit_harness",
      :code_mutation,
      true,
      classifier_meta(classified)
    )
  end

  defp route_auto_intent(input, :test_command, classified) do
    require_test_capability!(input)

    route(
      :auto,
      :agentic,
      test_reason(input),
      :test_command,
      true,
      classifier_meta(classified)
    )
  end

  defp route(
         requested,
         selected,
         reason,
         tool_intent,
         tools_exposed,
         classifier_meta,
         extra_meta \\ %{}
       ) do
    %{
      requested: Atom.to_string(requested),
      selected: Atom.to_string(selected),
      reason: reason,
      tool_intent: Atom.to_string(tool_intent),
      tools_exposed: tools_exposed
    }
    |> Map.merge(classifier_meta)
    |> Map.merge(extra_meta)
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
    |> maybe_apply_deterministic_guard(input)
  end

  defp classify_intent!(%__MODULE__{router_mode: :llm} = input) do
    input.llm_router_module.classify!(%{
      task: input.task,
      pending_action: input.pending_action,
      recent_context: input.recent_context,
      provider: input.provider,
      model: input.model,
      pricing: input.pricing,
      http_timeout_ms: input.http_timeout_ms
    })
    |> validate_classifier_result!()
    |> maybe_apply_deterministic_guard(input)
  end

  defp classify_intent!(%__MODULE__{router_mode: mode}) do
    raise ArgumentError,
          "workflow router :router_mode must be :deterministic, :local, or :llm, got: #{inspect(mode)}"
  end

  defp deterministic_intent(input) do
    text = effective_text(input)

    deterministic_intent_rules()
    |> Enum.find_value(:none, fn {intent, predicate} ->
      if predicate.(text), do: intent
    end)
  end

  defp deterministic_intent_rules do
    [
      delegation: &delegation_intent?/1,
      test_command: &test_intent?/1,
      code_mutation: &code_mutation_intent?/1,
      file_mutation: &file_mutation_intent?/1,
      file_read: &file_read_intent?/1,
      time: &time_intent?/1,
      web_browse: &web_browse_intent?/1,
      tool_use: &tool_use_intent?/1
    ]
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
          "workflow router classifier must return a map, got: #{inspect(result)}"
  end

  defp maybe_apply_deterministic_guard(classified, input) do
    case deterministic_intent(input) do
      :none ->
        classified

      intent ->
        %{
          classified
          | intent: intent,
            reason: "local_classifier_guarded_by_deterministic_#{intent}_intent"
        }
    end
  end

  defp validate_classifier_intent!(intent, _field) when intent in @valid_intents, do: :ok

  defp validate_classifier_intent!(intent, field) do
    raise ArgumentError,
          "workflow router classifier returned invalid #{field}: #{inspect(intent)}"
  end

  defp validate_classifier_name!(classifier) when is_binary(classifier) and classifier != "",
    do: :ok

  defp validate_classifier_name!(classifier) do
    raise ArgumentError,
          "workflow router classifier returned invalid classifier: #{inspect(classifier)}"
  end

  defp validate_optional_binary!(nil, _field), do: :ok
  defp validate_optional_binary!(value, _field) when is_binary(value), do: :ok

  defp validate_optional_binary!(value, field) do
    raise ArgumentError,
          "workflow router classifier returned invalid #{field}: #{inspect(value)}"
  end

  defp validate_optional_number!(nil, _field), do: :ok
  defp validate_optional_number!(value, _field) when is_number(value), do: :ok

  defp validate_optional_number!(value, field) do
    raise ArgumentError,
          "workflow router classifier returned invalid #{field}: #{inspect(value)}"
  end

  defp classifier_meta(classified) do
    %{
      classifier: Map.fetch!(classified, :classifier),
      classifier_model: Map.get(classified, :classifier_model),
      confidence: Map.get(classified, :confidence),
      classified_intent: classified |> Map.fetch!(:classified_intent) |> Atom.to_string()
    }
  end

  defp none_reason(%{classifier: classifier, reason: reason})
       when classifier in ["local", "llm"] and is_binary(reason),
       do: reason

  defp none_reason(_classified), do: "no_tool_or_mutation_intent_detected"

  defp local_web_browse_without_target?(input, %{classifier: "local"}) do
    input
    |> effective_text()
    |> normalize()
    |> web_browse_target?()
    |> Kernel.not()
  end

  defp local_web_browse_without_target?(_input, _classified), do: false

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
    |> contains_any?([
      "use agents",
      "use agent",
      "spawn agents",
      "spawn agent",
      "start agents",
      "start agent",
      "create agents",
      "create agent",
      "use subagents",
      "use subagent",
      "spawn subagents",
      "spawn subagent",
      "delegate",
      "deleguj",
      "delegowac",
      "delegować",
      "uzyj agentow",
      "użyj agentów",
      "odpal agentow",
      "odpal agentów",
      "agentow",
      "agentów",
      "worker",
      "workers",
      "workerow",
      "workerów"
    ])
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

  defp web_browse_intent?(text) do
    normalized = normalize(text)

    web_action? =
      contains_any?(normalized, [
        "open",
        "access",
        "browse",
        "visit",
        "go to",
        "load",
        "read website",
        "read web",
        "inspect website",
        "inspect web",
        "google",
        "search google",
        "search web",
        "search the web",
        "research",
        "look up",
        "latest news",
        "news today",
        "latest headlines"
      ])

    web_action? and web_browse_target?(normalized)
  end

  defp swarm_requested?(input) do
    input
    |> effective_text()
    |> normalize()
    |> contains_any?([
      "swarm",
      "different versions",
      "multiple versions",
      "variants",
      "variant",
      "alternative implementations",
      "competing solutions",
      "try several approaches",
      "prototype several options",
      "prototype options"
    ])
  end

  defp web_browse_target?(normalized) do
    contains_any?(normalized, [
      "website",
      "webpage",
      "web page",
      "url",
      "browser",
      "playwright",
      "google",
      "news",
      "headlines",
      "http",
      "www.",
      "strona",
      "strone",
      "stronę",
      "przegladarka",
      "przeglądarka"
    ]) or normalized =~ ~r/\b[a-z0-9-]+\.(com|org|net|io|dev|app|pl|co|ai)\b/
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
      "fix",
      "repair",
      "rewrite"
    ])
  end

  defp code_reference?(text) do
    contains_any?(text, [
      "code",
      "patch",
      "lib/",
      "test/",
      ".py",
      ".ex",
      ".exs",
      ".go",
      ".js",
      ".ts",
      "python",
      "script",
      "weather_app.py",
      "nextjs",
      "next.js",
      "react",
      "vite",
      "package.json",
      "src/",
      "app/",
      "pages/",
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
      raise CapabilityRequired,
        reason: :missing_read_harness,
        intent: :file_read,
        required_harnesses: [:local_files, :code_edit]
    end
  end

  defp route_time_intent(input, classified) do
    cond do
      has_any_harness?(input, [:time, :demo]) ->
        route(
          :auto,
          :tool,
          "time_intent_with_read_only_tool",
          :time,
          true,
          classifier_meta(classified)
        )

      tools_configured?(input) ->
        route(
          :auto,
          :tool,
          "time_intent_with_read_only_tool",
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

  defp require_any_tool_capability!(input) do
    unless tools_configured?(input) do
      raise CapabilityRequired,
        reason: :missing_tool_harness,
        intent: :tool_use
    end
  end

  defp require_swarm_capability!(input, :file_read), do: require_read_capability!(input)
  defp require_swarm_capability!(input, :file_mutation), do: require_write_capability!(input)
  defp require_swarm_capability!(input, :code_mutation), do: require_code_edit_capability!(input)
  defp require_swarm_capability!(input, :test_command), do: require_test_capability!(input)
  defp require_swarm_capability!(input, :web_browse), do: require_browser_mcp_capability!(input)
  defp require_swarm_capability!(input, :tool_use), do: require_any_tool_capability!(input)
  defp require_swarm_capability!(_input, _intent), do: :ok

  defp require_read_only_tool_capability!(input, intent) do
    require_any_tool_capability!(input)

    AgentMachine.ToolHarness.read_only_many!(
      input.tool_harnesses,
      [mcp_config: input.mcp_config],
      intent
    )

    :ok
  rescue
    exception in ArgumentError ->
      reraise CapabilityRequired,
              [
                reason: :missing_read_only_tool_capability,
                intent: intent,
                detail: Exception.message(exception)
              ],
              __STACKTRACE__
  end

  defp require_write_capability!(input) do
    unless has_any_harness?(input, [:local_files, :code_edit]) do
      raise CapabilityRequired,
        reason: :missing_write_harness,
        intent: :file_mutation,
        required_harness: :local_files,
        required_harnesses: [:local_files, :code_edit],
        requested_root: input.tool_root
    end
  end

  defp require_code_edit_capability!(input) do
    unless has_any_harness?(input, [:code_edit]) do
      raise CapabilityRequired,
        reason: :missing_code_edit_harness,
        intent: :code_mutation,
        required_harness: :code_edit,
        requested_root: input.tool_root
    end
  end

  defp require_test_capability!(input) do
    cond do
      not has_any_harness?(input, [:code_edit]) ->
        raise CapabilityRequired,
          reason: :missing_test_code_edit_harness,
          intent: :test_command,
          required_harness: :code_edit,
          requested_root: input.tool_root

      input.approval_mode not in [:full_access, :ask_before_write] ->
        raise CapabilityRequired,
          reason: :missing_test_approval,
          intent: :test_command,
          required_harness: :code_edit,
          required_approval_modes: [:full_access, :ask_before_write],
          requested_root: input.tool_root

      input.test_commands == [] ->
        if shell_capable_code_edit?(input) do
          :ok
        else
          raise CapabilityRequired,
            reason: :missing_test_commands,
            intent: :test_command,
            required_harness: :code_edit,
            requested_root: input.tool_root
        end

      true ->
        :ok
    end
  end

  defp test_reason(input) do
    if input.test_commands == [] and shell_capable_code_edit?(input) do
      "test_intent_with_code_edit_shell"
    else
      "test_intent_with_code_edit_full_access"
    end
  end

  defp shell_capable_code_edit?(input) do
    has_any_harness?(input, [:code_edit]) and
      input.approval_mode in [:full_access, :ask_before_write]
  end

  defp require_browser_mcp_capability!(input) do
    unless has_browser_mcp_tool?(input) do
      raise CapabilityRequired,
        reason: :missing_browser_mcp,
        intent: :web_browse,
        required_harness: :mcp,
        required_mcp_tool: "browser_navigate"
    end

    if input.approval_mode not in [:full_access, :ask_before_write] do
      raise CapabilityRequired,
        reason: :missing_browser_approval,
        intent: :web_browse,
        required_harness: :mcp,
        required_approval_modes: [:full_access, :ask_before_write],
        required_mcp_tool: "browser_navigate"
    end
  end

  defp has_browser_mcp_tool?(%__MODULE__{tool_harnesses: harnesses, mcp_config: mcp_config}) do
    :mcp in harnesses and match?(%AgentMachine.MCP.Config{}, mcp_config) and
      Enum.any?(mcp_config.tools, fn tool ->
        tool.name == "browser_navigate" and
          tool.risk == :network and
          String.contains?(tool.provider_name, "playwright")
      end)
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

  defp swarm_tools_exposed?(_input, intent)
       when intent in [:file_read, :file_mutation, :code_mutation, :test_command, :web_browse],
       do: true

  defp swarm_tools_exposed?(input, _intent), do: tools_configured?(input)

  defp strategy_meta(true), do: %{strategy: "swarm"}
  defp strategy_meta(false), do: %{}

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
