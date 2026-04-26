Application.ensure_all_started(:agent_machine)
ExUnit.configure(exclude: [paid_openrouter: true])
ExUnit.start()
