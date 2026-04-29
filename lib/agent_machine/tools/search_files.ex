defmodule AgentMachine.Tools.SearchFiles do
  @moduledoc """
  Fast local text search constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.{JSON, Tools.PathGuard}
  alias AgentMachine.Secrets.Redactor

  @max_results_limit 200

  @impl true
  def permission, do: :local_files_search

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "search_files",
      description:
        "Search file contents under a narrow path using ripgrep. This does not find file or directory names; use list_files or file_info first when the user names a known path.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string"},
          "path" => %{
            "type" => "string",
            "description" =>
              "Relative path under the configured root, or an absolute path inside that root."
          },
          "max_results" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_results_limit
          }
        },
        "required" => ["pattern", "path", "max_results"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    pattern = input |> fetch_input!("pattern") |> PathGuard.require_non_empty_binary!("pattern")
    path = input |> fetch_input!("path") |> PathGuard.require_non_empty_binary!("path")
    max_results = input |> fetch_input!("max_results") |> require_max_results!()
    target = PathGuard.existing_target!(root, path)
    rg = rg_executable!()

    case System.cmd(rg, ["--json", "--", pattern, target], stderr_to_stdout: true) do
      {output, 0} ->
        matches = parse_matches(output, max_results)
        {matches, redaction} = redact_matches(matches)

        result = %{
          matches: matches,
          truncated: truncated?(output, max_results)
        }

        {:ok, Redactor.put_tool_metadata(result, redaction)}

      {_output, 1} ->
        {:ok, %{matches: [], truncated: false}}

      {output, status} ->
        {:error, %{status: status, output: output}}
    end
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch_input!(input, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "search_files input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("pattern"), do: :pattern
  defp input_atom_key!("path"), do: :path
  defp input_atom_key!("max_results"), do: :max_results

  defp require_max_results!(value) when is_integer(value) and value in 1..@max_results_limit do
    value
  end

  defp require_max_results!(value) do
    raise ArgumentError,
          "max_results must be an integer from 1 to #{@max_results_limit}, got: #{inspect(value)}"
  end

  defp rg_executable! do
    System.find_executable("rg") ||
      raise ArgumentError, "rg executable is required for search_files but was not found in PATH"
  end

  defp parse_matches(output, max_results) do
    output
    |> String.split("\n", trim: true)
    |> Stream.map(&JSON.decode!/1)
    |> Stream.filter(&(&1["type"] == "match"))
    |> Stream.map(&match_from_event!/1)
    |> Enum.take(max_results)
  end

  defp truncated?(output, max_results) do
    output
    |> String.split("\n", trim: true)
    |> Stream.map(&JSON.decode!/1)
    |> Enum.count(&(&1["type"] == "match"))
    |> Kernel.>(max_results)
  end

  defp match_from_event!(%{"data" => data}) do
    %{
      path: get_in(data, ["path", "text"]),
      line: Map.fetch!(data, "line_number"),
      text: get_in(data, ["lines", "text"]) |> String.trim_trailing()
    }
  end

  defp redact_matches(matches) do
    results = Enum.map(matches, &redact_match/1)

    redaction = %{
      redacted: Enum.any?(results, fn {_match, result} -> result.redacted end),
      count: Enum.reduce(results, 0, fn {_match, result}, count -> count + result.count end),
      reasons:
        results
        |> Enum.flat_map(fn {_match, result} -> result.reasons end)
        |> Enum.uniq()
        |> Enum.sort()
    }

    {Enum.map(results, fn {match, _redaction} -> match end), redaction}
  end

  defp redact_match(%{text: text} = match) when is_binary(text) do
    redaction = Redactor.redact_string(text)
    {%{match | text: redaction.value}, redaction}
  end
end
