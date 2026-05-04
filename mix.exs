defmodule AgentMachine.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_machine,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {AgentMachine.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        quality: :test
      ]
    ]
  end

  defp deps do
    [
      {:nx, "~> 0.6"},
      {:gun, "~> 2.2"},
      {:jason, "~> 1.4"},
      {:ortex, "~> 0.1.10"},
      {:req_llm, "~> 1.11"},
      {:telemetry, "~> 1.0"},
      {:tokenizers, "~> 0.5.1"},
      {:yamerl, "~> 0.10"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end
end
