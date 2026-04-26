defmodule AgentMachine.Tools.RollbackCheckpoint do
  @moduledoc """
  Roll back a code-edit checkpoint under the configured tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.{CodeEditCheckpoint, CodeEditSupport, PathGuard}

  @impl true
  def permission, do: :code_edit_rollback_checkpoint

  @impl true
  def approval_risk, do: :write

  @impl true
  def definition do
    %{
      name: "rollback_checkpoint",
      description:
        "Restore files from a prior code-edit checkpoint after verifying current files still match the checkpoint after-state.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "checkpoint_id" => %{"type" => "string"}
        },
        "required" => ["checkpoint_id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)

    checkpoint_id =
      input
      |> fetch!("checkpoint_id")
      |> CodeEditCheckpoint.require_checkpoint_id!()

    {:ok, CodeEditCheckpoint.rollback!(root, checkpoint_id)}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch!(input, key), do: CodeEditSupport.fetch_input!(input, "rollback_checkpoint", key)
end
