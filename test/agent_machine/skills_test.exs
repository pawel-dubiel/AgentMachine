defmodule AgentMachine.SkillsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias AgentMachine.{ClientRunner, JSON}
  alias AgentMachine.Skills.{Creator, Installer, Loader, Manifest, Registry, Selector}
  alias AgentMachine.Tools.{ReadSkillResource, RunSkillScript}
  alias Mix.Tasks.AgentMachine.Skills, as: SkillsTask

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-skills-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "loads a valid Codex-compatible skill manifest", %{root: root} do
    skill_dir = write_skill!(root, "docs-helper", "Helps with project docs", "Use docs style.")
    File.mkdir_p!(Path.join(skill_dir, "references"))
    File.write!(Path.join(skill_dir, "references/style.md"), "short docs")

    skill = Manifest.load!(skill_dir)

    assert skill.name == "docs-helper"
    assert skill.description == "Helps with project docs"
    assert skill.body == "Use docs style."
    assert skill.resources.references == ["style.md"]
  end

  test "fails fast on missing decision-critical manifest fields", %{root: root} do
    skill_dir = Path.join(root, "broken")
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: broken\n---\nBody")

    assert_raise ArgumentError, ~r/description/, fn ->
      Manifest.load!(skill_dir)
    end
  end

  test "rejects symlinks inside skill directories", %{root: root} do
    skill_dir = write_skill!(root, "linked", "Linked skill", "Body")
    File.ln_s!("/tmp", Path.join(skill_dir, "references"))

    assert_raise ArgumentError, ~r/symlink/, fn ->
      Manifest.load!(skill_dir)
    end
  end

  test "rejects duplicate installed skill names", %{root: root} do
    skills_dir = Path.join(root, "skills")
    File.mkdir_p!(skills_dir)
    first = write_skill!(skills_dir, "same", "First", "Body")
    second = Path.join(skills_dir, "other")
    File.cp_r!(first, second)

    assert_raise ArgumentError, ~r/directory name.*must match/, fn ->
      Loader.load_installed!(skills_dir)
    end
  end

  test "installs from a local registry and writes a lockfile", %{root: root} do
    source = write_skill!(root, "docs-helper", "Helps with docs", "Body")
    registry = Path.join(root, "registry.json")
    skills_dir = Path.join(root, "installed")

    File.write!(
      registry,
      JSON.encode!(%{
        skills: [
          %{
            name: "docs-helper",
            description: "Helps with docs",
            source: %{type: "local", path: source}
          }
        ]
      })
    )

    skill =
      Installer.install_from_registry!("docs-helper", skills_dir: skills_dir, registry: registry)

    assert skill.name == "docs-helper"
    assert File.exists?(Path.join(skills_dir, "docs-helper/SKILL.md"))

    lock =
      skills_dir
      |> Path.join(".agent_machine_skills.lock.json")
      |> File.read!()
      |> JSON.decode!()

    assert %{"docs-helper" => %{"hash" => hash, "source" => %{"type" => "local"}}} = lock
    assert is_binary(hash)
  end

  test "creator creates a valid skill with requested resource dirs", %{root: root} do
    skills_dir = Path.join(root, "skills")

    skill =
      Creator.create!("research-helper",
        skills_dir: skills_dir,
        description: "Helps with research",
        resources: ["references", "assets"]
      )

    assert skill.name == "research-helper"
    assert File.dir?(Path.join(skills_dir, "research-helper/references"))
    assert File.dir?(Path.join(skills_dir, "research-helper/assets"))
  end

  test "auto selector chooses matching installed skills", %{root: root} do
    skills_dir = Path.join(root, "skills")
    write_skill!(skills_dir, "docs-helper", "Helps write README documentation", "Body")
    write_skill!(skills_dir, "sql-helper", "Helps with database queries", "Body")

    selection =
      Selector.select!(%AgentMachine.RunSpec{
        task: "Update the README documentation",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        skills_mode: :auto,
        skills_dir: skills_dir,
        skill_names: [],
        allow_skill_scripts: false
      })

    assert [%{skill: %{name: "docs-helper"}, reason: reason}] = selection.selected
    assert reason =~ "matched"
  end

  test "agentic echo run emits skill events and summary skills", %{root: root} do
    skills_dir = Path.join(root, "skills")
    write_skill!(skills_dir, "docs-helper", "Helps write README documentation", "Body")
    parent = self()

    summary =
      ClientRunner.run!(
        %{
          task: "Update README documentation",
          workflow: :agentic,
          provider: :echo,
          timeout_ms: 1_000,
          max_steps: 6,
          max_attempts: 1,
          skills_mode: :auto,
          skills_dir: skills_dir
        },
        event_sink: fn event -> send(parent, {:event, event.type, event}) end
      )

    assert [%{name: "docs-helper", reason: _reason}] = summary.skills
    assert_receive {:event, :skills_loaded, %{count: 1}}
    assert_receive {:event, :skills_selected, %{count: 1}}
  end

  test "skill resource tool reads only selected references and assets", %{root: root} do
    skill_dir = write_skill!(root, "docs-helper", "Helps with docs", "Body")
    File.mkdir_p!(Path.join(skill_dir, "references"))
    File.write!(Path.join(skill_dir, "references/style.md"), "Use short sections.")
    skill = Manifest.load!(skill_dir)

    assert {:ok, %{content: "Use short sections."}} =
             ReadSkillResource.run(
               %{"skill" => "docs-helper", "path" => "style.md", "max_bytes" => 100},
               selected_skills: [skill]
             )

    assert {:error, reason} =
             ReadSkillResource.run(
               %{"skill" => "docs-helper", "path" => "../SKILL.md", "max_bytes" => 100},
               selected_skills: [skill]
             )

    assert reason =~ "parent path"
  end

  test "skill scripts are unavailable unless explicitly enabled", %{root: root} do
    skill_dir = write_skill!(root, "script-helper", "Runs scripts", "Body")
    File.mkdir_p!(Path.join(skill_dir, "scripts"))
    script = Path.join(skill_dir, "scripts/hello")
    File.write!(script, "#!/bin/sh\necho hello\n")
    File.chmod!(script, 0o700)
    skill = Manifest.load!(skill_dir)

    assert {:error, reason} =
             RunSkillScript.run(
               %{"skill" => "script-helper", "path" => "hello", "args" => []},
               selected_skills: [skill]
             )

    assert reason =~ "not enabled"
  end

  test "mix agent_machine.skills supports JSON list and validate", %{root: root} do
    skills_dir = Path.join(root, "skills")
    skill_dir = write_skill!(skills_dir, "docs-helper", "Helps with docs", "Body")

    Mix.Task.reenable("agent_machine.skills")

    output =
      capture_io(fn ->
        SkillsTask.run(["list", "--skills-dir", skills_dir, "--json"])
      end)

    assert %{"skills" => [%{"name" => "docs-helper"}]} = JSON.decode!(String.trim(output))

    Mix.Task.reenable("agent_machine.skills")

    output =
      capture_io(fn ->
        SkillsTask.run(["validate", skill_dir, "--json"])
      end)

    assert %{"valid" => true, "skill" => %{"name" => "docs-helper"}} =
             JSON.decode!(String.trim(output))
  end

  test "registry rejects duplicate names", %{root: root} do
    registry = Path.join(root, "registry.json")

    File.write!(
      registry,
      JSON.encode!(%{
        skills: [
          %{name: "same", description: "One", source: %{type: "local", path: root}},
          %{name: "same", description: "Two", source: %{type: "local", path: root}}
        ]
      })
    )

    assert_raise ArgumentError, ~r/duplicate names/, fn ->
      Registry.load!(registry)
    end
  end

  defp write_skill!(parent, name, description, body) do
    skill_dir = Path.join(parent, name)
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---
    #{body}
    """)

    skill_dir
  end
end
