defmodule Mix.Tasks.AgentMachine.Skills do
  @moduledoc """
  Manages AgentMachine skills.
  """

  use Mix.Task

  alias AgentMachine.{
    JSON,
    Skills.ClawHub,
    Skills.Creator,
    Skills.Generator,
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
    provider: :string,
    provider_option: :keep,
    model: :string,
    input_price_per_million: :float,
    output_price_per_million: :float,
    resources: :string,
    source: :string,
    sort: :string,
    limit: :integer,
    version: :string,
    clawhub_registry: :string,
    http_timeout_ms: :integer,
    force: :boolean,
    all: :boolean,
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
          "usage: mix agent_machine.skills <list|search|show|validate|install|install-git|create|generate|remove|update>"
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
  defp dispatch!("generate", opts, positional), do: generate!(opts, positional)
  defp dispatch!("remove", opts, positional), do: remove!(opts, positional)
  defp dispatch!("update", opts, positional), do: update!(opts, positional)

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
    case Keyword.get(opts, :source) do
      "clawhub" ->
        ClawHub.search!(query,
          registry: clawhub_registry(opts),
          sort: Keyword.get(opts, :sort, "downloads"),
          limit: Keyword.get(opts, :limit, 20),
          http_timeout_ms: Keyword.get(opts, :http_timeout_ms, 30_000)
        )

      nil ->
        local_search!(opts, query)

      source ->
        Mix.raise("unknown skills source: #{inspect(source)}")
    end
  end

  defp search!(_opts, _positional),
    do:
      Mix.raise(
        "usage: mix agent_machine.skills search <query> [--source clawhub --sort downloads --limit 20]"
      )

  defp local_search!(opts, query) do
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

  defp show!(opts, [name]) do
    if String.starts_with?(name, "clawhub:") do
      name
      |> String.replace_prefix("clawhub:", "")
      |> ClawHub.show!(
        registry: clawhub_registry(opts),
        http_timeout_ms: Keyword.get(opts, :http_timeout_ms, 30_000)
      )
    else
      local_show!(opts, name)
    end
  end

  defp show!(_opts, _positional),
    do:
      Mix.raise("usage: mix agent_machine.skills show <name|clawhub:slug> [--skills-dir <path>]")

  defp local_show!(opts, name) do
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

  defp validate!(_opts, [path]) do
    skill = Manifest.load!(path)
    %{valid: true, skill: Manifest.catalog_entry(skill)}
  end

  defp validate!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills validate <path>")

  defp install!(opts, [name]) do
    skill =
      if String.starts_with?(name, "clawhub:") do
        Installer.install_clawhub!(name,
          skills_dir: skills_dir!(opts),
          version: Keyword.get(opts, :version, "latest"),
          clawhub_registry: clawhub_registry(opts),
          http_timeout_ms: Keyword.get(opts, :http_timeout_ms, 30_000),
          force: Keyword.get(opts, :force, false)
        )
      else
        Installer.install_from_registry!(name,
          skills_dir: skills_dir!(opts),
          registry: Keyword.get(opts, :registry, Registry.default_path()),
          force: Keyword.get(opts, :force, false)
        )
      end

    %{installed: Manifest.catalog_entry(skill)}
  end

  defp install!(_opts, _positional),
    do:
      Mix.raise("usage: mix agent_machine.skills install <name|clawhub:slug> --skills-dir <path>")

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

  defp generate!(opts, [name]) do
    skill =
      Generator.generate!(name,
        skills_dir: skills_dir!(opts),
        description: fetch_required_option!(opts, :description),
        provider: provider_from_opts!(opts),
        provider_options: provider_options_from_opts!(opts),
        model: fetch_required_option!(opts, :model),
        http_timeout_ms: fetch_required_value!(opts, :http_timeout_ms),
        pricing: pricing_from_opts!(opts)
      )

    %{created: Manifest.catalog_entry(skill)}
  end

  defp generate!(_opts, _positional) do
    Mix.raise(
      "usage: mix agent_machine.skills generate <name> --description <text> --skills-dir <path> --provider <echo|openai|openrouter> --model <id> --http-timeout-ms <ms> --input-price-per-million <n> --output-price-per-million <n>"
    )
  end

  defp remove!(opts, [name]) do
    Installer.remove!(name, skills_dir: skills_dir!(opts))
  end

  defp remove!(_opts, _positional),
    do: Mix.raise("usage: mix agent_machine.skills remove <name> --skills-dir <path>")

  defp update!(opts, []) do
    if Keyword.get(opts, :all, false) do
      Installer.update_clawhub!("--all", update_opts(opts))
    else
      Mix.raise("usage: mix agent_machine.skills update clawhub:<slug>|--all --skills-dir <path>")
    end
  end

  defp update!(opts, [target]) do
    target =
      if target == "--all" do
        target
      else
        ensure_clawhub_target!(target)
      end

    Installer.update_clawhub!(target, update_opts(opts))
  end

  defp update!(_opts, _positional),
    do:
      Mix.raise("usage: mix agent_machine.skills update clawhub:<slug>|--all --skills-dir <path>")

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

  defp clawhub_registry(opts) do
    Keyword.get(opts, :clawhub_registry) || System.get_env("AGENT_MACHINE_CLAWHUB_REGISTRY")
  end

  defp update_opts(opts) do
    [
      skills_dir: skills_dir!(opts),
      version: Keyword.get(opts, :version, "latest"),
      clawhub_registry: clawhub_registry(opts),
      http_timeout_ms: Keyword.get(opts, :http_timeout_ms, 30_000),
      force: Keyword.get(opts, :force, false)
    ]
  end

  defp ensure_clawhub_target!("clawhub:" <> _rest = target), do: target
  defp ensure_clawhub_target!(target), do: "clawhub:" <> target

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

  defp fetch_required_value!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Mix.raise("missing required --#{option_name(key)} option")
    end
  end

  defp provider_from_opts!(opts) do
    case fetch_required_option!(opts, :provider) do
      "echo" ->
        :echo

      provider ->
        AgentMachine.ProviderCatalog.fetch!(provider)
        provider
    end
  end

  defp provider_options_from_opts!(opts) do
    opts
    |> Keyword.get_values(:provider_option)
    |> Map.new(&provider_option_pair!/1)
  end

  defp provider_option_pair!(value) when is_binary(value) do
    case String.split(value, "=", parts: 2) do
      [key, option_value] when key != "" and option_value != "" ->
        {key, option_value}

      _other ->
        Mix.raise(
          "--provider-option must be key=value with non-empty key and value, got: #{inspect(value)}"
        )
    end
  end

  defp pricing_from_opts!(opts) do
    case {Keyword.fetch(opts, :input_price_per_million),
          Keyword.fetch(opts, :output_price_per_million)} do
      {{:ok, input}, {:ok, output}} ->
        %{input_per_million: input, output_per_million: output}

      {:error, :error} ->
        Mix.raise(
          "missing required --input-price-per-million and --output-price-per-million options"
        )

      _other ->
        Mix.raise(
          "--input-price-per-million and --output-price-per-million must be provided together"
        )
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

  defp format_text(%{updated: skills}),
    do: "updated skills: #{Enum.map_join(skills, ", ", & &1.name)}"

  defp format_text(%{created: skill}), do: "created skill: #{skill.name}"
  defp format_text(%{removed: name}), do: "removed skill: #{name}"

  defp format_text(%{slug: slug, name: name, description: description, latest_version: version}) do
    resolved_version = Map.get(version, "version", "")

    [
      "#{name} (#{slug})",
      description,
      if(resolved_version == "", do: nil, else: "latest: #{resolved_version}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp format_text(skill) when is_map(skill) and is_map_key(skill, :name) do
    [skill.name, skill.description, "", skill.instructions || ""]
    |> Enum.join("\n")
    |> String.trim()
  end
end
