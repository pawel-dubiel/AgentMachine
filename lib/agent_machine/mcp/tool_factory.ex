defmodule AgentMachine.MCP.ToolFactory do
  @moduledoc false

  def tools!(%AgentMachine.MCP.Config{tools: tools}) do
    Enum.map(tools, &module_for!/1)
  end

  def tools!(config) do
    raise ArgumentError, "mcp_config must be an AgentMachine.MCP.Config, got: #{inspect(config)}"
  end

  defp module_for!(%AgentMachine.MCP.Config.Tool{} = tool) do
    module =
      Module.concat([
        AgentMachine,
        MCP,
        DynamicTools,
        Macro.camelize(
          "#{tool.provider_name}_#{:erlang.phash2({tool.permission, tool.risk, tool.input_schema})}"
        )
      ])

    :global.trans({__MODULE__, module}, fn ->
      unless Code.ensure_loaded?(module) do
        create_or_wait_for_module!(module, quoted_tool(tool))
      end
    end)

    module
  end

  defp create_or_wait_for_module!(module, quoted) do
    Module.create(module, quoted, Macro.Env.location(__ENV__))
  rescue
    exception in CompileError ->
      if wait_for_module?(module, 50) do
        :ok
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp wait_for_module?(_module, 0), do: false

  defp wait_for_module?(module, attempts_left) do
    if Code.ensure_loaded?(module) do
      true
    else
      Process.sleep(10)
      wait_for_module?(module, attempts_left - 1)
    end
  end

  defp quoted_tool(tool) do
    quote bind_quoted: [
            provider_name: tool.provider_name,
            server_id: tool.server_id,
            tool_name: tool.name,
            permission: tool.permission,
            risk: tool.risk,
            argument_schema: Macro.escape(argument_schema(tool.input_schema))
          ] do
      @behaviour AgentMachine.Tool
      alias AgentMachine.MCP.ToolRunner

      @provider_name provider_name
      @server_id server_id
      @tool_name tool_name
      @permission permission
      @risk risk
      @argument_schema argument_schema

      @impl true
      def permission, do: @permission

      @impl true
      def approval_risk, do: @risk

      @impl true
      def definition do
        %{
          name: @provider_name,
          description: "Call MCP tool #{@server_id}.#{@tool_name}.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "arguments" =>
                %{
                  "description" => "Arguments to send to the MCP tool."
                }
                |> Map.merge(@argument_schema)
            },
            "required" => ["arguments"],
            "additionalProperties" => false
          }
        }
      end

      @impl true
      def run(input, opts) do
        ToolRunner.run(@server_id, @tool_name, input, opts)
      end
    end
  end

  defp argument_schema(schema) when schema == %{}, do: %{"type" => "object"}
  defp argument_schema(schema), do: schema
end
