defmodule AgentMachine.Tools.SearchFilesTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.SearchFiles

  test "searches files under the configured tool root with rg" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-search-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "one.md"), "alpha\nneedle one\n")
    File.write!(Path.join(root, "two.md"), "needle two\n")

    assert {:ok, %{matches: matches, truncated: false}} =
             SearchFiles.run(%{"pattern" => "needle", "path" => ".", "max_results" => 10},
               tool_root: root
             )

    assert Enum.map(matches, &Path.basename(&1.path)) |> Enum.sort() == ["one.md", "two.md"]
    assert Enum.any?(matches, &(&1.text == "needle one"))
  end

  test "limits search results" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-search-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "one.md"), "needle one\nneedle two\n")

    assert {:ok, %{matches: [_one], truncated: true}} =
             SearchFiles.run(%{"pattern" => "needle", "path" => ".", "max_results" => 1},
               tool_root: root
             )
  end

  test "rejects search paths outside the configured root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-search-#{System.unique_integer()}"))

    outside = Path.expand(Path.join(System.tmp_dir!(), "outside.md"))

    File.mkdir_p!(root)

    assert {:error, message} =
             SearchFiles.run(%{"pattern" => "needle", "path" => outside, "max_results" => 10},
               tool_root: root
             )

    assert message =~ outside
    assert message =~ root
  end

  test "requires the configured tool root to exist" do
    root =
      Path.expand(
        Path.join(System.tmp_dir!(), "agent-machine-missing-#{System.unique_integer()}")
      )

    assert {:error, message} =
             SearchFiles.run(%{"pattern" => "needle", "path" => ".", "max_results" => 10},
               tool_root: root
             )

    assert message =~ "tool root does not exist"
  end
end
