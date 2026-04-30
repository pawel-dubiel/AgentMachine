defmodule AgentMachine.Tools.ToolDisplaySummaryTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.{FileInfo, ListFiles, Now, ReadFile, SearchFiles, WriteFile}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-tool-summary-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "read-only tools return safe display summaries", %{root: root} do
    File.write!(Path.join(root, "README.md"), "secret-ish content\nsecond line\n")

    assert {:ok, %{summary: %{tool: "now", utc: utc, timezone: "UTC"}}} = Now.run(%{}, [])
    assert is_binary(utc)

    assert {:ok, %{summary: %{tool: "file_info", path: "README.md", type: "regular", size: size}}} =
             FileInfo.run(%{"path" => "README.md"}, tool_root: root)

    assert size > 0

    assert {:ok, %{summary: %{tool: "list_files", path: ".", entry_count: 1}}} =
             ListFiles.run(%{"path" => ".", "max_entries" => 10}, tool_root: root)

    assert {:ok,
            %{summary: %{tool: "read_file", path: "README.md", bytes: bytes, line_count: lines}}} =
             ReadFile.run(%{"path" => "README.md", "max_bytes" => 100}, tool_root: root)

    assert bytes > 0
    assert lines > 0

    assert {:ok,
            %{summary: %{tool: "search_files", path: ".", pattern: "second", match_count: 1}}} =
             SearchFiles.run(%{"path" => ".", "pattern" => "second", "max_results" => 10},
               tool_root: root
             )
  end

  test "write summaries expose changed paths but not content", %{root: root} do
    assert {:ok, result} =
             WriteFile.run(%{"path" => "app.txt", "content" => "do not show this content"},
               tool_root: root
             )

    assert %{summary: %{tool: "write_file", changed_count: 1}, path: "app.txt"} = result
    refute inspect(result.summary) =~ "do not show this content"
  end
end
