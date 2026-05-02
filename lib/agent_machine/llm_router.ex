defmodule AgentMachine.LLMRouter do
  @moduledoc false

  use GenServer

  alias AgentMachine.{Agent, Intent, RouterAdvice}

  @valid_intents Intent.intents()
  @intent_lookup Map.new(@valid_intents, &{Atom.to_string(&1), &1})
  @allowed_response_keys MapSet.new([
                           "intent",
                           "work_shape",
                           "route_hint",
                           "confidence",
                           "reason"
                         ])

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def classify!(input) when is_map(input) do
    timeout_ms = call_timeout_ms(input)

    case GenServer.call(__MODULE__, {:classify, input}, timeout_ms) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def classify!(input) do
    raise ArgumentError, "llm router input must be a map, got: #{inspect(input)}"
  end

  if Mix.env() == :test do
    def put_test_classifier(fun) when is_function(fun, 1) do
      GenServer.call(__MODULE__, {:put_test_classifier, fun})
    end

    def clear_test_classifier do
      GenServer.call(__MODULE__, :clear_test_classifier)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{tasks: %{}, test_classifier: nil}}

  @impl true
  def handle_call({:classify, input}, from, state) do
    classifier = state.test_classifier

    task =
      Task.Supervisor.async_nolink(AgentMachine.LLMRouter.TaskSupervisor, fn ->
        classify_task(input, classifier)
      end)

    {:noreply, put_in(state, [:tasks, task.ref], from)}
  end

  if Mix.env() == :test do
    def handle_call({:put_test_classifier, fun}, _from, state) do
      {:reply, :ok, %{state | test_classifier: fun}}
    end

    def handle_call(:clear_test_classifier, _from, state) do
      {:reply, :ok, %{state | test_classifier: nil}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    {from, state} = pop_task(state, ref)
    Process.demonitor(ref, [:flush])

    if from != nil do
      GenServer.reply(from, result)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    {from, state} = pop_task(state, ref)

    if from != nil do
      GenServer.reply(from, {:error, "llm router task exited: #{inspect(reason)}"})
    end

    {:noreply, state}
  end

  defp pop_task(state, ref) do
    {from, tasks} = Map.pop(state.tasks, ref)
    {from, %{state | tasks: tasks}}
  end

  defp classify_task(input, classifier) do
    {:ok, classify_input!(input, classifier)}
  rescue
    exception in [ArgumentError, RuntimeError] -> {:error, Exception.message(exception)}
  end

  defp classify_input!(input, classifier) when is_function(classifier, 1) do
    input
    |> classifier.()
    |> normalize_classifier_result!(required_model!(input))
  end

  defp classify_input!(input, nil) do
    provider = input |> required_provider!() |> provider_module!()
    model = required_model!(input)
    pricing = required_pricing!(input)

    http_timeout_ms =
      required_positive_integer!(Map.get(input, :http_timeout_ms), :http_timeout_ms)

    agent =
      Agent.new!(%{
        id: "workflow-router",
        provider: provider,
        model: model,
        pricing: pricing,
        instructions: instructions(),
        input: prompt(input)
      })

    case provider.complete(agent, provider_opts(http_timeout_ms)) do
      {:ok, %{output: output}} ->
        output
        |> decode_response!()
        |> normalize_classifier_result!(model)

      {:ok, payload} ->
        raise ArgumentError, "llm router provider response is missing output: #{inspect(payload)}"

      {:error, reason} ->
        raise ArgumentError, "llm router provider failed: #{inspect(reason)}"
    end
  end

  defp provider_opts(http_timeout_ms) do
    [
      http_timeout_ms: http_timeout_ms,
      run_context: %{agent_graph: %{}, results: %{}, artifacts: %{}}
    ]
  end

  defp decode_response!(output) when is_binary(output) do
    decoded =
      case output |> String.trim() |> Jason.decode() do
        {:ok, value} ->
          value

        {:error, error} ->
          raise ArgumentError, "llm router invalid JSON response: #{Exception.message(error)}"
      end

    decoded
    |> require_response_object!()
    |> reject_unknown_response_keys!()
  end

  defp decode_response!(output) do
    raise ArgumentError, "llm router provider output must be a binary, got: #{inspect(output)}"
  end

  defp require_response_object!(%{} = response), do: response

  defp require_response_object!(response) do
    raise ArgumentError, "llm router response must be a JSON object, got: #{inspect(response)}"
  end

  defp reject_unknown_response_keys!(response) do
    unknown_keys =
      response
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@allowed_response_keys, &1))

    if unknown_keys == [] do
      response
    else
      raise ArgumentError, "llm router response contains unknown keys: #{inspect(unknown_keys)}"
    end
  end

  defp normalize_classifier_result!(%{} = response, model) do
    intent = response |> value!(:intent) |> normalize_intent!(:intent)
    work_shape = response |> value!(:work_shape) |> normalize_work_shape!()
    route_hint = response |> value!(:route_hint) |> normalize_route_hint!()
    confidence = response |> value!(:confidence) |> normalize_confidence!()
    reason = response |> value!(:reason) |> normalize_reason!()

    %{
      intent: intent,
      classified_intent: intent,
      work_shape: work_shape,
      route_hint: route_hint,
      classifier: "llm",
      classifier_model: model,
      confidence: confidence,
      reason: reason
    }
  end

  defp normalize_classifier_result!(response, _model) do
    raise ArgumentError, "llm router classifier must return a map, got: #{inspect(response)}"
  end

  defp value!(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      true -> raise ArgumentError, "llm router response is missing #{inspect(string_key)}"
    end
  end

  defp normalize_intent!(intent, _field) when is_atom(intent) do
    if Intent.valid?(intent) do
      intent
    else
      raise ArgumentError, "llm router returned invalid intent: #{inspect(intent)}"
    end
  end

  defp normalize_intent!(intent, field) when is_binary(intent) do
    case Map.fetch(@intent_lookup, intent) do
      {:ok, normalized} ->
        normalized

      :error ->
        raise ArgumentError, "llm router returned invalid #{field}: #{inspect(intent)}"
    end
  end

  defp normalize_intent!(intent, field) do
    raise ArgumentError, "llm router returned invalid #{field}: #{inspect(intent)}"
  end

  defp normalize_work_shape!(work_shape) do
    RouterAdvice.normalize_work_shape!(work_shape, "llm router returned invalid work_shape")
  end

  defp normalize_route_hint!(route_hint) do
    RouterAdvice.normalize_route_hint!(route_hint, "llm router returned invalid route_hint")
  end

  defp normalize_confidence!(confidence) when is_number(confidence) do
    confidence = confidence * 1.0

    if confidence >= 0.0 and confidence <= 1.0 do
      confidence
    else
      raise ArgumentError, "llm router confidence must be from 0.0 to 1.0, got: #{confidence}"
    end
  end

  defp normalize_confidence!(confidence) do
    raise ArgumentError, "llm router confidence must be a number, got: #{inspect(confidence)}"
  end

  defp normalize_reason!(reason) when is_binary(reason) do
    reason = String.trim(reason)

    if reason != "" do
      reason
    else
      raise ArgumentError, "llm router reason must be a non-empty binary"
    end
  end

  defp normalize_reason!(reason) do
    raise ArgumentError, "llm router reason must be a non-empty binary, got: #{inspect(reason)}"
  end

  defp instructions do
    intents =
      @valid_intents
      |> Enum.map_join("\n", fn intent -> "- #{intent}: #{intent_description(intent)}" end)

    work_shapes =
      RouterAdvice.work_shapes()
      |> Enum.map_join("\n", fn work_shape ->
        "- #{work_shape}: #{work_shape_description(work_shape)}"
      end)

    route_hints =
      RouterAdvice.route_hints()
      |> Enum.map_join(", ", &Atom.to_string/1)

    """
    You are AgentMachine's workflow router.
    Classify the current user request into exactly one routing intent and one advisory execution shape.

    Valid intents:
    #{intents}

    Valid work_shape values:
    #{work_shapes}

    Valid route_hint values:
    #{route_hints}

    Rules:
    - Return only one JSON object.
    - Do not include Markdown, prose, or code fences.
    - route_hint is advisory only; the Elixir runtime validates capabilities, permissions, and the final route.
    - Use file_mutation for requests to create, write, edit, delete, rename, or modify local files or folders.
    - Use code_mutation for requests to create, edit, fix, patch, or generate code, apps, scripts, websites, tests, or project files.
    - Use file_read with work_shape narrow_read and route_hint tool for a narrow local file, directory, search, or lookup request.
    - Use file_read with work_shape broad_project_analysis and route_hint agentic for broad codebase/project/repository analysis, architecture review, or improvement recommendations.
    - Use web_browse only for opening, browsing, inspecting, or researching an external/current website, browser page, URL, or web search.
    - Do not decide permissions and do not execute tools.

    Required JSON shape:
    {"intent":"file_read","work_shape":"broad_project_analysis","route_hint":"agentic","confidence":0.91,"reason":"short reason"}
    """
  end

  defp intent_description(:none), do: "normal chat or explanation without tool use"
  defp intent_description(:file_read), do: "inspect, list, search, check, or read local files"

  defp intent_description(:file_mutation),
    do: "create, write, edit, delete, rename, or modify local files"

  defp intent_description(:code_mutation),
    do: "edit, patch, fix, repair, or create code, apps, scripts, or project files"

  defp intent_description(:test_command),
    do: "run tests or execute an explicitly requested test command"

  defp intent_description(:time), do: "answer the current time or current date"

  defp intent_description(:web_browse),
    do: "open, browse, inspect, research, or read a website, web page, URL, or browser page"

  defp intent_description(:tool_use),
    do: "explicitly use a tool, API, MCP server, or external integration"

  defp intent_description(:delegation),
    do: "explicitly use agents, workers, subagents, or delegated work"

  defp work_shape_description(:conversation),
    do: "normal conversation or explanation without tool use"

  defp work_shape_description(:narrow_read),
    do: "one small local read, listing, search, or lookup"

  defp work_shape_description(:broad_project_analysis),
    do: "multi-file project, codebase, repository, architecture, or improvement analysis"

  defp work_shape_description(:mutation),
    do: "local file or code creation, editing, repair, deletion, or refactoring"

  defp work_shape_description(:test_execution),
    do: "running tests, checks, or explicit test commands"

  defp work_shape_description(:web_research),
    do: "external website, URL, browser, or web-search research"

  defp work_shape_description(:explicit_delegation),
    do: "explicit user request for agents, workers, subagents, or delegated work"

  defp work_shape_description(:generic_tool_use),
    do: "explicit generic tool, API, MCP, or integration use"

  defp prompt(input) do
    [
      optional_section("Pending action", Map.get(input, :pending_action)),
      optional_section("Recent context", Map.get(input, :recent_context)),
      required_section("Current request", Map.get(input, :task))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp optional_section(_label, nil), do: ""
  defp optional_section(_label, ""), do: ""
  defp optional_section(label, value) when is_binary(value), do: label <> ":\n" <> value

  defp optional_section(label, value) do
    raise ArgumentError, "#{label} must be a binary when present, got: #{inspect(value)}"
  end

  defp required_section(label, value) when is_binary(value) and byte_size(value) > 0 do
    label <> ":\n" <> value
  end

  defp required_section(label, value) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp required_provider!(input) do
    case Map.fetch(input, :provider) do
      {:ok, provider} -> provider
      :error -> raise ArgumentError, "llm router input is missing :provider"
    end
  end

  defp required_model!(input) do
    case Map.fetch(input, :model) do
      {:ok, model} when is_binary(model) and byte_size(model) > 0 ->
        model

      {:ok, model} ->
        raise ArgumentError,
              "llm router :model must be a non-empty binary, got: #{inspect(model)}"

      :error ->
        raise ArgumentError, "llm router input is missing :model"
    end
  end

  defp required_pricing!(input) do
    case Map.fetch(input, :pricing) do
      {:ok, pricing} ->
        AgentMachine.Pricing.validate!(pricing)
        pricing

      :error ->
        raise ArgumentError, "llm router input is missing :pricing"
    end
  end

  defp required_positive_integer!(value, _field) when is_integer(value) and value > 0, do: value

  defp required_positive_integer!(value, field) do
    raise ArgumentError,
          "llm router #{inspect(field)} must be a positive integer, got: #{inspect(value)}"
  end

  defp provider_module!(:openai), do: AgentMachine.Providers.OpenAIResponses
  defp provider_module!(:openrouter), do: AgentMachine.Providers.OpenRouterChat

  defp provider_module!(provider) when is_atom(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :complete, 2) do
      provider
    else
      raise ArgumentError, "llm router does not support provider #{inspect(provider)}"
    end
  end

  defp provider_module!(provider) do
    raise ArgumentError, "llm router provider must be an atom, got: #{inspect(provider)}"
  end

  defp call_timeout_ms(input) do
    case Map.get(input, :http_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms + 1_000
      _other -> 5_000
    end
  end
end
