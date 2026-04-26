defmodule AgentMachine.Skills.ClawHub do
  @moduledoc false

  alias AgentMachine.{JSON, Skills.Manifest}

  @default_registry "https://clawhub.ai"
  @max_download_bytes 20 * 1024 * 1024
  @default_timeout_ms 30_000

  def default_registry do
    System.get_env("AGENT_MACHINE_CLAWHUB_REGISTRY") || @default_registry
  end

  def search!(query, opts \\ []) when is_list(opts) do
    query = require_non_empty_binary!(query, "query")
    limit = positive_integer!(Keyword.get(opts, :limit, 20), "limit")
    sort = require_non_empty_binary!(Keyword.get(opts, :sort, "downloads"), "sort")

    response =
      if String.trim(query) == "*" do
        get_json!("/api/v1/skills", opts, %{
          "limit" => Integer.to_string(limit),
          "sort" => sort,
          "nonSuspiciousOnly" => "true"
        })
      else
        get_json!("/api/v1/search", opts, %{
          "q" => query,
          "limit" => Integer.to_string(limit),
          "nonSuspiciousOnly" => "true"
        })
      end

    %{skills: normalize_search_results!(response), source: "clawhub", registry: registry(opts)}
  end

  def show!(target, opts \\ []) when is_list(opts) do
    slug = normalize_slug!(target)

    response =
      "/api/v1/skills/#{URI.encode(slug, &URI.char_unreserved?/1)}"
      |> get_json!(opts, %{})

    normalize_skill_detail!(response, slug, opts)
  end

  def download!(target, version, opts \\ []) when is_list(opts) do
    slug = normalize_slug!(target)
    version = require_non_empty_binary!(version || "latest", "version")

    metadata = show!(slug, opts)
    resolved_version = resolve_version!(metadata, version)

    body =
      get_binary!("/api/v1/download", opts, %{
        "slug" => slug,
        version_query_key(version) => resolved_version
      })

    hash = sha256(body)

    %{
      slug: slug,
      version: resolved_version,
      requested_version: version,
      registry: registry(opts),
      hash: hash,
      bytes: byte_size(body),
      metadata: metadata,
      zip: body
    }
  end

  def extract_skill_zip!(zip, opts \\ []) when is_binary(zip) and is_list(opts) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-clawhub-#{System.unique_integer([:positive])}"
      )

    zip_path = Path.join(tmp, "bundle.zip")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    File.write!(zip_path, zip)

    try do
      validate_zip_entries!(zip_path)

      case :zip.extract(String.to_charlist(zip_path), cwd: String.to_charlist(tmp)) do
        {:ok, _files} ->
          source = find_skill_root!(tmp)
          Manifest.load!(source)
          source

        {:error, reason} ->
          raise ArgumentError, "failed to extract ClawHub bundle: #{inspect(reason)}"
      end
    rescue
      error ->
        File.rm_rf(tmp)
        reraise error, __STACKTRACE__
    end
  end

  def cleanup_extracted!(path) when is_binary(path) do
    path = Path.expand(path)
    tmp = Path.expand(System.tmp_dir!())

    path
    |> clawhub_tmp_root()
    |> case do
      nil -> :ok
      root -> cleanup_tmp_root(root, tmp)
    end

    :ok
  end

  defp cleanup_tmp_root(root, tmp) do
    if String.starts_with?(root, tmp <> "/") do
      File.rm_rf(root)
    else
      :ok
    end
  end

  defp clawhub_tmp_root(path) do
    parts = Path.split(path)

    case Enum.find_index(parts, &String.starts_with?(&1, "agent-machine-clawhub-")) do
      nil -> nil
      index -> parts |> Enum.take(index + 1) |> Path.join()
    end
  end

  def normalize_slug!(target) do
    target =
      target
      |> require_non_empty_binary!("clawhub slug")
      |> String.trim()
      |> String.replace_prefix("clawhub:", "")

    target =
      case URI.parse(target) do
        %URI{scheme: scheme, path: path} when scheme in ["http", "https"] and is_binary(path) ->
          path
          |> String.split("/", trim: true)
          |> List.last()

        _uri ->
          target
      end

    parts = String.split(target || "", "/", trim: true)

    slug =
      case parts do
        [single] -> single
        [_owner, skill] -> skill
        _other -> raise ArgumentError, "ambiguous ClawHub slug: #{inspect(target)}"
      end

    unless Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/, slug) do
      raise ArgumentError, "invalid ClawHub slug: #{inspect(slug)}"
    end

    slug
  end

  defp normalize_search_results!(%{"results" => results}) when is_list(results) do
    Enum.map(results, &normalize_search_item!/1)
  end

  defp normalize_search_results!(%{"items" => items}) when is_list(items) do
    Enum.map(items, &normalize_search_item!/1)
  end

  defp normalize_search_results!(items) when is_list(items) do
    Enum.map(items, &normalize_search_item!/1)
  end

  defp normalize_search_results!(other) do
    raise ArgumentError, "invalid ClawHub search response: #{inspect(other)}"
  end

  defp normalize_search_item!(item) when is_map(item) do
    slug = fetch_string!(item, ["slug"], "skill slug")

    %{
      slug: slug,
      name: first_string(item, ["displayName", "name"]) || slug,
      description: first_string(item, ["summary", "description"]) || "",
      version: version_from_item(item),
      downloads:
        number_from_path(item, ["stats", "downloads"]) || first_number(item, ["downloads"]),
      stars: number_from_path(item, ["stats", "stars"]) || first_number(item, ["stars"]),
      updated_at: first_number(item, ["updatedAt"]),
      score: first_number(item, ["score"])
    }
  end

  defp normalize_search_item!(other) do
    raise ArgumentError, "invalid ClawHub skill entry: #{inspect(other)}"
  end

  defp normalize_skill_detail!(%{"skill" => skill} = response, slug, opts) when is_map(skill) do
    moderation = Map.get(response, "moderationInfo") || Map.get(response, "moderation") || %{}
    reject_unsafe_metadata!(moderation, slug)

    latest = Map.get(response, "latestVersion") || %{}

    %{
      slug: fetch_string!(skill, ["slug"], "skill slug"),
      name: first_string(skill, ["displayName", "name"]) || slug,
      description: first_string(skill, ["summary", "description"]) || "",
      tags: map_or_empty(Map.get(skill, "tags")),
      stats: map_or_empty(Map.get(skill, "stats")),
      owner: map_or_empty(Map.get(response, "owner")),
      latest_version: normalize_version(latest),
      versions: fetch_versions!(slug, opts),
      moderation: map_or_empty(moderation),
      registry: registry(opts)
    }
  end

  defp normalize_skill_detail!(item, slug, opts) when is_map(item) do
    reject_unsafe_metadata!(item, slug)

    latest =
      Map.get(item, "latestVersion") ||
        %{"version" => first_string(item, ["version", "latestVersion"])}

    %{
      slug: fetch_string!(item, ["slug"], "skill slug"),
      name: first_string(item, ["displayName", "name"]) || slug,
      description: first_string(item, ["summary", "description"]) || "",
      tags: map_or_empty(Map.get(item, "tags")),
      stats: map_or_empty(Map.get(item, "stats")),
      owner: map_or_empty(Map.get(item, "owner")),
      latest_version: normalize_version(latest),
      versions: fetch_versions!(slug, opts),
      moderation: %{},
      registry: registry(opts)
    }
  end

  defp normalize_skill_detail!(other, _slug, _opts) do
    raise ArgumentError, "invalid ClawHub show response: #{inspect(other)}"
  end

  defp fetch_versions!(slug, opts) do
    response =
      "/api/v1/skills/#{URI.encode(slug, &URI.char_unreserved?/1)}/versions"
      |> get_json!(opts, %{"limit" => "200"})

    items =
      cond do
        is_map(response) and is_list(response["items"]) -> response["items"]
        is_list(response) -> response
        true -> raise ArgumentError, "invalid ClawHub versions response: #{inspect(response)}"
      end

    Enum.map(items, &normalize_version/1)
  end

  defp normalize_version(nil), do: %{}
  defp normalize_version(%{} = version), do: version

  defp normalize_version(other) do
    raise ArgumentError, "invalid ClawHub version response: #{inspect(other)}"
  end

  defp resolve_version!(metadata, "latest") do
    version =
      get_in(metadata, [:latest_version, "version"]) ||
        get_in(metadata, [:tags, "latest"]) ||
        latest_version_from_versions(metadata.versions)

    require_non_empty_binary!(version, "resolved latest version")
  end

  defp resolve_version!(metadata, version) do
    versions = Enum.map(metadata.versions, &Map.get(&1, "version"))

    if versions != [] and version not in versions do
      raise ArgumentError, "ClawHub skill #{metadata.slug} has no version #{inspect(version)}"
    end

    version
  end

  defp latest_version_from_versions(versions) do
    versions
    |> Enum.map(&Map.get(&1, "version"))
    |> Enum.find(&(is_binary(&1) and byte_size(&1) > 0))
  end

  defp version_query_key("latest"), do: "version"
  defp version_query_key(_version), do: "version"

  defp get_json!(path, opts, query) do
    body = get_binary!(path, opts, query)

    try do
      JSON.decode!(body)
    rescue
      error in ArgumentError ->
        reraise ArgumentError,
                [
                  message:
                    "invalid ClawHub JSON response for #{path}: #{Exception.message(error)}"
                ],
                __STACKTRACE__
    end
  end

  defp get_binary!(path, opts, query) do
    ensure_http_started!()

    url = build_url(registry(opts), path, query)
    timeout = Keyword.get(opts, :http_timeout_ms, @default_timeout_ms)
    max_bytes = Keyword.get(opts, :max_download_bytes, @max_download_bytes)

    request = {String.to_charlist(url), []}
    http_opts = [timeout: timeout, connect_timeout: timeout]
    opts = [body_format: :binary]

    case :httpc.request(:get, request, http_opts, opts) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        if byte_size(body) > max_bytes do
          raise ArgumentError, "ClawHub response exceeded #{max_bytes} bytes"
        end

        body

      {:ok, {{_version, status, reason}, _headers, body}} ->
        message = body |> to_string() |> String.slice(0, 500)
        raise ArgumentError, "ClawHub #{path} failed (#{status} #{reason}): #{message}"

      {:error, reason} ->
        raise ArgumentError, "ClawHub request failed for #{path}: #{inspect(reason)}"
    end
  end

  defp build_url(base, path, query) do
    base = String.trim_trailing(require_non_empty_binary!(base, "ClawHub registry"), "/")
    encoded = URI.encode_query(query)

    if encoded == "" do
      base <> path
    else
      base <> path <> "?" <> encoded
    end
  end

  defp registry(opts) do
    Keyword.get(opts, :registry) || default_registry()
  end

  defp ensure_http_started! do
    ensure_application_started!(:inets)
    ensure_application_started!(:ssl)
  end

  defp ensure_application_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, {^app, {:already_started, ^app}}} -> :ok
      {:error, reason} -> raise ArgumentError, "failed to start #{app}: #{inspect(reason)}"
    end
  end

  defp validate_zip_entries!(zip_path) do
    case :zip.list_dir(String.to_charlist(zip_path)) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&zip_comment?/1)
        |> Enum.each(&validate_zip_entry!/1)

      {:error, reason} ->
        raise ArgumentError, "invalid ClawHub zip bundle: #{inspect(reason)}"
    end
  end

  defp zip_comment?({:zip_comment, _comment}), do: true
  defp zip_comment?(_entry), do: false

  defp validate_zip_entry!({:zip_file, path, _info, _comment, _offset, _size}) do
    validate_zip_path!(List.to_string(path))
  end

  defp validate_zip_entry!({:zip_file, path, _info, _comment, _offset}) do
    validate_zip_path!(List.to_string(path))
  end

  defp validate_zip_entry!({:zip_file, path, _info}) do
    validate_zip_path!(List.to_string(path))
  end

  defp validate_zip_entry!(other) do
    raise ArgumentError, "invalid ClawHub zip entry: #{inspect(other)}"
  end

  defp validate_zip_path!(path) do
    cond do
      path == "" ->
        raise ArgumentError, "ClawHub zip entry path is empty"

      String.starts_with?(path, "/") ->
        raise ArgumentError, "ClawHub zip entry uses an absolute path: #{inspect(path)}"

      String.contains?(path, <<0>>) ->
        raise ArgumentError, "ClawHub zip entry contains a null byte: #{inspect(path)}"

      ".." in Path.split(path) ->
        raise ArgumentError, "ClawHub zip entry escapes parent directory: #{inspect(path)}"

      true ->
        :ok
    end
  end

  defp find_skill_root!(tmp) do
    direct = Path.join(tmp, "SKILL.md")

    if File.regular?(direct) do
      tmp
    else
      candidates =
        tmp
        |> File.ls!()
        |> Enum.map(&Path.join(tmp, &1))
        |> Enum.filter(fn path ->
          File.dir?(path) and File.regular?(Path.join(path, "SKILL.md"))
        end)

      case candidates do
        [path] -> path
        [] -> raise ArgumentError, "ClawHub bundle does not contain SKILL.md"
        _many -> raise ArgumentError, "ClawHub bundle contains multiple skill roots"
      end
    end
  end

  defp reject_unsafe_metadata!(metadata, slug) when is_map(metadata) do
    metadata
    |> unsafe_flag_messages()
    |> Enum.each(fn message -> raise ArgumentError, "ClawHub skill #{slug} #{message}" end)

    reject_unsafe_verdict!(metadata, slug)
  end

  defp reject_unsafe_metadata!(_metadata, _slug), do: :ok

  defp unsafe_flag_messages(metadata) do
    [
      {truthy?(Map.get(metadata, "isHidden")) or truthy?(Map.get(metadata, "hidden")),
       "is hidden"},
      {truthy?(Map.get(metadata, "isRemoved")) or truthy?(Map.get(metadata, "deleted")),
       "is deleted or removed"},
      {truthy?(Map.get(metadata, "isMalwareBlocked")), "is blocked as malware"},
      {truthy?(Map.get(metadata, "isSuspicious")), "is flagged as suspicious"}
    ]
    |> Enum.filter(fn {unsafe?, _message} -> unsafe? end)
    |> Enum.map(fn {_unsafe?, message} -> message end)
  end

  defp reject_unsafe_verdict!(metadata, slug) do
    case Map.get(metadata, "verdict") || Map.get(metadata, "moderationVerdict") do
      "malicious" -> raise ArgumentError, "ClawHub skill #{slug} is blocked as malware"
      "suspicious" -> raise ArgumentError, "ClawHub skill #{slug} is flagged as suspicious"
      _other -> :ok
    end
  end

  defp fetch_string!(map, keys, label) do
    case first_string(map, keys) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _other -> raise ArgumentError, "missing ClawHub #{label}"
    end
  end

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and byte_size(value) > 0 -> value
        _other -> nil
      end
    end)
  end

  defp first_number(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) or is_float(value) -> value
        _other -> nil
      end
    end)
  end

  defp number_from_path(map, [first, second]) do
    case map do
      %{^first => nested} when is_map(nested) -> first_number(nested, [second])
      _other -> nil
    end
  end

  defp version_from_item(%{"latestVersion" => %{"version" => version}}) when is_binary(version),
    do: version

  defp version_from_item(item), do: first_string(item, ["version", "latestVersion"])

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp sha256(binary) do
    :sha256
    |> :crypto.hash(binary)
    |> Base.encode16(case: :lower)
  end

  defp positive_integer!(value, _label) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, label) do
    raise ArgumentError, "#{label} must be a positive integer, got: #{inspect(value)}"
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end
end
