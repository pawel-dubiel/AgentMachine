defmodule AgentMachine.LocalIntentClassifier do
  @moduledoc false

  alias AgentMachine.JSON

  @model_id "MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7"

  @intents [
    :none,
    :file_read,
    :file_mutation,
    :code_mutation,
    :test_command,
    :time,
    :web_browse,
    :tool_use,
    :delegation
  ]

  @hypotheses %{
    none: "This request is normal chat, explanation, or discussion without tool use.",
    file_read:
      "This request asks to inspect, list, search, check, or read local files or directories.",
    file_mutation:
      "This request asks to create, write, edit, delete, rename, or modify local files.",
    code_mutation:
      "This request asks to edit, patch, fix, repair, or rewrite code, an app, or a script.",
    test_command:
      "This request asks to run tests, execute a test command, or verify by running a command.",
    time: "This request asks for the current time or current date.",
    web_browse:
      "This request asks to open, access, browse, inspect, or read a website, web page, URL, or browser page.",
    tool_use:
      "This request explicitly asks to use a tool, API, MCP server, or external tool integration.",
    delegation:
      "This request explicitly asks to use agents, workers, subagents, or delegated work."
  }

  def model_id, do: @model_id
  def intents, do: @intents

  def candidate_inputs(input) when is_map(input) do
    premise = premise(input)

    Enum.map(@intents, fn intent ->
      %{
        intent: intent,
        premise: premise,
        hypothesis: Map.fetch!(@hypotheses, intent)
      }
    end)
  end

  def classify!(input) when is_map(input) do
    model_dir = require_non_empty_binary!(Map.get(input, :model_dir), :model_dir)
    timeout_ms = require_positive_integer!(Map.get(input, :timeout_ms), :timeout_ms)
    threshold = require_threshold!(Map.get(input, :confidence_threshold))
    runner = Map.get(input, :runner, __MODULE__.OnnxRunner)
    candidates = candidate_inputs(input)

    scores =
      runner
      |> run_with_timeout!(model_dir, candidates, timeout_ms)
      |> validate_scores!()

    best = Enum.max_by(scores, & &1.score)

    if best.score >= threshold do
      %{
        intent: best.intent,
        classified_intent: best.intent,
        classifier: "local",
        classifier_model: @model_id,
        confidence: best.score,
        reason: "local_classifier_matched_#{best.intent}"
      }
    else
      %{
        intent: :none,
        classified_intent: best.intent,
        classifier: "local",
        classifier_model: @model_id,
        confidence: best.score,
        reason: "local_classifier_below_confidence_threshold"
      }
    end
  end

  def classify!(input) do
    raise ArgumentError, "local intent classifier input must be a map, got: #{inspect(input)}"
  end

  defp run_with_timeout!(runner, model_dir, candidates, timeout_ms) do
    task = Task.async(fn -> runner.score!(model_dir, candidates) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        raise ArgumentError, "local intent classifier timed out after #{timeout_ms}ms"
    end
  end

  defp validate_scores!(scores) when is_list(scores) and length(scores) == length(@intents) do
    Enum.map(scores, fn
      %{intent: intent, score: score} = item when intent in @intents and is_number(score) ->
        %{intent: intent, score: score * 1.0, reason: Map.get(item, :reason)}

      score ->
        raise ArgumentError, "invalid local intent classifier score: #{inspect(score)}"
    end)
  end

  defp validate_scores!(scores) do
    raise ArgumentError,
          "local intent classifier must return one score per intent, got: #{inspect(scores)}"
  end

  defp premise(input) do
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

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0 do
    value
  end

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "local intent classifier #{inspect(field)} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_positive_integer!(value, _field) when is_integer(value) and value > 0, do: value

  defp require_positive_integer!(value, field) do
    raise ArgumentError,
          "local intent classifier #{inspect(field)} must be a positive integer, got: #{inspect(value)}"
  end

  defp require_threshold!(value) when is_float(value) and value > 0.0 and value <= 1.0, do: value

  defp require_threshold!(value) do
    raise ArgumentError,
          "local intent classifier :confidence_threshold must be a float greater than 0.0 and less than or equal to 1.0, got: #{inspect(value)}"
  end

  defmodule OnnxRunner do
    @moduledoc false

    alias Tokenizers.{Encoding, Tokenizer}

    @onnx_path Path.join(["onnx", "model_quantized.onnx"])

    def score!(model_dir, candidates) when is_binary(model_dir) and is_list(candidates) do
      assets = load_assets!(model_dir)

      Enum.map(candidates, fn candidate ->
        %{
          intent: Map.fetch!(candidate, :intent),
          score: score_candidate!(assets, candidate)
        }
      end)
    end

    defp score_candidate!(assets, candidate) do
      encoding = encode!(assets.tokenizer, candidate)
      tensors = tensors_for_model!(assets.inputs, encoding)
      {logits} = Ortex.run(assets.model, List.to_tuple(tensors))

      logits
      |> Nx.backend_transfer(Nx.BinaryBackend)
      |> Nx.to_flat_list()
      |> entailment_probability!(assets.entailment_index)
    end

    defp encode!(tokenizer, %{premise: premise, hypothesis: hypothesis}) do
      case Tokenizer.encode(tokenizer, {premise, hypothesis}) do
        {:ok, encoding} ->
          encoding

        {:error, reason} ->
          raise ArgumentError, "failed to tokenize local router input: #{inspect(reason)}"
      end
    end

    defp tensors_for_model!(inputs, encoding) do
      input_ids = Encoding.get_ids(encoding)
      attention_mask = Encoding.get_attention_mask(encoding)
      type_ids = Encoding.get_type_ids(encoding)

      Enum.map(inputs, fn {name, _type, _shape} ->
        cond do
          String.contains?(name, "input_ids") ->
            int64_tensor(input_ids)

          String.contains?(name, "attention_mask") ->
            int64_tensor(attention_mask)

          String.contains?(name, "token_type_ids") ->
            int64_tensor(type_ids)

          true ->
            raise ArgumentError, "unsupported ONNX router model input: #{inspect(name)}"
        end
      end)
    end

    defp int64_tensor(values) when is_list(values) do
      values
      |> then(&Nx.tensor([&1], type: {:s, 64}))
    end

    defp entailment_probability!(logits, entailment_index)
         when is_list(logits) and entailment_index in 0..2 do
      if length(logits) < 3 do
        raise ArgumentError, "local router ONNX output must contain at least 3 logits"
      end

      max = Enum.max(logits)
      exps = Enum.map(logits, &:math.exp(&1 - max))
      total = Enum.sum(exps)

      exps
      |> Enum.at(entailment_index)
      |> Kernel./(total)
    end

    defp load_assets!(model_dir) do
      model_dir = Path.expand(model_dir)
      key = {__MODULE__, model_dir}

      case :persistent_term.get(key, :missing) do
        :missing ->
          assets = do_load_assets!(model_dir)
          :persistent_term.put(key, assets)
          assets

        assets ->
          assets
      end
    end

    defp do_load_assets!(model_dir) do
      tokenizer_path = Path.join(model_dir, "tokenizer.json")
      onnx_path = Path.join(model_dir, @onnx_path)
      config_path = Path.join(model_dir, "config.json")

      require_file!(tokenizer_path)
      require_file!(onnx_path)
      require_file!(config_path)

      tokenizer =
        case Tokenizer.from_file(tokenizer_path) do
          {:ok, tokenizer} ->
            tokenizer

          {:error, reason} ->
            raise ArgumentError, "failed to load local router tokenizer: #{inspect(reason)}"
        end

      model = Ortex.load(onnx_path)
      inputs = model_inputs!(model)

      %{
        tokenizer: tokenizer,
        model: model,
        inputs: inputs,
        entailment_index: entailment_index!(config_path)
      }
    end

    defp require_file!(path) do
      unless File.regular?(path) do
        raise ArgumentError, "required local router model file does not exist: #{path}"
      end
    end

    defp model_inputs!(%Ortex.Model{reference: reference}) do
      case Ortex.Native.show_session(reference) do
        {:error, reason} -> raise ArgumentError, "failed to inspect ONNX router model: #{reason}"
        {inputs, _outputs} when is_list(inputs) -> inputs
      end
    end

    defp entailment_index!(config_path) do
      config = config_path |> File.read!() |> JSON.decode!()
      id2label = Map.fetch!(config, "id2label")

      id2label
      |> Enum.find_value(fn {index, label} ->
        if label |> String.downcase() |> String.contains?("entail") do
          String.to_integer(index)
        end
      end)
      |> case do
        nil -> raise ArgumentError, "local router config.json does not define an entailment label"
        index -> index
      end
    end
  end
end
