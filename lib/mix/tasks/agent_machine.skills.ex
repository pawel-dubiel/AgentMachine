defmodule Mix.Tasks.AgentMachine.Skills do
  @moduledoc """
  Manages AgentMachine skills.
  """

  use Mix.Task

  alias AgentMachine.{
    JSON,
    Skills.Creator,
    Skills.Installer,
    Skills.Loader,
    Skills.Manifest,
    Skills.Registry
  }

  @shortdoc "Lists, installs, creates, validates, and removes AgentMachine skills"

  @switches [
    skills_dir: :string,
    registry: :string,
    repo: :string,
    ref: :string,
    path: :string,
    description: :string,
    resources: :string,
    force: :boolean,
    json: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [command | rest] ->
        run_command(command, rest)

      [] ->
        Mix.raise(
          "usage: mix agent_machine.skills <list|search|show|validate|install|install-git|create|remove>"
        )
    end
  end

  defp run_command(command, args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    result = dispatch!(command, opts, positional)

    print_result(result, Keyword.get(opts, :json, false))
  end

  defp dispatch!("list", opts, positional), do: list!(opts, positional)
  defp dispatch!("search", opts, positional), do: search!(opts, positional)
  defp dispatch!("show", opts, positional), do: show!(opts, positional)
  defp dispatch!("validate", opts, positional), do: validate!(opts, positional)
  defp dispatch!("install", opts, positional), do: install!(opts, positional)
  defp dispatch!("install-git", opts, positional), do: install_git!(opts, positional)
  defp dispatch!("create", opts, positional), do: create!(opts, positional)
  defp dispatch!("remove", opts, positional), do: remove!(opts, positional)

  defp dispatch!(command, _opts, _positional),
    do: Mix.raise("unknown skills command: #{inspect(command)}")

  defp list!(opts, []) do
    skills =
      opts
      |> skills_dir!()
      |> Loader.load_installed!()
      |> Enum.map(&Manifest.catalog_entry/1)

    %{skills: skills}
  end

  defp list!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills list --skills-dir <path>")

  defp search!(opts, [query]) do
    query = String.downcase(require_non_empty_binary!(query, "query"))

    installed =
      opts |> skills_dir!() |> Loader.load_installed!() |> Enum.map(&Manifest.catalog_entry/1)

    registry = registry_entries(opts)

    matches =
      (installed ++ registry)
      |> Enum.filter(fn skill ->
        text = String.downcase(skill.name <> " " <> skill.description)
        String.contains?(text, query)
      end)
      |> Enum.uniq_by(& &1.name)
      |> Enum.sort_by(& &1.name)

    %{skills: matches}
  end

  defp search!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills search <query> --skills-dir <path>")

  defp show!(opts, [name]) do
    skill =
      opts
      |> skills_dir!()
      |> Loader.load_named!([name])
      |> List.first()

    %{
      name: skill.name,
      description: skill.description,
      root: skill.root,
      metadata: skill.metadata,
      resources: skill.resources,
      instructions: skill.body
    }
  end

  defp show!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills show <name> --skills-dir <path>")

  defp validate!(_opts, [path]) do
    skill = Manifest.load!(path)
    %{valid: true, skill: Manifest.catalog_entry(skill)}
  end

  defp validate!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills validate <path>")

  defp install!(opts, [name]) do
    skill =
      Installer.install_from_registry!(name,
        skills_dir: skills_dir!(opts),
        registry: Keyword.get(opts, :registry, Registry.default_path()),
        force: Keyword.get(opts, :force, false)
      )

    %{installed: Manifest.catalog_entry(skill)}
  end

  defp install!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills install <name> --skills-dir <path>")

  defp install_git!(opts, []) do
    skill =
      Installer.install_git!(
        fetch_required_option!(opts, :repo),
        fetch_required_option!(opts, :ref),
        fetch_required_option!(opts, :path),
        skills_dir: skills_dir!(opts),
        force: Keyword.get(opts, :force, false)
      )

    %{installed: Manifest.catalog_entry(skill)}
  end

  defp install_git!(_opts, _positional) do
    Mix.raise(
      "usage: mix agent_machine.skills install-git --repo <url> --ref <ref> --path <skill-path> --skills-dir <path>"
    )
  end

  defp create!(opts, [name]) do
    skill =
      Creator.create!(name,
        skills_dir: skills_dir!(opts),
        description: fetch_required_option!(opts, :description),
        resources: resources_from_opts(opts),
        force: Keyword.get(opts, :force, false)
      )

    %{created: Manifest.catalog_entry(skill)}
  end

  defp create!(_opts, _positional) do
    Mix.raise(
      "usage: mix agent_machine.skills create <name> --description <text> --skills-dir <path>"
    )
  end

  defp remove!(opts, [name]) do
    Installer.remove!(name, skills_dir: skills_dir!(opts))
  end

  defp remove!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills remove <name> --skills-dir <path>")

  defp registry_entries(opts) do
    registry = Keyword.get(opts, :registry, Registry.default_path())

    registry
    |> Registry.load!()
    |> Enum.map(fn entry ->
      %{name: entry.name, description: entry.description, source: inspect(entry.source)}
    end)
  end

  defp skills_dir!(opts) do
    case Keyword.fetch(opts, :skills_dir) do
      {:ok, path} ->
        path

      :error ->
        System.get_env("AGENT_MACHINE_SKILLS_DIR") ||
          Mix.raise("missing required --skills-dir option")
    end
  end

  defp resources_from_opts(opts) do
    case Keyword.get(opts, :resources, "") do
      "" -> []
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp fetch_required_option!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      {:ok, value} -> Mix.raise("--#{option_name(key)} must be non-empty, got: #{inspect(value)}")
      :error -> Mix.raise("missing required --#{option_name(key)} option")
    end
  end

  defp option_name(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    Mix.raise("#{label} must be non-empty, got: #{inspect(value)}")
  end

  defp print_result(result, true), do: Mix.shell().info(JSON.encode!(result))

  defp print_result(result, false) do
    Mix.shell().info(format_text(result))
  end

  defp format_text(%{skills: skills}) do
    case skills do
      [] ->
        "skills: none"

      skills ->
        Enum.map_join(skills, "\n", fn skill -> "#{skill.name}: #{skill.description}" end)
    end
  end

  defp format_text(%{valid: true, skill: skill}), do: "valid skill: #{skill.name}"
  defp format_text(%{installed: skill}), do: "installed skill: #{skill.name}"
  defp format_text(%{created: skill}), do: "created skill: #{skill.name}"
  defp format_text(%{removed: name}), do: "removed skill: #{name}"

  defp format_text(skill) when is_map(skill) and is_map_key(skill, :name) do
    [skill.name, skill.description, "", skill.instructions || ""]
    |> Enum.join("\n")
    |> String.trim()
  end
end
