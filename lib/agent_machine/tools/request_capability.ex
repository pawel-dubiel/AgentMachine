defmodule AgentMachine.Tools.RequestCapability do
  @moduledoc false

  def permission, do: :permission_control_request

  def approval_risk, do: :read

  def definition do
    %{
      name: "request_capability",
      description:
        "Ask the runtime and user to expose one narrow additional tool capability for this agent attempt.",
      input_schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["capability", "reason"],
        "properties" => %{
          "capability" => %{
            "type" => "string",
            "enum" => ["code_edit", "local_files", "mcp_tool", "test_command"]
          },
          "reason" => %{"type" => "string"},
          "root" => %{"type" => "string"},
          "tool" => %{"type" => "string"},
          "command" => %{"type" => "string"}
        }
      }
    }
  end

  def run(_input, _opts) do
    {:error, "request_capability must be handled by AgentMachine.AgentRunner"}
  end
end
