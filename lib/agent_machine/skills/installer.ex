defmodule AgentMachine.Skills.Installer do
  @moduledoc false

  alias AgentMachine.{JSON, Skills.Registry}
  alias AgentMachine.Skills.{Loader, Manifest}

  @lockfile ".agent_machine_skills.lock.json"

  def install_from_registry!(name, opts) when is_list(opts) do
    registry = Keyword.get(opts, :registry, Registry.default_path())
    entry = Registry.find!(name, registry)
    install_entry!(entry, opts)
  end

  def install_git!(repo, ref, path, opts) when is_list(opts) do
    repo = require_non_empty_binary!(repo, "git repo")
    ref = require_non_empty_binary!(ref, "git ref")
    path = Manifest.safe_relative_path!(path, "git path")
    tmp = clone_git!(repo, ref)
    source_path = Path.join(tmp, path)
    skill = Manifest.load!(source_path)

    entry = %{
      name: skill.name,
      description: skill.description,
      source: %{
        type: :git,
        repo: repo,
        ref: ref,
        path: path
      }
    }

    try do
      do_install!(entry, source_path, opts)
    after
      File.rm_rf(tmp)
    end
  end

  def install_entry!(%{name: name, source: source} = entry, opts) when is_list(opts) do
    entry = %{entry | name: name, source: source}

    case source do
      %{type: :local, path: path} ->
        do_install!(entry, path, opts)

      %{type: :git, repo: repo, ref: ref, path: path} ->
        tmp = clone_git!(repo, ref)

        try do
          do_install!(entry, Path.join(tmp, path), opts)
        after
          File.rm_rf(tmp)
        end
    end
  end

  defp do_install!(%{name: name} = entry, source_path, opts) do
    skills_dir = ensure_skills_dir!(Keyword.fetch!(opts, :skills_dir))
    force? = Keyword.get(opts, :force, false)
    name = Manifest.validate_name!(name)
    dest = Path.join(skills_dir, name)
    stage_parent = Path.join(skills_dir, ".install-#{name}-#{System.unique_integer([:positive])}")
    stage = Path.join(stage_parent, name)

    if File.exists?(dest) and not force? do
      raise ArgumentError, "skill already installed: #{inspect(name)}"
    end

    File.rm_rf!(stage_parent)

    try do
      copy_skill!(source_path, stage)

      skill = Manifest.load!(stage)

      if skill.name != name do
        raise ArgumentError,
              "installed skill name #{inspect(skill.name)} does not match registry name #{inspect(name)}"
      end

      if force? do
        File.rm_rf!(dest)
      end

      File.rename!(stage, dest)
      skill = Manifest.load!(dest)
      write_lock!(skills_dir, skill, entry)
      skill
    after
      File.rm_rf(stage_parent)
    end
  end

  def remove!(name, opts) when is_list(opts) do
    skills_dir = Loader.require_existing_directory!(Keyword.fetch!(opts, :skills_dir))
    name = Manifest.validate_name!(name)
    target = Path.join(skills_dir, name)

    unless File.dir?(target) do
      raise ArgumentError, "skill is not installed: #{inspect(name)}"
    end

    File.rm_rf!(target)
    remove_lock!(skills_dir, name)
    %{removed: name}
  end

  defp clone_git!(repo, ref) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-skill-git-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)

    case System.cmd("git", ["clone", "--depth", "1", "--branch", ref, repo, tmp],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> tmp
      {output, status} -> raise ArgumentError, "git clone failed with status #{status}: #{output}"
    end
  end

  defp copy_skill!(source, stage) do
    Manifest.load!(source)
    File.mkdir_p!(Path.dirname(stage))
    File.cp_r!(source, stage)
  end

  defp ensure_skills_dir!(skills_dir) do
    skills_dir = require_non_empty_binary!(skills_dir, "skills dir") |> Path.expand()
    File.mkdir_p!(skills_dir)
    skills_dir
  end

  defp write_lock!(skills_dir, skill, entry) do
    lock_path = Path.join(skills_dir, @lockfile)
    lock = read_lock(lock_path)

    lock =
      Map.put(lock, skill.name, %{
        name: skill.name,
        source: lock_source(entry.source),
        installed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        hash: skill_hash(skill.root)
      })

    File.write!(lock_path, JSON.encode!(lock) <> "\n")
  end

  defp remove_lock!(skills_dir, name) do
    lock_path = Path.join(skills_dir, @lockfile)
    lock = lock_path |> read_lock() |> Map.delete(name)
    File.write!(lock_path, JSON.encode!(lock) <> "\n")
  end

  defp read_lock(path) do
    case File.read(path) do
      {:ok, body} -> JSON.decode!(body)
      {:error, :enoent} -> %{}
      {:error, reason} -> raise ArgumentError, "failed to read skill lockfile: #{inspect(reason)}"
    end
  end

  defp lock_source(%{type: :local, path: path}), do: %{type: "local", path: path}

  defp lock_source(%{type: :git, repo: repo, ref: ref, path: path}) do
    %{type: "git", repo: repo, ref: ref, path: path}
  end

  defp skill_hash(root) do
    root
    |> files_for_hash()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, ctx ->
      rel = Path.relative_to(path, root)
      ctx = :crypto.hash_update(ctx, rel)
      :crypto.hash_update(ctx, File.read!(path))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp files_for_hash(root) do
    root
    |> collect_files([])
    |> Enum.sort()
  end

  defp collect_files(path, acc) do
    case File.stat!(path) do
      %{type: :directory} ->
        path
        |> File.ls!()
        |> Enum.reduce(acc, &collect_files(Path.join(path, &1), &2))

      %{type: :regular} ->
        [path | acc]

      _stat ->
        acc
    end
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end
end
