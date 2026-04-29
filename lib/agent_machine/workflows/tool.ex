defmodule AgentMachine.Workflows.Tool do
  @moduledoc """
  Internal auto-selected workflow for single-agent read-only tool requests.
  """

  alias AgentMachine.RunSpec

  def build!(%RunSpec{} = spec, %{tool_intent: intent}) do
    provider = provider_module(spec)
    pricing = pricing(spec)

    agents = [
      %{
        id: "assistant",
        provider: provider,
        model: model(spec),
        instructions: assistant_instructions(),
        input: spec.task,
        pricing: pricing
      }
    ]

    opts =
      [
        timeout: spec.timeout_ms,
        max_steps: spec.max_steps,
        max_attempts: spec.max_attempts,
        stream_response: spec.stream_response
      ]
      |> put_http_opts(spec)
      |> put_read_only_tool_opts(spec, intent)

    {agents, opts}
  end

  def build!(%RunSpec{}, route) do
    raise ArgumentError, "tool workflow route must include :tool_intent, got: #{inspect(route)}"
  end

  defp provider_module(%RunSpec{provider: :echo}), do: AgentMachine.Providers.Echo
  defp provider_module(%RunSpec{provider: :openai}), do: AgentMachine.Providers.OpenAIResponses
  defp provider_module(%RunSpec{provider: :openrouter}), do: AgentMachine.Providers.OpenRouterChat

  defp model(%RunSpec{provider: :echo}), do: "echo"

  defp model(%RunSpec{provider: provider, model: model})
       when provider in [:openai, :openrouter] do
    model
  end

  defp pricing(%RunSpec{provider: :echo}) do
    %{input_per_million: 0.0, output_per_million: 0.0}
  end

  defp pricing(%RunSpec{provider: provider, pricing: pricing})
       when provider in [:openai, :openrouter] do
    pricing
  end

  defp put_http_opts(opts, %RunSpec{provider: :echo}), do: opts

  defp put_http_opts(opts, %RunSpec{provider: provider, http_timeout_ms: http_timeout_ms})
       when provider in [:openai, :openrouter] do
    Keyword.put(opts, :http_timeout_ms, http_timeout_ms)
  end

  defp put_read_only_tool_opts(
         opts,
         %RunSpec{
           tool_harnesses: harnesses,
           tool_timeout_ms: tool_timeout_ms,
           tool_max_rounds: tool_max_rounds,
           tool_approval_mode: tool_approval_mode
         } = spec,
         intent
       )
       when is_list(harnesses) do
    harness_opts = tool_harness_opts(spec)

    opts
    |> Keyword.put(
      :allowed_tools,
      AgentMachine.ToolHarness.read_only_many!(harnesses, harness_opts, intent)
    )
    |> Keyword.put(
      :tool_policy,
      AgentMachine.ToolHarness.read_only_policy_many!(harnesses, harness_opts, intent)
    )
    |> Keyword.put(:tool_timeout_ms, tool_timeout_ms)
    |> Keyword.put(:tool_max_rounds, tool_max_rounds)
    |> Keyword.put(:tool_approval_mode, tool_approval_mode)
    |> maybe_put_tool_root(harnesses, spec)
    |> maybe_put_mcp_config(spec)
  end

  defp put_read_only_tool_opts(_opts, spec, _intent) do
    raise ArgumentError,
          "tool workflow requires tool harnesses, got: #{inspect(spec.tool_harnesses)}"
  end

  defp tool_harness_opts(%RunSpec{
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts
       }),
       do: [
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts
       ]

  defp maybe_put_tool_root(opts, harnesses, %RunSpec{tool_root: root})
       when is_list(harnesses) do
    if Enum.any?(harnesses, &(&1 in [:local_files, :code_edit])) do
      Keyword.put(opts, :tool_root, root)
    else
      opts
    end
  end

  defp maybe_put_tool_root(opts, _harnesses, _spec), do: opts

  defp maybe_put_mcp_config(opts, %RunSpec{mcp_config: nil}), do: opts

  defp maybe_put_mcp_config(opts, %RunSpec{mcp_config: config}),
    do: Keyword.put(opts, :mcp_config, config)

  defp assistant_instructions do
    """
    Answer the user's task directly and concisely.
    Use only the available read-only tools needed to answer.
    Do not claim that you wrote, changed, deleted, patched, or executed anything.
    If the available read-only tools cannot answer the request, say what is missing.
    """
    |> String.trim()
  end
end
