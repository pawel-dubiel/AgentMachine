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

  defmodule FixedIntentRunner do
    alias AgentMachine.LocalIntentClassifierTest.Score

    def score!(_model_dir, candidates) do
      intent =
        candidates
        |> hd()
        |> Map.fetch!(:premise)
        |> String.split("representative request for ")
        |> List.last()
        |> String.to_existing_atom()

      Score.score(candidates, intent, 0.88)
    end
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
    assert Enum.any?(candidates, &(&1.intent == :web_browse))
    assert Enum.all?(candidates, &String.contains?(&1.premise, "Current request"))
    assert Enum.any?(candidates, &String.contains?(&1.hypothesis, "edit"))
  end

  test "builds complex premise with pending action, recent context, and current request" do
    candidates =
      LocalIntentClassifier.candidate_inputs(%{
        pending_action: "Fix the corrupted weather_app.py script in Projekt1.",
        recent_context: "The previous run found weather_app.py but did not modify it.",
        task: "tak, zrób to teraz"
      })

    premise = candidates |> hd() |> Map.fetch!(:premise)

    assert premise =~ "Pending action:\nFix the corrupted weather_app.py script in Projekt1."
    assert premise =~ "Recent context:\nThe previous run found weather_app.py"
    assert premise =~ "Current request:\ntak, zrób to teraz"
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

  test "classifies every supported intent with injected zero-shot scores" do
    for intent <- LocalIntentClassifier.intents() do
      result =
        LocalIntentClassifier.classify!(%{
          task: "representative request for #{intent}",
          model_dir: "/tmp/router-model",
          timeout_ms: 100,
          confidence_threshold: 0.5,
          runner: FixedIntentRunner
        })

      assert result.intent == intent
      assert result.classified_intent == intent
      assert result.confidence == 0.88
    end
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

  test "ONNX runner scores zero-shot logits with entailment versus contradiction" do
    score = LocalIntentClassifier.OnnxRunner.zero_shot_probability!([0.0, 10.0, -2.0], 0, 2)

    assert_in_delta score, 0.880797, 0.000001
  end

  test "ONNX runner fails fast when required logits are missing" do
    assert_raise ArgumentError, ~r/entailment and contradiction logits/, fn ->
      LocalIntentClassifier.OnnxRunner.zero_shot_probability!([0.0], 0, 2)
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

  @tag :manual_router_model
  test "real local ONNX classifier predicts representative routing intents" do
    if model_dir = System.get_env("AGENT_MACHINE_ROUTER_MODEL_DIR") do
      cases = [
        {:none, "explain what progressive escalation means"},
        {:file_read, "read README.md and list the important sections"},
        {:file_mutation, "create a folder named reports in this project"},
        {:code_mutation, "edit lib/foo.ex and fix the Elixir code"},
        {:test_command, "run mix test"},
        {:time, "what time is it now"},
        {:web_browse, "open https://example.com in the browser"},
        {:tool_use, "use MCP tool to search documentation"},
        {:delegation, "use agents to review this project"}
      ]

      for {expected, task} <- cases do
        result =
          LocalIntentClassifier.classify!(%{
            task: task,
            model_dir: model_dir,
            timeout_ms: 10_000,
            confidence_threshold: 0.01
          })

        assert result.classified_intent == expected,
               "expected #{inspect(expected)} for #{inspect(task)}, got #{inspect(result)}"
      end
    end
  end

  @tag :manual_router_model
  test "real local ONNX classifier predicts complex multilingual routing intents" do
    if model_dir = System.get_env("AGENT_MACHINE_ROUTER_MODEL_DIR") do
      cases = [
        %{
          expected: :none,
          task:
            "Compare the tradeoffs between planner/direct routing and worker delegation in plain English; no tools or files needed."
        },
        %{
          expected: :file_read,
          task:
            "Hej, sprawdź README.md oraz lib/agent_machine/workflow_router.ex, ale nic nie zmieniaj; powiedz co robi auto mode."
        },
        %{
          expected: :file_mutation,
          task:
            "In the project folder create reports/2026 and write a short notes.txt file there; this is documentation, not code."
        },
        %{
          expected: :code_mutation,
          task:
            "Projekt1 has a broken weather_app.py. Rewrite the Python script so it can run, but keep API key placeholders configurable."
        },
        %{
          expected: :test_command,
          task:
            "After the router changes, run mix test test/agent_machine/workflow_router_test.exs and report failures."
        },
        %{
          expected: :time,
          task: "Jaki mamy teraz czas i dzisiejszą datę w UTC?"
        },
        %{
          expected: :web_browse,
          task: "Use Playwright to open https://example.com and tell me the page title."
        },
        %{
          expected: :tool_use,
          task:
            "Use the GitHub MCP tool to search issues for router timeout problems, but do not edit anything."
        },
        %{
          expected: :delegation,
          task:
            "Use two worker agents: one should review router behavior and another should review the TUI progress display."
        },
        %{
          expected: :code_mutation,
          pending_action: "Fix the existing Python weather app in Projekt1.",
          recent_context: "The app file was found, but it was malformed.",
          task: "tak, napraw to teraz"
        }
      ]

      for scenario <- cases do
        result =
          LocalIntentClassifier.classify!(%{
            task: Map.fetch!(scenario, :task),
            pending_action: Map.get(scenario, :pending_action),
            recent_context: Map.get(scenario, :recent_context),
            model_dir: model_dir,
            timeout_ms: 10_000,
            confidence_threshold: 0.01
          })

        assert result.classified_intent == scenario.expected,
               "expected #{inspect(scenario.expected)} for #{inspect(scenario.task)}, got #{inspect(result)}"
      end
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
