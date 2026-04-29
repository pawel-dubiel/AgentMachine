defmodule AgentMachine.WorkflowRouter do
  @moduledoc false

  alias AgentMachine.RunSpec

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
    :recent_context
  ]

  def route!(%RunSpec{} = spec) do
    %__MODULE__{
      requested_workflow: spec.workflow,
      task: spec.task,
      tool_harnesses: spec.tool_harnesses || [],
      approval_mode: spec.tool_approval_mode,
      test_commands: spec.test_commands || [],
      pending_action: nil,
      recent_context: nil
    }
    |> route!()
  end

  def route!(%__MODULE__{requested_workflow: :chat} = input) do
    reject_chat_tools!(input)
    route(:chat, :chat, "explicit_chat_workflow", :none, false)
  end

  def route!(%__MODULE__{requested_workflow: :basic} = input) do
    route(:basic, :basic, "explicit_basic_workflow", intent(input), tools_configured?(input))
  end

  def route!(%__MODULE__{requested_workflow: :agentic} = input) do
    route(
      :agentic,
      :agentic,
      "explicit_agentic_workflow",
      intent(input),
      tools_configured?(input)
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
    case intent(input) do
      :none ->
        route(:auto, :chat, "no_tool_or_mutation_intent_detected", :none, false)

      :delegation ->
        route(
          :auto,
          :agentic,
          "explicit_delegation_intent",
          :delegation,
          tools_configured?(input)
        )

      :file_read ->
        require_read_capability!(input)
        route(:auto, :basic, "read_intent_with_filesystem_harness", :file_read, true)

      :time ->
        require_demo_capability!(input)
        route(:auto, :basic, "time_intent_with_demo_harness", :time, true)

      :tool_use ->
        require_any_tool_capability!(input)
        route(:auto, :basic, "tool_intent_with_configured_harness", :tool_use, true)

      :file_mutation ->
        require_write_capability!(input)
        route(:auto, :agentic, write_reason(input), :file_mutation, true)

      :code_mutation ->
        require_code_edit_capability!(input)

        route(
          :auto,
          :agentic,
          "code_mutation_intent_with_code_edit_harness",
          :code_mutation,
          true
        )

      :test_command ->
        require_test_capability!(input)
        route(:auto, :agentic, "test_intent_with_code_edit_full_access", :test_command, true)
    end
  end

  defp route(requested, selected, reason, tool_intent, tools_exposed) do
    %{
      requested: Atom.to_string(requested),
      selected: Atom.to_string(selected),
      reason: reason,
      tool_intent: Atom.to_string(tool_intent),
      tools_exposed: tools_exposed
    }
  end

  defp reject_chat_tools!(input) do
    if tools_configured?(input) do
      raise ArgumentError, "workflow :chat does not accept tool harness options"
    end
  end

  defp intent(input) do
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

  defp require_demo_capability!(input) do
    unless has_any_harness?(input, [:demo]) do
      raise ArgumentError,
            "auto workflow detected time intent but the demo time tool harness is not configured"
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
