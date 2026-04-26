defmodule AgentMachine.MCP.Config do
  @moduledoc """
  Validated MCP server/tool configuration.
  """

  alias AgentMachine.JSON

  @risks ~w(read write delete command network)

  defstruct [:path, servers: [], tools: []]

  @type t :: %__MODULE__{path: binary() | nil, servers: [Server.t()], tools: [Tool.t()]}

  defmodule Server do
    @moduledoc false
    defstruct [
      :id,
      :transport,
      :command,
      :args,
      :env,
      :url,
      :headers,
      :tools
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Tool do
    @moduledoc false
    defstruct [:server_id, :name, :provider_name, :permission, :risk]

    @type t :: %__MODULE__{}
  end

  def load!(path) do
    path = require_non_empty_binary!(path, "mcp config path")

    path
    |> File.read!()
    |> JSON.decode!()
    |> from_map!(path)
  rescue
    exception in [File.Error, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid MCP config #{inspect(path)}: #{Exception.message(exception)}"],
              __STACKTRACE__
  end

  def from_map!(config, path \\ nil)

  def from_map!(%{"servers" => servers}, path) when is_list(servers) and servers != [] do
    servers = Enum.map(servers, &server!/1)
    reject_duplicates!(Enum.map(servers, & &1.id), "MCP server id")

    tools = Enum.flat_map(servers, & &1.tools)
    reject_duplicates!(Enum.map(tools, & &1.provider_name), "MCP provider tool name")

    %__MODULE__{path: path, servers: servers, tools: tools}
  end

  def from_map!(config, _path) do
    raise ArgumentError,
          "MCP config must contain a non-empty servers list, got: #{inspect(config)}"
  end

  def server!(%{"id" => id, "transport" => transport, "tools" => tools} = server) do
    id = require_identifier!(id, "MCP server id")
    transport = transport!(transport)
    tools = tools!(id, tools)

    base = %Server{
      id: id,
      transport: transport,
      args: [],
      env: %{},
      headers: %{},
      tools: tools
    }

    case transport do
      :stdio ->
        %{
          base
          | command: command!(Map.get(server, "command")),
            args: string_list!(Map.get(server, "args"), "MCP stdio args"),
            env: env_refs!(Map.get(server, "env", %{}), "MCP stdio env")
        }

      :streamable_http ->
        %{
          base
          | url: url!(Map.get(server, "url")),
            headers: env_refs!(Map.get(server, "headers", %{}), "MCP HTTP headers")
        }
    end
  end

  def server!(server) do
    raise ArgumentError, "MCP server must be an object, got: #{inspect(server)}"
  end

  def server_by_id!(%__MODULE__{servers: servers}, id) do
    case Enum.find(servers, &(&1.id == id)) do
      nil -> raise ArgumentError, "unknown MCP server id: #{inspect(id)}"
      server -> server
    end
  end

  defp tools!(server_id, tools) when is_list(tools) and tools != [] do
    parsed = Enum.map(tools, &tool!(server_id, &1))
    reject_duplicates!(Enum.map(parsed, & &1.name), "MCP tool name for #{server_id}")

    reject_duplicates!(
      Enum.map(parsed, & &1.provider_name),
      "MCP provider tool name for #{server_id}"
    )

    parsed
  end

  defp tools!(server_id, tools) do
    raise ArgumentError,
          "MCP server #{inspect(server_id)} tools must be a non-empty list, got: #{inspect(tools)}"
  end

  defp tool!(
         server_id,
         %{"name" => name, "permission" => permission, "risk" => risk}
       ) do
    name = require_identifier!(name, "MCP tool name")
    permission = require_permission!(permission)
    risk = require_risk!(risk)

    %Tool{
      server_id: server_id,
      name: name,
      provider_name: provider_name!(server_id, name),
      permission: permission,
      risk: risk
    }
  end

  defp tool!(server_id, tool) do
    raise ArgumentError,
          "MCP server #{inspect(server_id)} tool must include name, permission, and risk, got: #{inspect(tool)}"
  end

  defp transport!("stdio"), do: :stdio
  defp transport!("streamable_http"), do: :streamable_http

  defp transport!(transport) do
    raise ArgumentError,
          "MCP transport must be stdio or streamable_http, got: #{inspect(transport)}"
  end

  defp command!(command) do
    command = require_non_empty_binary!(command, "MCP stdio command")

    if String.contains?(command, ["\n", "\r", "|", "&", ";", "`", "$(", ">", "<"]) do
      raise ArgumentError,
            "MCP stdio command must be an executable path/name, got: #{inspect(command)}"
    end

    command
  end

  defp url!(url) do
    url = require_non_empty_binary!(url, "MCP streamable_http url")

    unless String.starts_with?(url, ["http://", "https://"]) do
      raise ArgumentError, "MCP streamable_http url must start with http:// or https://"
    end

    url
  end

  defp string_list!(values, label) when is_list(values) do
    Enum.map(values, &require_non_empty_binary!(&1, label))
  end

  defp string_list!(nil, label) do
    raise ArgumentError, "#{label} must be an explicit list"
  end

  defp string_list!(values, label) do
    raise ArgumentError, "#{label} must be a list of strings, got: #{inspect(values)}"
  end

  defp env_refs!(values, label) when is_map(values) do
    Map.new(values, fn {key, value} ->
      key = require_non_empty_binary!(key, "#{label} key")
      value = require_non_empty_binary!(value, "#{label} value")

      unless String.starts_with?(value, "env:") and byte_size(value) > 4 do
        raise ArgumentError, "#{label} values must be env:NAME references, got: #{inspect(value)}"
      end

      {key, String.replace_prefix(value, "env:", "")}
    end)
  end

  defp env_refs!(values, label) do
    raise ArgumentError, "#{label} must be an object, got: #{inspect(values)}"
  end

  defp require_identifier!(value, label) do
    value = require_non_empty_binary!(value, label)

    unless value =~ ~r/^[A-Za-z0-9_-]+$/ do
      raise ArgumentError,
            "#{label} must contain only letters, numbers, _ or -, got: #{inspect(value)}"
    end

    value
  end

  defp require_permission!(permission) do
    permission = require_non_empty_binary!(permission, "MCP tool permission")

    unless permission =~ ~r/^[a-z][a-z0-9_]*$/ do
      raise ArgumentError,
            "MCP tool permission must be a lowercase atom name string, got: #{inspect(permission)}"
    end

    String.to_atom(permission)
  end

  defp require_risk!(risk) when risk in @risks, do: String.to_atom(risk)

  defp require_risk!(risk) do
    raise ArgumentError,
          "MCP tool risk must be one of #{inspect(@risks)}, got: #{inspect(risk)}"
  end

  defp provider_name!(server_id, tool_name) do
    "mcp_#{sanitize(server_id)}_#{sanitize(tool_name)}"
  end

  defp sanitize(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp reject_duplicates!(values, label) do
    duplicates =
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "#{label} must be unique, duplicates: #{inspect(duplicates)}"
    end
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty string, got: #{inspect(value)}"
  end
end
