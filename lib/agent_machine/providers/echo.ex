defmodule AgentMachine.Providers.Echo do
  @moduledoc """
  Local provider for development and tests.

  It does not call an LLM. It echoes the input and emits deterministic fake usage
  so the rest of the orchestration path can be tested without network access.
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON, RunContextPrompt}

  @impl true
  def complete(%Agent{} = agent, opts) do
    input_tokens = token_count(agent.input) + token_count(agent.instructions)
    output = output(agent, opts)
    output_tokens = token_count(output)

    {:ok,
     %{
       output: output,
       usage: %{
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         total_tokens: input_tokens + output_tokens
       }
     }}
  end

  @impl true
  def stream_complete(%Agent{} = agent, opts) do
    output = output(agent, opts)
    emit_delta(opts, output)
    emit_done(opts)

    input_tokens = token_count(agent.input) + token_count(agent.instructions)
    output_tokens = token_count(output)

    {:ok,
     %{
       output: output,
       usage: %{
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         total_tokens: input_tokens + output_tokens
       }
     }}
  end

  @impl true
  def context_budget_request(%Agent{} = agent, opts) do
    sections = RunContextPrompt.budget_sections(opts)

    {:ok,
     %{
       provider: :echo,
       request: %{
         "model" => agent.model,
         "instructions" => agent.instructions,
         "input" => input(agent, sections)
       },
       breakdown: %{
         instructions: agent.instructions,
         task_input: agent.input,
         run_context: sections.run_context,
         skills: sections.skills,
         tools: [],
         mcp_tools: [],
         tool_continuation: nil
       }
     }}
  end

  defp emit_delta(opts, delta) do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_delta,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      delta: delta,
      at: DateTime.utc_now()
    })
  end

  defp emit_done(opts) do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_done,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      at: DateTime.utc_now()
    })
  end

  defp output(%Agent{} = agent, opts) do
    cond do
      compaction_response?(agent) ->
        compaction_output(agent)

      skill_generation_response?(agent) ->
        skill_generation_output(agent)

      swarm_delegation_response?(agent) ->
        swarm_output(agent, opts)

      structured_delegation_response?(agent) ->
        JSON.encode!(%{
          "decision" => %{
            "mode" => "direct",
            "reason" => "Echo provider completes structured planner requests directly."
          },
          "output" => "agent #{agent.id}: #{agent.input}",
          "next_agents" => []
        })

      true ->
        "agent #{agent.id}: #{agent.input}"
    end
  end

  defp swarm_output(%Agent{} = agent, opts) do
    run_id = opts |> Keyword.fetch!(:run_context) |> Map.fetch!(:run_id)
    variant_ids = ["minimal", "robust", "experimental"]
    variant_agent_ids = Enum.map(variant_ids, &"variant-#{&1}")

    JSON.encode!(%{
      "decision" => %{
        "mode" => "swarm",
        "reason" => "Echo provider created deterministic swarm variants."
      },
      "output" => "Planning three isolated variants and an evaluator.",
      "next_agents" =>
        Enum.map(variant_ids, &swarm_variant(&1, run_id)) ++
          [
            %{
              "id" => "swarm-evaluator",
              "input" => "Compare the swarm variants for: #{agent.input}",
              "depends_on" => variant_agent_ids,
              "metadata" => %{
                "agent_machine_role" => "swarm_evaluator",
                "swarm_id" => "default"
              }
            }
          ]
    })
  end

  defp swarm_variant(variant_id, run_id) do
    %{
      "id" => "variant-#{variant_id}",
      "input" =>
        "Produce the #{variant_id} variant in workspace .agent-machine/swarm/#{run_id}/#{variant_id}. Report confirmed checks and partial failures.",
      "metadata" => %{
        "agent_machine_role" => "swarm_variant",
        "swarm_id" => "default",
        "variant_id" => variant_id,
        "workspace" => ".agent-machine/swarm/#{run_id}/#{variant_id}"
      }
    }
  end

  defp input(%Agent{} = agent, %{full_text: ""}), do: agent.input

  defp input(%Agent{} = agent, %{full_text: context}),
    do: agent.input <> "\n\nRun context:\n" <> context

  defp compaction_response?(%Agent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_response) == "compaction" ||
      Map.get(metadata, "agent_machine_response") == "compaction"
  end

  defp compaction_response?(_agent), do: false

  defp compaction_output(%Agent{} = agent) do
    payload = JSON.decode!(agent.input)

    JSON.encode!(%{
      "summary" => "Echo compacted #{compaction_type(payload)} context.",
      "covered_items" => covered_items(payload)
    })
  end

  defp compaction_type(%{"type" => type}) when is_binary(type), do: type
  defp compaction_type(_payload), do: "unknown"

  defp covered_items(%{"type" => "conversation", "messages" => messages})
       when is_list(messages) do
    messages
    |> length()
    |> then(fn count -> 1..count end)
    |> Enum.map(&Integer.to_string/1)
  end

  defp covered_items(%{"type" => "run_context", "results" => results}) when is_map(results) do
    Map.keys(results)
  end

  defp covered_items(_payload), do: []

  defp skill_generation_response?(%Agent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_response) == "skill_generation" ||
      Map.get(metadata, "agent_machine_response") == "skill_generation"
  end

  defp skill_generation_response?(_agent), do: false

  defp skill_generation_output(%Agent{} = agent) do
    payload = JSON.decode!(agent.input)
    name = Map.fetch!(payload, "name")
    description = Map.fetch!(payload, "description")

    JSON.encode!(%{
      "name" => name,
      "description" => description,
      "instructions" => """
      Use this skill when the task matches: #{description}.

      ## Workflow

      - Confirm the request fits the skill description.
      - Apply the requested command-specific behavior directly and concisely.
      - Keep generated output focused on the user's current task.
      - Fail fast when required input is missing instead of inventing defaults.
      """
    })
  end

  defp structured_delegation_response?(%Agent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_response) == "delegation" ||
      Map.get(metadata, "agent_machine_response") == "delegation"
  end

  defp structured_delegation_response?(_agent), do: false

  defp swarm_delegation_response?(%Agent{metadata: metadata} = agent) when is_map(metadata) do
    structured_delegation_response?(agent) and
      (Map.get(metadata, :agent_machine_strategy) == "swarm" ||
         Map.get(metadata, "agent_machine_strategy") == "swarm")
  end

  defp swarm_delegation_response?(_agent), do: false

  defp token_count(nil), do: 0

  defp token_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
