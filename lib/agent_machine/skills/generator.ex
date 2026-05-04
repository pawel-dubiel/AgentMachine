defmodule AgentMachine.Skills.Generator do
  @moduledoc false

  alias AgentMachine.{Agent, JSON, Pricing}
  alias AgentMachine.Skills.Manifest

  @generated_keys MapSet.new(["name", "description", "instructions"])
  @max_instruction_bytes 20_000

  def generate!(name, opts) when is_list(opts) do
    name = Manifest.validate_name!(name)
    skills_dir = opts |> fetch_required!(:skills_dir) |> require_non_empty_binary!("skills dir")

    description =
      opts |> fetch_required!(:description) |> require_non_empty_binary!("description")

    provider_id = fetch_required!(opts, :provider)
    provider = provider_module!(provider_id)
    model = model!(provider_id, fetch_required!(opts, :model))

    http_timeout_ms =
      opts |> fetch_required!(:http_timeout_ms) |> require_positive_integer!("http timeout ms")

    pricing = opts |> fetch_required!(:pricing) |> Pricing.validate!()
    root = Path.join(Path.expand(skills_dir), name)

    if File.exists?(root) do
      raise ArgumentError, "skill already exists: #{inspect(name)}"
    end

    payload =
      name
      |> generator_agent(description, provider, model, pricing)
      |> complete_provider!(http_timeout_ms, Keyword.get(opts, :provider_options, %{}))
      |> parse_payload!(name)

    write_skill!(root, payload)
  end

  defp generator_agent(name, description, provider, model, pricing) do
    Agent.new!(%{
      id: "skill-generator",
      provider: provider,
      model: model,
      instructions: generator_instructions(),
      input: JSON.encode!(%{name: name, description: description}),
      pricing: pricing,
      metadata: %{
        agent_machine_response: "skill_generation",
        skill_name: name,
        skill_description: description
      }
    })
  end

  defp complete_provider!(%Agent{} = agent, http_timeout_ms, provider_options) do
    case agent.provider.complete(agent, provider_opts(http_timeout_ms, provider_options)) do
      {:ok, %{output: output}} when is_binary(output) ->
        output

      {:ok, other} ->
        raise ArgumentError,
              "skill generator provider returned invalid payload: #{inspect(other)}"

      {:error, reason} ->
        raise RuntimeError, "skill generator provider failed: #{inspect(reason)}"
    end
  end

  defp provider_opts(http_timeout_ms, provider_options) do
    [
      http_timeout_ms: http_timeout_ms,
      provider_options: provider_options,
      run_context: %{results: %{}, artifacts: %{}},
      runtime_facts: false
    ]
  end

  defp parse_payload!(output, expected_name) do
    output
    |> JSON.decode!()
    |> validate_payload!(expected_name)
  rescue
    exception in [Jason.DecodeError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid generated skill payload: #{Exception.message(exception)}"],
              __STACKTRACE__
  end

  defp validate_payload!(payload, expected_name) when is_map(payload) do
    keys = payload |> Map.keys() |> MapSet.new()

    if keys != @generated_keys do
      raise ArgumentError,
            "generated skill payload must contain exactly name, description, and instructions"
    end

    name = payload |> Map.fetch!("name") |> require_non_empty_binary!("generated skill name")

    if name != expected_name do
      raise ArgumentError,
            "generated skill name must match requested name #{inspect(expected_name)}, got: #{inspect(name)}"
    end

    %{
      name: name,
      description:
        payload
        |> Map.fetch!("description")
        |> require_non_empty_binary!("generated skill description"),
      instructions:
        payload
        |> Map.fetch!("instructions")
        |> require_non_empty_binary!("generated skill instructions")
        |> require_bounded_instructions!()
    }
  end

  defp validate_payload!(payload, _expected_name) do
    raise ArgumentError, "generated skill payload must be an object, got: #{inspect(payload)}"
  end

  defp write_skill!(root, payload) do
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "SKILL.md"),
      """
      ---
      name: #{yaml_string(payload.name)}
      description: #{yaml_string(payload.description)}
      ---
      #{payload.instructions}
      """
    )

    Manifest.load!(root)
  end

  defp generator_instructions do
    """
    You generate one concise Codex-compatible AgentMachine skill.
    Return only strict JSON with exactly these string fields: name, description, instructions.
    The name must exactly match the requested name.
    The description should clearly say when to use the skill.
    The instructions should be practical Markdown for an AI agent and should stay focused on the requested behavior.
    Do not include scripts, resources, file paths to create, YAML frontmatter, code fences around the JSON, README text, changelog text, or installation notes.
    """
    |> String.trim()
  end

  defp provider_module!(:echo), do: AgentMachine.Providers.Echo

  defp provider_module!(provider) when is_binary(provider) do
    AgentMachine.ProviderCatalog.fetch!(provider)
    AgentMachine.Providers.ReqLLM
  end

  defp provider_module!(provider) do
    raise ArgumentError,
          "skill generator provider must be :echo or a supported ReqLLM provider id, got: #{inspect(provider)}"
  end

  defp model!(:echo, model), do: require_non_empty_binary!(model, "model")

  defp model!(provider, model) when is_binary(provider) do
    provider <> ":" <> require_non_empty_binary!(model, "model")
  end

  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required #{inspect(key)} option"
    end
  end

  defp require_non_empty_binary!(value, label) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      raise ArgumentError, "#{label} must not be empty"
    end

    value
  end

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_positive_integer!(value, _label) when is_integer(value) and value > 0, do: value

  defp require_positive_integer!(value, label) do
    raise ArgumentError, "#{label} must be a positive integer, got: #{inspect(value)}"
  end

  defp require_bounded_instructions!(instructions) do
    if byte_size(instructions) > @max_instruction_bytes do
      raise ArgumentError, "generated skill instructions exceed #{@max_instruction_bytes} bytes"
    end

    instructions
  end

  defp yaml_string(value), do: JSON.encode!(value)
end
