defmodule Mix.Tasks.AgentMachine.Rollback do
  @moduledoc """
  Rolls back a code-edit checkpoint under an explicit tool root.
  """

  use Mix.Task

  alias AgentMachine.Tools.{CodeEditCheckpoint, PathGuard}

  @shortdoc "Rolls back a code-edit checkpoint"

  @switches [
    tool_root: :string,
    checkpoint_id: :string,
    json: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    if positional != [] do
      Mix.raise(
        "agent_machine.rollback does not accept positional arguments: #{inspect(positional)}"
      )
    end

    root = root_from_opts!(opts)
    checkpoint_id = checkpoint_id_from_opts!(opts)
    result = CodeEditCheckpoint.rollback!(root, checkpoint_id)

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(AgentMachine.JSON.encode!(result))
    else
      print_text_summary(result)
    end
  rescue
    exception in [ArgumentError, File.Error] ->
      Mix.raise(Exception.message(exception))
  end

  defp root_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_root) do
      {:ok, root} -> PathGuard.root!(tool_root: root)
      :error -> Mix.raise("missing required --tool-root option")
    end
  end

  defp checkpoint_id_from_opts!(opts) do
    case Keyword.fetch(opts, :checkpoint_id) do
      {:ok, checkpoint_id} -> CodeEditCheckpoint.require_checkpoint_id!(checkpoint_id)
      :error -> Mix.raise("missing required --checkpoint-id option")
    end
  end

  defp print_text_summary(result) do
    Mix.shell().info("Rolled back checkpoint #{result.rolled_back_checkpoint_id}")
    Mix.shell().info("Created rollback checkpoint #{result.checkpoint_id}")
    Mix.shell().info("Restored #{result.count} path(s)")
  end
end
