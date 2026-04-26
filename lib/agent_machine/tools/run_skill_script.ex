defmodule AgentMachine.Tools.RunSkillScript do
  @moduledoc """
  Runs an explicitly enabled script bundled with a selected skill.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Skills.ResourceStore

  @max_output_bytes 50_000

  @impl true
  def permission, do: :skills_script_run

  @impl true
  def approval_risk, do: :command

  @impl true
  def definition do
    %{
      name: "run_skill_script",
      description:
        "Run a script bundled with a selected skill. This is unavailable unless skill scripts are explicitly enabled.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{"type" => "string"},
          "path" => %{"type" => "string"},
          "args" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["skill", "path", "args"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    unless Keyword.get(opts, :allow_skill_scripts, false) == true do
      raise ArgumentError, "skill scripts are not enabled for this run"
    end

    skills = ResourceStore.selected_skills!(opts)
    skill_name = fetch_input!(input, "skill")
    script_path = fetch_input!(input, "path")
    args = input |> fetch_input!("args") |> require_args!()
    {skill, target} = ResourceStore.script_path!(skills, skill_name, script_path)

    case System.cmd(target, args, cd: skill.root, stderr_to_stdout: true) do
      {output, status} ->
        {bounded, truncated} = bound_output(output)
        redaction = Redactor.redact_string(bounded)

        {:ok,
         Redactor.put_tool_metadata(
           %{
             skill: skill.name,
             path: script_path,
             status: status,
             output: redaction.value,
             truncated: truncated
           },
           redaction
         )}
    end
  rescue
    exception in [ArgumentError, ErlangError, File.Error] ->
      {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "run_skill_script input is missing #{inspect(key)}"
    end
  end

  defp require_args!(args) when is_list(args) do
    Enum.map(args, fn
      arg when is_binary(arg) -> arg
      arg -> raise ArgumentError, "script args must be strings, got: #{inspect(arg)}"
    end)
  end

  defp require_args!(args) do
    raise ArgumentError, "script args must be a list, got: #{inspect(args)}"
  end

  defp bound_output(output) do
    if byte_size(output) <= @max_output_bytes do
      {output, false}
    else
      {binary_part(output, 0, @max_output_bytes), true}
    end
  end
end
