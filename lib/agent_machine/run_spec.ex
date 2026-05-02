defmodule AgentMachine.RunSpec do
  @moduledoc """
  High-level run request used by clients.
  """

  alias AgentMachine.{ContextBudget, MCP.Config}
  alias AgentMachine.Skills.Manifest
  alias AgentMachine.Tools.RunTestCommand

  @enforce_keys [:task, :workflow, :provider, :timeout_ms, :max_steps, :max_attempts]
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :task,
    :workflow,
    :provider,
    :model,
    :timeout_ms,
    :max_steps,
    :max_attempts,
    :http_timeout_ms,
    :pricing,
    :tool_harness,
    :tool_harnesses,
    :tool_timeout_ms,
    :tool_max_rounds,
    :tool_root,
    :tool_approval_mode,
    :test_commands,
    :mcp_config_path,
    :mcp_config,
    :skills_mode,
    :skills_dir,
    :skill_names,
    :allow_skill_scripts,
    :stream_response,
    :context_window_tokens,
    :context_warning_percent,
    :context_tokenizer_path,
    :reserved_output_tokens,
    :run_context_compaction,
    :run_context_compact_percent,
    :max_context_compactions,
    :agentic_persistence_rounds,
    :router_mode,
    :router_model_dir,
    :router_timeout_ms,
    :router_confidence_threshold
  ]

  @type t :: %__MODULE__{
          task: binary(),
          workflow: :chat | :basic | :agentic | :auto,
          provider: :echo | :openai | :openrouter,
          model: binary() | nil,
          timeout_ms: pos_integer(),
          max_steps: pos_integer(),
          max_attempts: pos_integer(),
          http_timeout_ms: pos_integer() | nil,
          pricing: map() | nil,
          tool_harness: :demo | :time | :local_files | :code_edit | :mcp | :skills | nil,
          tool_harnesses: [:demo | :time | :local_files | :code_edit | :mcp | :skills] | nil,
          tool_timeout_ms: pos_integer() | nil,
          tool_max_rounds: pos_integer() | nil,
          tool_root: binary() | nil,
          tool_approval_mode:
            :read_only | :ask_before_write | :auto_approved_safe | :full_access | nil,
          test_commands: [binary()] | nil,
          mcp_config_path: binary() | nil,
          mcp_config: AgentMachine.MCP.Config.t() | nil,
          skills_mode: :off | :auto,
          skills_dir: binary() | nil,
          skill_names: [binary()],
          allow_skill_scripts: boolean(),
          stream_response: boolean(),
          context_window_tokens: pos_integer() | nil,
          context_warning_percent: pos_integer() | nil,
          context_tokenizer_path: binary() | nil,
          reserved_output_tokens: pos_integer() | nil,
          run_context_compaction: :off | :on,
          run_context_compact_percent: pos_integer() | nil,
          max_context_compactions: pos_integer() | nil,
          agentic_persistence_rounds: pos_integer() | nil,
          router_mode: :deterministic | :local | :llm,
          router_model_dir: binary() | nil,
          router_timeout_ms: pos_integer() | nil,
          router_confidence_threshold: float() | nil
        }

  def new!(attrs) when is_map(attrs) do
    attrs
    |> atomize_keys!()
    |> normalize_skills!()
    |> normalize_tool_harnesses!()
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  def new!(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new!()
  end

  def new!(attrs) do
    raise ArgumentError, "run spec must be a map or keyword list, got: #{inspect(attrs)}"
  end

  defp validate!(%__MODULE__{} = spec) do
    require_non_empty_binary!(spec.task, :task)
    require_workflow!(spec.workflow)
    require_provider!(spec.provider)
    require_positive_integer!(spec.timeout_ms, :timeout_ms)
    require_positive_integer!(spec.max_steps, :max_steps)
    require_positive_integer!(spec.max_attempts, :max_attempts)
    validate_provider_options!(spec)
    require_boolean!(spec.stream_response, :stream_response)
    validate_skill_options!(spec)
    validate_tool_options!(spec)
    validate_context_options!(spec)
    validate_agentic_persistence_options!(spec)
    validate_router_options!(spec)
    spec
  end

  defp validate_provider_options!(%__MODULE__{provider: :echo}), do: :ok

  defp validate_provider_options!(%__MODULE__{provider: provider} = spec)
       when provider in [:openai, :openrouter] do
    require_non_empty_binary!(spec.model, :model)
    require_positive_integer!(spec.http_timeout_ms, :http_timeout_ms)
    AgentMachine.Pricing.validate!(spec.pricing)
  end

  defp atomize_keys!(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, _value}, _acc ->
        raise ArgumentError, "run spec keys must be atoms, got key: #{inspect(key)}"
    end)
  end

  defp require_workflow!(workflow) when workflow in [:chat, :basic, :agentic, :auto], do: :ok

  defp require_workflow!(workflow) do
    raise ArgumentError,
          "run spec :workflow must be :chat, :basic, :agentic, or :auto, got: #{inspect(workflow)}"
  end

  defp require_provider!(provider) when provider in [:echo, :openai, :openrouter], do: :ok

  defp require_provider!(provider) do
    raise ArgumentError,
          "run spec :provider must be :echo, :openai, or :openrouter, got: #{inspect(provider)}"
  end

  defp validate_tool_options!(%__MODULE__{
         tool_harnesses: nil,
         tool_timeout_ms: nil,
         tool_max_rounds: nil,
         tool_root: nil,
         tool_approval_mode: nil,
         test_commands: nil,
         mcp_config_path: nil,
         mcp_config: nil
       }),
       do: :ok

  defp validate_tool_options!(%__MODULE__{tool_harnesses: nil} = spec) do
    raise ArgumentError,
          "run spec tool options require :tool_harness or :tool_harnesses, got :tool_timeout_ms #{inspect(spec.tool_timeout_ms)}, :tool_max_rounds #{inspect(spec.tool_max_rounds)}, :tool_root #{inspect(spec.tool_root)}, :test_commands #{inspect(spec.test_commands)}, and :mcp_config_path #{inspect(spec.mcp_config_path)}"
  end

  defp validate_tool_options!(%__MODULE__{
         tool_harnesses: harnesses,
         tool_timeout_ms: timeout_ms,
         tool_max_rounds: max_rounds,
         tool_approval_mode: approval_mode,
         test_commands: test_commands
       })
       when harnesses in [[:demo], [:time]] do
    require_positive_integer!(timeout_ms, :tool_timeout_ms)
    require_positive_integer!(max_rounds, :tool_max_rounds)
    require_tool_approval_mode!(approval_mode)
    reject_test_commands_for_non_code_edit!(test_commands)
  end

  defp validate_tool_options!(%__MODULE__{
         tool_harnesses: harnesses,
         tool_timeout_ms: timeout_ms,
         tool_max_rounds: max_rounds,
         tool_root: root,
         tool_approval_mode: approval_mode,
         test_commands: test_commands,
         mcp_config_path: mcp_config_path,
         mcp_config: mcp_config
       })
       when is_list(harnesses) do
    validate_harnesses!(harnesses)
    require_positive_integer!(timeout_ms, :tool_timeout_ms)
    require_positive_integer!(max_rounds, :tool_max_rounds)
    require_tool_approval_mode!(approval_mode)
    maybe_require_tool_root!(harnesses, root)
    validate_test_commands!(harnesses, approval_mode, test_commands)
    validate_mcp_config!(harnesses, mcp_config_path, mcp_config)
  end

  defp validate_tool_options!(%__MODULE__{tool_harnesses: harness}) do
    raise ArgumentError,
          "run spec :tool_harnesses must be a non-empty list of :demo, :time, :local_files, :code_edit, :mcp, or :skills, got: #{inspect(harness)}"
  end

  defp normalize_skills!(attrs) do
    attrs
    |> Map.put_new(:skills_mode, :off)
    |> Map.put_new(:skill_names, [])
    |> Map.put_new(:allow_skill_scripts, false)
    |> Map.put_new(:stream_response, false)
    |> Map.put_new(:run_context_compaction, :off)
    |> Map.put_new(:router_mode, :llm)
    |> normalize_skill_names!()
  end

  defp validate_context_options!(%__MODULE__{} = spec) do
    require_optional_positive_integer!(spec.context_window_tokens, :context_window_tokens)
    require_optional_percent!(spec.context_warning_percent, :context_warning_percent)
    validate_context_tokenizer_path!(spec.context_tokenizer_path)
    require_optional_positive_integer!(spec.reserved_output_tokens, :reserved_output_tokens)
    require_run_context_compaction!(spec.run_context_compaction)
    validate_warning_requires_window!(spec)
    validate_run_context_compaction_options!(spec)
  end

  defp validate_context_tokenizer_path!(nil), do: :ok

  defp validate_context_tokenizer_path!(path) do
    ContextBudget.validate_tokenizer_path!(path)
    :ok
  end

  defp validate_warning_requires_window!(%__MODULE__{
         context_window_tokens: nil,
         context_warning_percent: percent
       })
       when not is_nil(percent) do
    raise ArgumentError, "run spec :context_warning_percent requires :context_window_tokens"
  end

  defp validate_warning_requires_window!(_spec), do: :ok

  defp validate_run_context_compaction_options!(%__MODULE__{run_context_compaction: :off} = spec) do
    if spec.run_context_compact_percent != nil or spec.max_context_compactions != nil do
      raise ArgumentError,
            "run spec run-context compaction options require :run_context_compaction :on"
    end
  end

  defp validate_run_context_compaction_options!(%__MODULE__{run_context_compaction: :on} = spec) do
    require_positive_integer!(spec.context_window_tokens, :context_window_tokens)
    require_percent!(spec.run_context_compact_percent, :run_context_compact_percent)
    require_positive_integer!(spec.max_context_compactions, :max_context_compactions)
  end

  defp validate_agentic_persistence_options!(%__MODULE__{agentic_persistence_rounds: nil}),
    do: :ok

  defp validate_agentic_persistence_options!(%__MODULE__{
         workflow: :agentic,
         agentic_persistence_rounds: rounds
       }) do
    require_positive_integer!(rounds, :agentic_persistence_rounds)
  end

  defp validate_agentic_persistence_options!(%__MODULE__{
         workflow: workflow,
         agentic_persistence_rounds: rounds
       }) do
    require_positive_integer!(rounds, :agentic_persistence_rounds)

    raise ArgumentError,
          "run spec :agentic_persistence_rounds requires :workflow :agentic, got: #{inspect(workflow)}"
  end

  defp require_run_context_compaction!(value) when value in [:off, :on], do: :ok

  defp require_run_context_compaction!(value) do
    raise ArgumentError,
          "run spec :run_context_compaction must be :off or :on, got: #{inspect(value)}"
  end

  defp validate_router_options!(%__MODULE__{
         router_mode: :deterministic,
         router_model_dir: nil,
         router_timeout_ms: nil,
         router_confidence_threshold: nil
       }),
       do: :ok

  defp validate_router_options!(%__MODULE__{router_mode: :deterministic} = spec) do
    raise ArgumentError,
          "run spec deterministic router does not accept local router options, got :router_model_dir #{inspect(spec.router_model_dir)}, :router_timeout_ms #{inspect(spec.router_timeout_ms)}, and :router_confidence_threshold #{inspect(spec.router_confidence_threshold)}"
  end

  defp validate_router_options!(%__MODULE__{
         router_mode: :llm,
         router_model_dir: nil,
         router_timeout_ms: nil,
         router_confidence_threshold: nil
       }),
       do: :ok

  defp validate_router_options!(%__MODULE__{router_mode: :llm} = spec) do
    raise ArgumentError,
          "run spec llm router does not accept local router options, got :router_model_dir #{inspect(spec.router_model_dir)}, :router_timeout_ms #{inspect(spec.router_timeout_ms)}, and :router_confidence_threshold #{inspect(spec.router_confidence_threshold)}"
  end

  defp validate_router_options!(%__MODULE__{
         router_mode: :local,
         router_model_dir: model_dir,
         router_timeout_ms: timeout_ms,
         router_confidence_threshold: threshold
       }) do
    require_non_empty_binary!(model_dir, :router_model_dir)
    require_positive_integer!(timeout_ms, :router_timeout_ms)
    require_probability!(threshold, :router_confidence_threshold)
  end

  defp validate_router_options!(%__MODULE__{router_mode: mode}) do
    raise ArgumentError,
          "run spec :router_mode must be :deterministic, :local, or :llm, got: #{inspect(mode)}"
  end

  defp normalize_skill_names!(%{skill_names: nil} = attrs), do: Map.put(attrs, :skill_names, [])

  defp normalize_skill_names!(%{skill_names: names} = attrs) when is_list(names) do
    Map.put(attrs, :skill_names, names)
  end

  defp normalize_skill_names!(%{skill_names: name} = attrs) when is_binary(name) do
    Map.put(attrs, :skill_names, [name])
  end

  defp normalize_skill_names!(%{skill_names: names}) do
    raise ArgumentError,
          "run spec :skill_names must be a list of skill names, got: #{inspect(names)}"
  end

  defp normalize_tool_harnesses!(attrs) do
    harness = Map.get(attrs, :tool_harness)
    harnesses = Map.get(attrs, :tool_harnesses)

    normalized =
      cond do
        is_nil(harnesses) and is_nil(harness) ->
          nil

        is_nil(harnesses) ->
          [harness]

        is_list(harnesses) ->
          harnesses

        true ->
          raise ArgumentError,
                "run spec :tool_harnesses must be a list, got: #{inspect(harnesses)}"
      end

    attrs
    |> Map.put(:tool_harnesses, normalize_harness_list!(normalized))
    |> Map.put(:tool_harness, first_harness(normalized))
    |> load_mcp_config_if_needed!()
  end

  defp normalize_harness_list!(nil), do: nil

  defp normalize_harness_list!(harnesses) when is_list(harnesses) and harnesses != [] do
    reject_duplicates!(harnesses, "run spec :tool_harnesses")
    harnesses
  end

  defp normalize_harness_list!(harnesses) do
    raise ArgumentError,
          "run spec :tool_harnesses must be a non-empty list when provided, got: #{inspect(harnesses)}"
  end

  defp first_harness(nil), do: nil
  defp first_harness([harness | _rest]), do: harness

  defp load_mcp_config_if_needed!(%{tool_harnesses: harnesses} = attrs) when is_list(harnesses) do
    if :mcp in harnesses and is_nil(Map.get(attrs, :mcp_config)) do
      Map.put(attrs, :mcp_config, Config.load!(Map.get(attrs, :mcp_config_path)))
    else
      attrs
    end
  end

  defp load_mcp_config_if_needed!(attrs), do: attrs

  defp validate_harnesses!(harnesses) when is_list(harnesses) and harnesses != [] do
    Enum.each(harnesses, fn
      harness when harness in [:demo, :time, :local_files, :code_edit, :mcp, :skills] ->
        :ok

      harness ->
        raise ArgumentError,
              "run spec :tool_harness must be :demo, :time, :local_files, :code_edit, :mcp, or :skills, got: #{inspect(harness)}"
    end)
  end

  defp validate_harnesses!(harnesses) do
    raise ArgumentError,
          "run spec :tool_harnesses must be a non-empty list, got: #{inspect(harnesses)}"
  end

  defp maybe_require_tool_root!(harnesses, root) do
    if Enum.any?(harnesses, &(&1 in [:local_files, :code_edit])) do
      require_non_empty_binary!(root, :tool_root)
    end
  end

  defp validate_mcp_config!(harnesses, mcp_config_path, mcp_config) do
    if :mcp in harnesses do
      require_non_empty_binary!(mcp_config_path, :mcp_config_path)

      unless match?(%Config{}, mcp_config) do
        raise ArgumentError,
              "run spec :mcp_config must be loaded when :tool_harnesses includes :mcp"
      end
    else
      if not is_nil(mcp_config_path) or not is_nil(mcp_config) do
        raise ArgumentError, "run spec :mcp_config_path requires :tool_harness :mcp"
      end
    end
  end

  defp validate_skill_options!(%__MODULE__{} = spec) do
    require_skills_mode!(spec.skills_mode)
    require_skill_names!(spec.skill_names)
    require_boolean!(spec.allow_skill_scripts, :allow_skill_scripts)

    skills_enabled? = spec.skills_mode == :auto or spec.skill_names != []
    validate_skill_mode_combination!(spec)
    validate_skills_dir!(spec, skills_enabled?)
    validate_skill_scripts!(spec, skills_enabled?)
    validate_skills_harness!(spec, skills_enabled?)
  end

  defp validate_skill_mode_combination!(%__MODULE__{skills_mode: :auto, skill_names: names})
       when names != [] do
    raise ArgumentError,
          "run spec :skills_mode :auto cannot be combined with explicit :skill_names"
  end

  defp validate_skill_mode_combination!(_spec), do: :ok

  defp validate_skills_dir!(spec, true),
    do: require_non_empty_binary!(spec.skills_dir, :skills_dir)

  defp validate_skills_dir!(%__MODULE__{skills_dir: nil}, false), do: :ok

  defp validate_skills_dir!(spec, false),
    do: require_non_empty_binary!(spec.skills_dir, :skills_dir)

  defp validate_skill_scripts!(%__MODULE__{allow_skill_scripts: false}, _skills_enabled?),
    do: :ok

  defp validate_skill_scripts!(spec, true) do
    unless is_list(spec.tool_harnesses) and :skills in spec.tool_harnesses do
      raise ArgumentError, "run spec :allow_skill_scripts requires :tool_harness :skills"
    end
  end

  defp validate_skill_scripts!(_spec, false) do
    raise ArgumentError, "run spec :allow_skill_scripts requires enabled skills"
  end

  defp validate_skills_harness!(%__MODULE__{tool_harnesses: harnesses}, false)
       when is_list(harnesses) do
    if :skills in harnesses do
      raise ArgumentError, "run spec :tool_harness :skills requires enabled skills"
    end
  end

  defp validate_skills_harness!(_spec, _skills_enabled?), do: :ok

  defp require_skills_mode!(mode) when mode in [:off, :auto], do: :ok

  defp require_skills_mode!(mode) do
    raise ArgumentError, "run spec :skills_mode must be :off or :auto, got: #{inspect(mode)}"
  end

  defp require_skill_names!(names) when is_list(names) do
    Enum.each(names, fn name ->
      require_non_empty_binary!(name, :skill_names)
      Manifest.validate_name!(name)
    end)

    reject_duplicates!(names, "run spec :skill_names")
  end

  defp require_skill_names!(names) do
    raise ArgumentError, "run spec :skill_names must be a list, got: #{inspect(names)}"
  end

  defp require_boolean!(value, _field) when is_boolean(value), do: :ok

  defp require_boolean!(value, field) do
    raise ArgumentError, "run spec #{inspect(field)} must be a boolean, got: #{inspect(value)}"
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0 do
    :ok
  end

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "run spec #{inspect(field)} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_positive_integer!(value, _field) when is_integer(value) and value > 0 do
    :ok
  end

  defp require_positive_integer!(value, field) do
    raise ArgumentError,
          "run spec #{inspect(field)} must be a positive integer, got: #{inspect(value)}"
  end

  defp require_optional_positive_integer!(nil, _field), do: :ok

  defp require_optional_positive_integer!(value, field),
    do: require_positive_integer!(value, field)

  defp require_percent!(value, _field) when is_integer(value) and value >= 1 and value <= 100,
    do: :ok

  defp require_percent!(value, field) do
    raise ArgumentError,
          "run spec #{inspect(field)} must be an integer between 1 and 100, got: #{inspect(value)}"
  end

  defp require_optional_percent!(nil, _field), do: :ok
  defp require_optional_percent!(value, field), do: require_percent!(value, field)

  defp require_probability!(value, _field)
       when is_float(value) and value > 0.0 and value <= 1.0 do
    :ok
  end

  defp require_probability!(value, field) do
    raise ArgumentError,
          "run spec #{inspect(field)} must be a float greater than 0.0 and less than or equal to 1.0, got: #{inspect(value)}"
  end

  defp require_tool_approval_mode!(mode)
       when mode in [:read_only, :ask_before_write, :auto_approved_safe, :full_access],
       do: :ok

  defp require_tool_approval_mode!(mode) do
    raise ArgumentError,
          "run spec :tool_approval_mode must be :read_only, :ask_before_write, :auto_approved_safe, or :full_access, got: #{inspect(mode)}"
  end

  defp reject_test_commands_for_non_code_edit!(nil), do: :ok

  defp reject_test_commands_for_non_code_edit!(test_commands) do
    raise ArgumentError,
          "run spec :test_commands require :tool_harness :code_edit, got: #{inspect(test_commands)}"
  end

  defp validate_test_commands!(_harnesses, _approval_mode, nil), do: :ok

  defp validate_test_commands!(harnesses, approval_mode, test_commands)
       when approval_mode in [:full_access, :ask_before_write] do
    unless :code_edit in harnesses do
      raise ArgumentError,
            "run spec :test_commands require :tool_harness :code_edit, got: #{inspect(harnesses)} with #{inspect(test_commands)}"
    end

    RunTestCommand.validate_allowlist!(test_commands)
  end

  defp validate_test_commands!(harnesses, _approval_mode, test_commands) do
    if :code_edit in harnesses do
      raise ArgumentError,
            "run spec :test_commands require :tool_approval_mode :full_access or :ask_before_write"
    else
      raise ArgumentError,
            "run spec :test_commands require :tool_harness :code_edit, got: #{inspect(harnesses)} with #{inspect(test_commands)}"
    end
  end

  defp reject_duplicates!(values, label) do
    duplicates =
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "#{label} must not contain duplicates: #{inspect(duplicates)}"
    end
  end
end
