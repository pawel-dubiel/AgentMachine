defmodule AgentMachine.LocalIntentClassifierTest do
  use ExUnit.Case, async: true

  alias AgentMachine.LocalIntentClassifier

  defmodule EnglishEditRunner do
    alias AgentMachine.LocalIntentClassifierTest.Score

    def score!(_model_dir, candidates),
      do: Score.score(candidates, :code_mutation, 0.92)
  end

  defmodule PolishEditRunner do
    alias AgentMachine.LocalIntentClassifierTest.Score

    def score!(_model_dir, candidates),
      do: Score.score(candidates, :code_mutation, 0.91)
  end

  defmodule ReadRunner do
    alias AgentMachine.LocalIntentClassifierTest.Score

    def score!(_model_dir, candidates),
      do: Score.score(candidates, :file_read, 0.89)
  end

  defmodule LowConfidenceRunner do
    alias AgentMachine.LocalIntentClassifierTest.Score

    def score!(_model_dir, candidates),
      do: Score.score(candidates, :code_mutation, 0.30)
  end

  defmodule MalformedRunner do
    def score!(_model_dir, _candidates), do: [%{intent: :code_mutation, score: 0.9}]
  end

  defmodule Score do
    def score(candidates, matching_intent, matching_score) do
      Enum.map(candidates, fn candidate ->
        intent = Map.fetch!(candidate, :intent)
        score = if intent == matching_intent, do: matching_score, else: 0.01
        %{intent: intent, score: score}
      end)
    end
  end

  test "builds candidate inputs with current request and hypotheses" do
    candidates =
      LocalIntentClassifier.candidate_inputs(%{
        task: "please edit this file",
        recent_context: "README.md was selected"
      })

    assert length(candidates) == length(LocalIntentClassifier.intents())
    assert Enum.any?(candidates, &(&1.intent == :code_mutation))
    assert Enum.all?(candidates, &String.contains?(&1.premise, "Current request"))
    assert Enum.any?(candidates, &String.contains?(&1.hypothesis, "edit"))
  end

  test "classifies English edit request as code mutation with injected runner" do
    result =
      classify!("please edit this file and fix the script", EnglishEditRunner)

    assert result.intent == :code_mutation
    assert result.classified_intent == :code_mutation
    assert result.confidence == 0.92
  end

  test "classifies Polish edit request as code mutation with injected runner" do
    result =
      classify!("napraw prosze ten skrypt i przepisz kod", PolishEditRunner)

    assert result.intent == :code_mutation
  end

  test "classifies read or list folder request as file read with injected runner" do
    result =
      classify!("list files in this directory", ReadRunner)

    assert result.intent == :file_read
  end

  test "low confidence falls back to no tool intent" do
    result =
      classify!("normal explanation", LowConfidenceRunner)

    assert result.intent == :none
    assert result.classified_intent == :code_mutation
    assert result.reason == "local_classifier_below_confidence_threshold"
  end

  test "malformed score output fails fast" do
    assert_raise ArgumentError, ~r/one score per intent/, fn ->
      classify!("please edit", MalformedRunner)
    end
  end

  @tag :manual_router_model
  test "runs real local ONNX classifier when AGENT_MACHINE_ROUTER_MODEL_DIR is set" do
    if model_dir = System.get_env("AGENT_MACHINE_ROUTER_MODEL_DIR") do
      result =
        LocalIntentClassifier.classify!(%{
          task: "please edit this Python app",
          model_dir: model_dir,
          timeout_ms: 10_000,
          confidence_threshold: 0.1
        })

      assert result.classifier == "local"
      assert result.classifier_model == LocalIntentClassifier.model_id()
      assert result.classified_intent in LocalIntentClassifier.intents()
      assert is_float(result.confidence)
    end
  end

  defp classify!(task, runner) do
    LocalIntentClassifier.classify!(%{
      task: task,
      model_dir: "/tmp/router-model",
      timeout_ms: 100,
      confidence_threshold: 0.5,
      runner: runner
    })
  end
end
