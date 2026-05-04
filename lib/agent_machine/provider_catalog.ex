defmodule AgentMachine.ProviderCatalog do
  @moduledoc """
  Explicit provider setup catalog for AgentMachine's ReqLLM boundary.
  """

  alias AgentMachine.JSON

  @type field :: %{name: binary(), label: binary(), env: binary() | nil, required: boolean()}
  @type provider :: %{
          id: binary(),
          label: binary(),
          req_llm_provider: atom(),
          status: :supported,
          secret_fields: [field()],
          option_fields: [field()],
          supports_streaming: boolean(),
          supports_tools: boolean()
        }

  @providers [
    %{
      id: "alibaba",
      label: "Alibaba Cloud Bailian",
      req_llm_provider: :alibaba,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_ALIBABA_API_KEY", required: true}
      ]
    },
    %{
      id: "alibaba_cn",
      label: "Alibaba Cloud Bailian China",
      req_llm_provider: :alibaba_cn,
      secret_fields: [
        %{
          name: "api_key",
          label: "API key",
          env: "AGENT_MACHINE_ALIBABA_CN_API_KEY",
          required: true
        }
      ]
    },
    %{
      id: "anthropic",
      label: "Anthropic",
      req_llm_provider: :anthropic,
      secret_fields: [
        %{
          name: "api_key",
          label: "API key",
          env: "AGENT_MACHINE_ANTHROPIC_API_KEY",
          required: true
        }
      ]
    },
    %{
      id: "openai",
      label: "OpenAI",
      req_llm_provider: :openai,
      secret_fields: [%{name: "api_key", label: "API key", env: "OPENAI_API_KEY", required: true}]
    },
    %{
      id: "google",
      label: "Google Gemini",
      req_llm_provider: :google,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_GOOGLE_API_KEY", required: true}
      ]
    },
    %{
      id: "google_vertex",
      label: "Google Vertex AI",
      req_llm_provider: :google_vertex,
      secret_fields: [
        %{
          name: "access_token",
          label: "Access token",
          env: "AGENT_MACHINE_GOOGLE_VERTEX_ACCESS_TOKEN",
          required: true
        }
      ],
      option_fields: [
        %{name: "project_id", label: "Project ID", env: nil, required: true},
        %{name: "region", label: "Region", env: nil, required: true}
      ]
    },
    %{
      id: "amazon_bedrock",
      label: "Amazon Bedrock",
      req_llm_provider: :amazon_bedrock,
      secret_fields: [
        %{
          name: "access_key_id",
          label: "Access key ID",
          env: "AGENT_MACHINE_AMAZON_BEDROCK_ACCESS_KEY_ID",
          required: true
        },
        %{
          name: "secret_access_key",
          label: "Secret access key",
          env: "AGENT_MACHINE_AMAZON_BEDROCK_SECRET_ACCESS_KEY",
          required: true
        }
      ],
      option_fields: [%{name: "region", label: "Region", env: nil, required: true}]
    },
    %{
      id: "azure",
      label: "Azure OpenAI",
      req_llm_provider: :azure,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_AZURE_API_KEY", required: true}
      ],
      option_fields: [
        %{name: "base_url", label: "Azure OpenAI base URL", env: nil, required: true},
        %{name: "deployment", label: "Deployment", env: nil, required: true},
        %{name: "api_version", label: "API version", env: nil, required: true}
      ]
    },
    %{
      id: "groq",
      label: "Groq",
      req_llm_provider: :groq,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_GROQ_API_KEY", required: true}
      ]
    },
    %{
      id: "xai",
      label: "xAI",
      req_llm_provider: :xai,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_XAI_API_KEY", required: true}
      ]
    },
    %{
      id: "openrouter",
      label: "OpenRouter",
      req_llm_provider: :openrouter,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "OPENROUTER_API_KEY", required: true}
      ]
    },
    %{
      id: "cerebras",
      label: "Cerebras",
      req_llm_provider: :cerebras,
      secret_fields: [
        %{
          name: "api_key",
          label: "API key",
          env: "AGENT_MACHINE_CEREBRAS_API_KEY",
          required: true
        }
      ]
    },
    %{
      id: "meta",
      label: "Meta Llama",
      req_llm_provider: :meta,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_META_API_KEY", required: true}
      ]
    },
    %{
      id: "zai",
      label: "Z.AI",
      req_llm_provider: :zai,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_ZAI_API_KEY", required: true}
      ]
    },
    %{
      id: "zai_coder",
      label: "Z.AI Coder",
      req_llm_provider: :zai_coder,
      secret_fields: [
        %{
          name: "api_key",
          label: "API key",
          env: "AGENT_MACHINE_ZAI_CODER_API_KEY",
          required: true
        }
      ]
    },
    %{
      id: "zenmux",
      label: "Zenmux",
      req_llm_provider: :zenmux,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_ZENMUX_API_KEY", required: true}
      ]
    },
    %{
      id: "venice",
      label: "Venice",
      req_llm_provider: :venice,
      secret_fields: [
        %{name: "api_key", label: "API key", env: "AGENT_MACHINE_VENICE_API_KEY", required: true}
      ]
    },
    %{
      id: "vllm",
      label: "vLLM",
      req_llm_provider: :vllm,
      secret_fields: [
        %{
          name: "api_key",
          label: "API key or placeholder token",
          env: "AGENT_MACHINE_VLLM_API_KEY",
          required: true
        }
      ],
      option_fields: [%{name: "base_url", label: "Base URL", env: nil, required: true}]
    }
  ]

  @field_name_atoms %{
    "access_key_id" => :access_key_id,
    "access_token" => :access_token,
    "api_key" => :api_key,
    "api_version" => :api_version,
    "base_url" => :base_url,
    "deployment" => :deployment,
    "project_id" => :project_id,
    "provider" => :provider,
    "region" => :region,
    "secret_access_key" => :secret_access_key
  }

  @unsupported [
    %{
      id: "minimax",
      label: "MiniMax",
      status: :unsupported,
      reason: "ReqLLM 1.11 does not document a MiniMax provider ID"
    }
  ]

  @unsupported_by_id Map.new(@unsupported, &{&1.id, &1})

  def providers do
    @providers
    |> Enum.map(&normalize_provider/1)
    |> Enum.sort_by(& &1.id)
  end

  def unsupported_requested_providers, do: @unsupported

  def all_requested_provider_ids do
    providers()
    |> Enum.map(& &1.id)
    |> Kernel.++(Enum.map(@unsupported, & &1.id))
    |> Enum.sort()
  end

  def supported?(provider_id), do: Map.has_key?(provider_by_id(), normalize_id(provider_id))

  def fetch(provider_id) do
    provider_id = normalize_id(provider_id)

    case Map.fetch(provider_by_id(), provider_id) do
      {:ok, provider} -> {:ok, provider}
      :error -> unsupported_error(provider_id)
    end
  end

  def fetch!(provider_id) do
    case fetch(provider_id) do
      {:ok, provider} -> provider
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def req_llm_provider!(provider_id), do: fetch!(provider_id).req_llm_provider

  def validate_options!(provider_id, options) when is_map(options) do
    provider = fetch!(provider_id)
    allowed = MapSet.new(Enum.map(provider.option_fields, & &1.name))
    unknown = options |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unknown != [] do
      raise ArgumentError,
            "provider #{inspect(provider.id)} does not accept option(s): #{inspect(Enum.sort(unknown))}"
    end

    provider.option_fields
    |> Enum.filter(& &1.required)
    |> Enum.each(fn field ->
      require_non_empty_option!(options, field.name, provider.id)
    end)

    options
  end

  def validate_options!(_provider_id, options) do
    raise ArgumentError, "provider_options must be a map, got: #{inspect(options)}"
  end

  def runtime_options!(provider_id, provider_options) when is_map(provider_options) do
    provider = fetch!(provider_id)
    validate_options!(provider.id, provider_options)

    secret_opts =
      provider.secret_fields
      |> Enum.flat_map(fn field ->
        value = required_secret!(provider.id, field)
        [{field_atom!(field.name), value}]
      end)

    option_opts = Enum.map(provider_options, fn {key, value} -> {field_atom!(key), value} end)
    secret_opts ++ option_opts
  end

  def model_spec!(provider_id, model, provider_options) do
    provider = fetch!(provider_id)
    model = require_non_empty_binary!(model, "model")
    validate_options!(provider.id, provider_options)

    case Map.fetch(provider_options, "base_url") do
      {:ok, base_url} ->
        %{
          provider: provider.req_llm_provider,
          id: model,
          base_url: require_non_empty_binary!(base_url, "provider option base_url")
        }

      :error ->
        "#{provider.id}:#{model}"
    end
  end

  def list_models!(provider_id, provider_options) do
    provider = fetch!(provider_id)
    validate_options!(provider.id, provider_options)

    provider.id
    |> available_model_specs(runtime_options!(provider.id, provider_options))
    |> Enum.map(&model_metadata!/1)
    |> Enum.sort_by(& &1.id)
  end

  def provider_json(provider) do
    provider
    |> Map.take([
      :id,
      :label,
      :status,
      :secret_fields,
      :option_fields,
      :supports_streaming,
      :supports_tools
    ])
    |> stringify_field_keys()
  end

  def unsupported_json(provider), do: stringify_field_keys(provider)

  def model_json(model), do: stringify_field_keys(model)

  def encode_json!(value), do: JSON.encode!(value)

  defp available_model_specs(provider_id, runtime_options) do
    provider = fetch!(provider_id)
    opts = [scope: provider.req_llm_provider, provider_options: runtime_options]

    case ReqLLM.available_models(opts) do
      models when is_list(models) ->
        models

      other ->
        raise ArgumentError, "ReqLLM.available_models/1 returned invalid value: #{inspect(other)}"
    end
  end

  defp model_metadata!(spec) when is_binary(spec) do
    model =
      case ReqLLM.model(spec) do
        {:ok, model} ->
          model

        {:error, reason} ->
          raise ArgumentError, "failed to load ReqLLM model #{spec}: #{inspect(reason)}"
      end

    map = Map.from_struct(model)
    id = model_id!(map, spec)

    %{
      id: id,
      spec: spec,
      pricing: pricing_from_model(map),
      context_window_tokens: context_window_from_model(map)
    }
  end

  defp model_id!(map, spec) do
    case Map.get(map, :id) || Map.get(map, :model) do
      value when is_binary(value) and value != "" ->
        value

      _other ->
        [_provider, model] = String.split(spec, ":", parts: 2)
        model
    end
  end

  defp pricing_from_model(map) do
    cost = Map.get(map, :cost) || Map.get(map, :pricing)

    with %{input: input, output: output} <- cost,
         true <- is_number(input),
         true <- is_number(output) do
      %{input_per_million: input * 1.0, output_per_million: output * 1.0}
    else
      _other -> nil
    end
  end

  defp context_window_from_model(map) do
    limit = Map.get(map, :limit) || Map.get(map, :limits)

    cond do
      is_map(limit) and is_integer(Map.get(limit, :context)) -> Map.fetch!(limit, :context)
      is_integer(Map.get(map, :context_window)) -> Map.fetch!(map, :context_window)
      is_integer(Map.get(map, :context_window_tokens)) -> Map.fetch!(map, :context_window_tokens)
      true -> nil
    end
  end

  defp unsupported_error(provider_id) do
    case Map.fetch(@unsupported_by_id, provider_id) do
      {:ok, provider} ->
        {:error, "provider #{inspect(provider_id)} is not supported: #{provider.reason}"}

      :error ->
        supported = @providers |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join(", ")

        {:error,
         "unsupported provider #{inspect(provider_id)}; supported providers: #{supported}"}
    end
  end

  defp normalize_provider(provider) do
    provider
    |> Map.put_new(:status, :supported)
    |> Map.put_new(:option_fields, [])
    |> Map.put_new(:supports_streaming, true)
    |> Map.put_new(:supports_tools, true)
  end

  defp provider_by_id, do: Map.new(providers(), &{&1.id, &1})

  defp normalize_id(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp normalize_id(provider) when is_binary(provider) do
    provider = String.trim(provider)

    if provider == "" do
      raise ArgumentError, "provider id must not be empty"
    end

    provider
  end

  defp normalize_id(provider),
    do: raise(ArgumentError, "provider id must be a string, got: #{inspect(provider)}")

  defp require_non_empty_option!(options, name, provider_id) do
    case Map.fetch(options, name) do
      {:ok, value} ->
        require_non_empty_binary!(
          value,
          "provider #{inspect(provider_id)} option #{inspect(name)}"
        )

      :error ->
        raise ArgumentError, "provider #{inspect(provider_id)} requires option #{inspect(name)}"
    end
  end

  defp require_non_empty_binary!(value, label) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      raise ArgumentError, "#{label} must be a non-empty string, got: #{inspect(value)}"
    end

    value
  end

  defp require_non_empty_binary!(value, label),
    do: raise(ArgumentError, "#{label} must be a non-empty string, got: #{inspect(value)}")

  defp required_secret!(provider_id, field) do
    case System.fetch_env(field.env) do
      {:ok, value} ->
        require_non_empty_binary!(
          value,
          "provider #{inspect(provider_id)} secret #{inspect(field.name)} from #{field.env}"
        )

      :error ->
        raise ArgumentError,
              "provider #{inspect(provider_id)} requires secret #{inspect(field.name)} in #{field.env}"
    end
  end

  defp field_atom!(name) do
    Map.fetch!(@field_name_atoms, name)
  end

  defp stringify_field_keys(value) when is_map(value) do
    Map.new(value, fn
      {key, item} when is_atom(key) -> {Atom.to_string(key), stringify_field_keys(item)}
      {key, item} -> {key, stringify_field_keys(item)}
    end)
  end

  defp stringify_field_keys(value) when is_list(value),
    do: Enum.map(value, &stringify_field_keys/1)

  defp stringify_field_keys(value), do: value
end
