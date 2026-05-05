defmodule AgentMachine.ReqLLMRuntimeConfigTest do
  use ExUnit.Case, async: true

  test "configures ReqLLM Finch pool for concurrent agentic streams" do
    finch_config = Application.fetch_env!(:req_llm, :finch)
    pools = Keyword.fetch!(finch_config, :pools)
    default_pool = Map.fetch!(pools, :default)

    assert Keyword.fetch!(finch_config, :name) == ReqLLM.Finch
    assert Keyword.fetch!(default_pool, :protocols) == [:http1]
    assert Keyword.fetch!(default_pool, :size) == 1
    assert Keyword.fetch!(default_pool, :count) >= 32
  end
end
