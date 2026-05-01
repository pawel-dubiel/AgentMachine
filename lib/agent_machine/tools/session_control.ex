defmodule AgentMachine.Tools.SpawnSessionAgent do
  @moduledoc false

  @behaviour AgentMachine.Tool

  def permission, do: :session_control
  def approval_risk, do: :read

  def definition do
    %{
      name: "spawn_agent",
      description: "Start a named session sidechain agent from an explicit briefing.",
      input_schema: %{
        type: "object",
        additionalProperties: false,
        required: ["name", "briefing"],
        properties: %{
          name: %{type: "string", minLength: 1},
          briefing: %{type: "string", minLength: 1},
          instructions: %{type: "string"},
          background: %{type: "boolean"},
          fork_context: %{type: "boolean"}
        }
      }
    }
  end

  def run(input, opts) when is_map(input) and is_list(opts) do
    opts
    |> session_server!()
    |> AgentMachine.SessionServer.spawn_agent(input)
  end

  defp session_server!(opts) do
    case Keyword.fetch(opts, :session_server) do
      {:ok, pid} when is_pid(pid) ->
        pid

      other ->
        raise ArgumentError,
              "session_server must be configured for session-control tools, got: #{inspect(other)}"
    end
  end
end

defmodule AgentMachine.Tools.SendSessionAgentMessage do
  @moduledoc false

  @behaviour AgentMachine.Tool

  def permission, do: :session_control
  def approval_risk, do: :read

  def definition do
    %{
      name: "send_agent_message",
      description:
        "Send a message to a running session agent or resume a completed session agent.",
      input_schema: %{
        type: "object",
        additionalProperties: false,
        required: ["message"],
        properties: %{
          agent_id: %{type: "string", minLength: 1},
          name: %{type: "string", minLength: 1},
          message: %{type: "string", minLength: 1},
          resume: %{type: "boolean"}
        }
      }
    }
  end

  def run(input, opts) when is_map(input) and is_list(opts) do
    opts
    |> session_server!()
    |> AgentMachine.SessionServer.send_agent_message(input)
  end

  defp session_server!(opts) do
    case Keyword.fetch(opts, :session_server) do
      {:ok, pid} when is_pid(pid) ->
        pid

      other ->
        raise ArgumentError,
              "session_server must be configured for session-control tools, got: #{inspect(other)}"
    end
  end
end

defmodule AgentMachine.Tools.ReadSessionAgentOutput do
  @moduledoc false

  @behaviour AgentMachine.Tool

  def permission, do: :session_control
  def approval_risk, do: :read

  def definition do
    %{
      name: "read_agent_output",
      description:
        "Read bounded status, output, summary, and transcript tail for a session agent.",
      input_schema: %{
        type: "object",
        additionalProperties: false,
        properties: %{
          agent_id: %{type: "string", minLength: 1},
          name: %{type: "string", minLength: 1},
          limit: %{type: "integer", minimum: 1, maximum: 100}
        }
      }
    }
  end

  def run(input, opts) when is_map(input) and is_list(opts) do
    opts
    |> session_server!()
    |> AgentMachine.SessionServer.read_agent_output(input)
  end

  defp session_server!(opts) do
    case Keyword.fetch(opts, :session_server) do
      {:ok, pid} when is_pid(pid) ->
        pid

      other ->
        raise ArgumentError,
              "session_server must be configured for session-control tools, got: #{inspect(other)}"
    end
  end
end

defmodule AgentMachine.Tools.ListSessionAgents do
  @moduledoc false

  @behaviour AgentMachine.Tool

  def permission, do: :session_control
  def approval_risk, do: :read

  def definition do
    %{
      name: "list_session_agents",
      description: "List active and completed agents in the current session.",
      input_schema: %{
        type: "object",
        additionalProperties: false,
        properties: %{}
      }
    }
  end

  def run(input, opts) when is_map(input) and is_list(opts) do
    opts
    |> session_server!()
    |> AgentMachine.SessionServer.list_agents()
  end

  defp session_server!(opts) do
    case Keyword.fetch(opts, :session_server) do
      {:ok, pid} when is_pid(pid) ->
        pid

      other ->
        raise ArgumentError,
              "session_server must be configured for session-control tools, got: #{inspect(other)}"
    end
  end
end
