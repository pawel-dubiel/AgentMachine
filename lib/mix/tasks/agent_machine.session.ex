defmodule Mix.Tasks.AgentMachine.Session do
  @moduledoc """
  Runs a long-lived AgentMachine session daemon over bidirectional JSONL stdio.
  """

  use Mix.Task

  alias AgentMachine.{
    CapabilityRequired,
    JSON,
    PermissionControl,
    SessionProtocol,
    SessionServer,
    SessionWriter
  }

  @shortdoc "Runs a long-lived AgentMachine session daemon"

  @switches [
    jsonl_stdio: :boolean,
    session_id: :string,
    session_dir: :string,
    log_file: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    if positional != [] do
      Mix.raise("agent_machine.session does not accept positional arguments")
    end

    validate_opts!(opts)

    with_log_file(opts, fn log_io ->
      output = Process.group_leader()
      {:ok, writer} = SessionWriter.start_link(output: output, log_io: log_io)
      {:ok, permission_control} = PermissionControl.start_link(input: false)

      {:ok, session} =
        AgentMachine.SessionSupervisor.start_session(
          session_id: Keyword.fetch!(opts, :session_id),
          session_dir: Keyword.fetch!(opts, :session_dir),
          writer: writer,
          permission_control: permission_control
        )

      read_loop(session, writer, permission_control)
    end)
  end

  defp read_loop(session, writer, permission_control) do
    case IO.read(:stdio, :line) do
      data when is_binary(data) ->
        case data |> String.trim_trailing() |> handle_line(session, writer, permission_control) do
          :shutdown -> :ok
          _other -> read_loop(session, writer, permission_control)
        end

      :eof ->
        PermissionControl.cancel_all(permission_control, "session control input reached EOF")
        :ok

      {:error, reason} ->
        PermissionControl.cancel_all(
          permission_control,
          "session control input failed: #{inspect(reason)}"
        )
    end
  end

  defp handle_line(line, session, writer, permission_control) do
    case SessionProtocol.parse_command!(line) do
      %{type: :permission_decision, line: raw} ->
        PermissionControl.decide(permission_control, raw)

      %{type: :user_message} = command ->
        case SessionServer.user_message(session, command) do
          {:ok, _reply} -> :ok
          {:error, reason} -> write_error_summary(writer, reason)
        end

      %{type: :send_agent_message} = command ->
        input =
          agent_input(command.agent_ref, %{
            "message" => command.content,
            "resume" => command.resume
          })

        write_command_result(
          writer,
          "send_agent_message",
          command.message_id,
          SessionServer.send_agent_message(session, input)
        )

      %{type: :read_agent_output} = command ->
        input = agent_input(command.agent_ref, %{"limit" => command.limit})

        write_command_result(
          writer,
          "read_agent_output",
          command.request_id,
          SessionServer.read_agent_output(session, input)
        )

      %{type: :cancel_agent} = command ->
        input = agent_input(command.agent_ref, %{"reason" => command.reason})

        write_command_result(
          writer,
          "cancel_agent",
          command.request_id,
          SessionServer.cancel_agent(session, input)
        )

      %{type: :shutdown, reason: reason} ->
        PermissionControl.cancel_all(permission_control, reason)

        SessionWriter.write_line(
          writer,
          JSON.encode!(%{type: "session_shutdown", reason: reason})
        )

        :shutdown
    end
  rescue
    exception in ArgumentError ->
      reason = Exception.message(exception)
      PermissionControl.cancel_all(permission_control, "invalid session command: #{reason}")
      SessionWriter.write_line(writer, JSON.encode!(%{type: "session_error", error: reason}))
      :ok
  end

  defp write_command_result(writer, command, request_id, {:ok, result}) do
    SessionWriter.write_line(
      writer,
      SessionProtocol.response_line!(%{
        type: "session_command_result",
        command: command,
        request_id: request_id,
        status: "ok",
        result: result
      })
    )
  end

  defp write_command_result(writer, command, request_id, {:error, reason}) do
    SessionWriter.write_line(
      writer,
      SessionProtocol.response_line!(%{
        type: "session_command_result",
        command: command,
        request_id: request_id,
        status: "error",
        error: reason
      })
    )
  end

  defp write_error_summary(writer, reason) do
    summary =
      case reason do
        %CapabilityRequired{} = error ->
          event = CapabilityRequired.event(error)

          %{
            status: "failed",
            error: Exception.message(error),
            final_output: nil,
            results: %{},
            events: [event],
            capability_required: CapabilityRequired.to_map(error)
          }

        reason when is_binary(reason) ->
          %{status: "failed", error: reason, final_output: nil, results: %{}, events: []}
      end

    SessionWriter.write_line(
      writer,
      SessionProtocol.summary_line!(summary)
    )
  end

  defp agent_input({:agent_id, agent_id}, extras), do: Map.put(extras, "agent_id", agent_id)
  defp agent_input({:name, name}, extras), do: Map.put(extras, "name", name)

  defp validate_opts!(opts) do
    unless Keyword.get(opts, :jsonl_stdio, false) do
      Mix.raise("agent_machine.session requires --jsonl-stdio")
    end

    require_non_empty_path!(Keyword.get(opts, :session_id), "--session-id")
    require_non_empty_path!(Keyword.get(opts, :session_dir), "--session-dir")
  end

  defp with_log_file(opts, callback) when is_function(callback, 1) do
    case Keyword.fetch(opts, :log_file) do
      {:ok, path} ->
        path = require_non_empty_path!(path, "--log-file")
        File.mkdir_p!(Path.dirname(path))

        case File.open(path, [:append, :utf8]) do
          {:ok, io} ->
            try do
              callback.(io)
            after
              File.close(io)
            end

          {:error, reason} ->
            Mix.raise("failed to open --log-file #{inspect(path)}: #{inspect(reason)}")
        end

      :error ->
        callback.(nil)
    end
  end

  defp require_non_empty_path!(path, _flag) when is_binary(path) and byte_size(path) > 0,
    do: path

  defp require_non_empty_path!(path, flag) do
    Mix.raise("#{flag} must be a non-empty path, got: #{inspect(path)}")
  end
end
