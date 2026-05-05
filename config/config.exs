import Config

config :req_llm,
  load_dotenv: false,
  redact_context: true,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      # Agentic runs can stream planner, worker, progress-observer, and
      # continuation requests concurrently. Keep HTTP/1 to match ReqLLM's
      # large-prompt guidance, but use a larger pool than the library default.
      :default => [protocols: [:http1], size: 1, count: 32]
    }
  ]
