defmodule AgentMachine.Tools.ReadSkillResource do
  @moduledoc """
  Reads references and assets bundled with selected AgentMachine skills.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Skills.ResourceStore

  @max_bytes_limit 200_000

  @impl true
  def permission, do: :skills_resource_read

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "read_skill_resource",
      description: "Read a UTF-8 reference or asset file from a skill selected for this run.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{"type" => "string"},
          "path" => %{"type" => "string"},
          "max_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_bytes_limit}
        },
        "required" => ["skill", "path", "max_bytes"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    skills = ResourceStore.selected_skills!(opts)
    skill = fetch_input!(input, "skill")
    path = fetch_input!(input, "path")
    max_bytes = input |> fetch_input!("max_bytes") |> require_max_bytes!()
    target = ResourceStore.readable_path!(skills, skill, path)
    {content, truncated} = read_text!(target, max_bytes)
    redaction = Redactor.redact_string(content)

    result = %{
      skill: skill,
      path: path,
      content: redaction.value,
      bytes: byte_size(redaction.value),
      truncated: truncated
    }

    {:ok, Redactor.put_tool_metadata(result, redaction)}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "read_skill_resource input is missing #{inspect(key)}"
    end
  end

  defp require_max_bytes!(value) when is_integer(value) and value in 1..@max_bytes_limit,
    do: value

  defp require_max_bytes!(value) do
    raise ArgumentError,
          "max_bytes must be an integer from 1 to #{@max_bytes_limit}, got: #{inspect(value)}"
  end

  defp read_text!(target, max_bytes) do
    data =
      File.open!(target, [:read, :binary], fn file ->
        case IO.binread(file, max_bytes + 1) do
          :eof -> ""
          bytes -> bytes
        end
      end)

    truncated = byte_size(data) > max_bytes
    content = binary_part(data, 0, min(byte_size(data), max_bytes))

    if String.valid?(content) do
      {content, truncated}
    else
      raise ArgumentError, "skill resource content must be valid UTF-8 text"
    end
  end
end
