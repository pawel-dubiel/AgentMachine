defmodule AgentMachine.ProviderCatalogTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias AgentMachine.{ProviderCatalog, RunSpec}
  alias Mix.Tasks.AgentMachine.Providers, as: ProvidersTask

  @requested_provider_ids ~w(
    alibaba
    alibaba_cn
    anthropic
    openai
    google
    google_vertex
    amazon_bedrock
    azure
    groq
    xai
    openrouter
    cerebras
    meta
    minimax
    zai
    zai_coder
    zenmux
    venice
    vllm
  )

  setup do
    original = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("OPENROUTER_API_KEY")
        value -> System.put_env("OPENROUTER_API_KEY", value)
      end
    end)

    :ok
  end

  test "catalog accounts for every requested provider and marks missing ReqLLM support explicitly" do
    assert ProviderCatalog.all_requested_provider_ids() == Enum.sort(@requested_provider_ids)

    assert %{
             id: "minimax",
             label: "MiniMax",
             status: :unsupported,
             reason: reason
           } = List.first(ProviderCatalog.unsupported_requested_providers())

    assert reason =~ "ReqLLM 1.11"
  end

  test "fetch rejects unknown and unsupported provider ids without creating provider atoms" do
    assert_raise ArgumentError, ~r/unsupported provider "missing"/, fn ->
      ProviderCatalog.fetch!("missing")
    end

    assert_raise ArgumentError, ~r/provider "minimax" is not supported/, fn ->
      ProviderCatalog.fetch!("minimax")
    end
  end

  test "required provider option validation fails fast" do
    assert_raise ArgumentError, ~r/provider "google_vertex" requires option "project_id"/, fn ->
      ProviderCatalog.validate_options!("google_vertex", %{"region" => "us-central1"})
    end

    assert_raise ArgumentError, ~r/does not accept option/, fn ->
      ProviderCatalog.validate_options!("openrouter", %{"base_url" => "https://example.test"})
    end
  end

  test "runtime options use catalog env names and validated non-secret fields" do
    assert [api_key: "test-openrouter-key"] = ProviderCatalog.runtime_options!("openrouter", %{})

    vertex_opts =
      with_env("AGENT_MACHINE_GOOGLE_VERTEX_ACCESS_TOKEN", "vertex-token", fn ->
        ProviderCatalog.runtime_options!("google_vertex", %{
          "project_id" => "project-1",
          "region" => "us-central1"
        })
      end)

    assert Map.new(vertex_opts) == %{
             access_token: "vertex-token",
             project_id: "project-1",
             region: "us-central1"
           }
  end

  test "runtime options fail fast on missing provider secrets" do
    with_env("OPENROUTER_API_KEY", nil, fn ->
      assert_raise ArgumentError,
                   ~r/provider "openrouter" requires secret "api_key" in OPENROUTER_API_KEY/,
                   fn ->
                     ProviderCatalog.runtime_options!("openrouter", %{})
                   end
    end)
  end

  test "model specs keep provider/model separated until the Elixir ReqLLM boundary" do
    assert ProviderCatalog.model_spec!("openrouter", "openai/gpt-4o-mini", %{}) ==
             "openrouter:openai/gpt-4o-mini"

    assert ProviderCatalog.model_spec!("vllm", "served-model", %{
             "base_url" => "http://localhost:8000/v1"
           }) == %{provider: :vllm, id: "served-model", base_url: "http://localhost:8000/v1"}
  end

  test "run specs require explicit remote provider ids instead of provider atoms" do
    assert %RunSpec{provider: "openrouter"} =
             RunSpec.new!(%{
               task: "hello",
               workflow: :agentic,
               provider: "openrouter",
               model: "openai/gpt-4o-mini",
               timeout_ms: 1_000,
               max_steps: 2,
               max_attempts: 1,
               http_timeout_ms: 1_000,
               pricing: %{input_per_million: 0.15, output_per_million: 0.60}
             })

    assert_raise ArgumentError, ~r/supported ReqLLM provider id/, fn ->
      RunSpec.new!(%{
        task: "hello",
        workflow: :agentic,
        provider: :openrouter,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1
      })
    end
  end

  test "providers mix task exposes catalog and model metadata as JSON" do
    Mix.Task.reenable("agent_machine.providers")

    catalog =
      capture_io(fn ->
        ProvidersTask.run(["--json", "--include-unsupported"])
      end)
      |> String.trim()
      |> AgentMachine.JSON.decode!()

    assert Enum.any?(catalog["providers"], &(&1["id"] == "openrouter"))

    assert [%{"id" => "minimax", "status" => "unsupported"}] =
             catalog["unsupported_requested_providers"]

    Mix.Task.reenable("agent_machine.providers")

    models =
      capture_io(fn ->
        ProvidersTask.run(["models", "--provider", "openrouter", "--json"])
      end)
      |> String.trim()
      |> AgentMachine.JSON.decode!()

    assert models["provider"] == "openrouter"
    assert is_list(models["models"])
  end

  defp with_env(key, value, fun) do
    original = System.get_env(key)

    case value do
      nil -> System.delete_env(key)
      value -> System.put_env(key, value)
    end

    try do
      fun.()
    after
      case original do
        nil -> System.delete_env(key)
        value -> System.put_env(key, value)
      end
    end
  end
end
