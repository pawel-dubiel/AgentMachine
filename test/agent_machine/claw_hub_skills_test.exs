defmodule AgentMachine.ClawHubSkillsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias AgentMachine.{JSON, Skills.ClawHub, Skills.Installer}
  alias Mix.Tasks.AgentMachine.Skills, as: SkillsTask

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-clawhub-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "search normalizes ClawHub API results", %{root: root} do
    server =
      start_http_server!(1, fn target ->
        uri = URI.parse(target)
        query = URI.decode_query(uri.query || "")
        assert uri.path == "/api/v1/search"
        assert query["q"] == "docs"
        assert query["limit"] == "2"

        json_response(%{
          results: [
            %{
              slug: "docs-helper",
              displayName: "Docs Helper",
              summary: "Helps with docs",
              version: "1.0.0",
              score: 0.9
            }
          ]
        })
      end)

    assert %{skills: [%{slug: "docs-helper", name: "Docs Helper", score: 0.9}]} =
             ClawHub.search!("docs", registry: server.url, limit: 2)

    File.write!(Path.join(root, "ok"), "done")
  end

  test "show rejects suspicious ClawHub metadata" do
    server =
      start_http_server!(1, fn target ->
        uri = URI.parse(target)

        case uri.path do
          "/api/v1/skills/risky" ->
            json_response(%{
              skill: %{slug: "risky", displayName: "Risky", summary: "Bad"},
              latestVersion: %{version: "1.0.0"},
              moderationInfo: %{isSuspicious: true}
            })
        end
      end)

    assert_raise ArgumentError, ~r/suspicious/, fn ->
      ClawHub.show!("risky", registry: server.url)
    end
  end

  test "install downloads zip, validates manifest, and records ClawHub lock provenance", %{
    root: root
  } do
    skills_dir = Path.join(root, "skills")
    zip = skill_zip!(root, "docs-helper", "Helps with docs")

    server =
      start_http_server!(3, fn target ->
        uri = URI.parse(target)

        case uri.path do
          "/api/v1/skills/docs-helper" ->
            json_response(%{
              skill: %{slug: "docs-helper", displayName: "Docs Helper", summary: "Helps"},
              latestVersion: %{version: "1.2.3"},
              owner: %{handle: "agent-machine"}
            })

          "/api/v1/skills/docs-helper/versions" ->
            json_response(%{items: [%{version: "1.2.3", files: []}], nextCursor: nil})

          "/api/v1/download" ->
            query = URI.decode_query(uri.query || "")
            assert query["slug"] == "docs-helper"
            assert query["version"] == "1.2.3"
            zip_response(zip)
        end
      end)

    skill =
      Installer.install_clawhub!("clawhub:docs-helper",
        skills_dir: skills_dir,
        clawhub_registry: server.url,
        version: "latest"
      )

    assert skill.name == "docs-helper"

    lock =
      skills_dir
      |> Path.join(".agent_machine_skills.lock.json")
      |> File.read!()
      |> JSON.decode!()

    assert %{
             "docs-helper" => %{
               "source" => %{
                 "type" => "clawhub",
                 "slug" => "docs-helper",
                 "version" => "1.2.3",
                 "registry" => registry,
                 "bundle_hash" => hash,
                 "metadata" => %{"owner" => %{"handle" => "agent-machine"}}
               }
             }
           } = lock

    assert registry == server.url
    assert is_binary(hash)
  end

  test "zip extraction rejects parent traversal entries", %{root: root} do
    zip = unsafe_zip!(root)

    assert_raise ArgumentError, ~r/escapes parent/, fn ->
      ClawHub.extract_skill_zip!(zip)
    end
  end

  test "mix task supports ClawHub search and install", %{root: root} do
    skills_dir = Path.join(root, "skills")
    zip = skill_zip!(root, "docs-helper", "Helps with docs")

    server =
      start_http_server!(4, fn target ->
        uri = URI.parse(target)

        case uri.path do
          "/api/v1/search" ->
            json_response(%{results: [%{slug: "docs-helper", displayName: "Docs Helper"}]})

          "/api/v1/skills/docs-helper" ->
            json_response(%{
              skill: %{slug: "docs-helper", displayName: "Docs Helper", summary: "Helps"},
              latestVersion: %{version: "1.0.0"}
            })

          "/api/v1/skills/docs-helper/versions" ->
            json_response(%{items: [%{version: "1.0.0", files: []}], nextCursor: nil})

          "/api/v1/download" ->
            zip_response(zip)
        end
      end)

    Mix.Task.reenable("agent_machine.skills")

    search_output =
      capture_io(fn ->
        SkillsTask.run([
          "search",
          "docs",
          "--source",
          "clawhub",
          "--clawhub-registry",
          server.url,
          "--json"
        ])
      end)

    assert %{"skills" => [%{"slug" => "docs-helper"}]} = JSON.decode!(String.trim(search_output))

    Mix.Task.reenable("agent_machine.skills")

    install_output =
      capture_io(fn ->
        SkillsTask.run([
          "install",
          "clawhub:docs-helper",
          "--skills-dir",
          skills_dir,
          "--clawhub-registry",
          server.url,
          "--json"
        ])
      end)

    assert %{"installed" => %{"name" => "docs-helper"}} =
             JSON.decode!(String.trim(install_output))
  end

  defp start_http_server!(request_count, handler) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(socket)

    parent = self()

    pid =
      spawn_link(fn ->
        serve_requests(socket, request_count, handler, parent)
      end)

    %{url: "http://127.0.0.1:#{port}", pid: pid}
  end

  defp serve_requests(socket, 0, _handler, parent) do
    :gen_tcp.close(socket)
    send(parent, {:http_server_done, self()})
  end

  defp serve_requests(socket, count, handler, parent) do
    case :gen_tcp.accept(socket, 5_000) do
      {:ok, client} ->
        {:ok, request} = :gen_tcp.recv(client, 0, 5_000)
        [request_line | _rest] = String.split(request, "\r\n")
        [_method, target, _version] = String.split(request_line, " ")
        {status, content_type, body} = handler.(target)

        response = [
          "HTTP/1.1 #{status} OK\r\n",
          "content-length: #{byte_size(body)}\r\n",
          "content-type: #{content_type}\r\n",
          "connection: close\r\n",
          "\r\n",
          body
        ]

        :ok = :gen_tcp.send(client, response)
        :gen_tcp.close(client)
        serve_requests(socket, count - 1, handler, parent)

      {:error, :timeout} ->
        :gen_tcp.close(socket)
        send(parent, {:http_server_done, self()})
    end
  end

  defp json_response(value), do: {200, "application/json", JSON.encode!(value)}
  defp zip_response(value), do: {200, "application/zip", value}

  defp skill_zip!(root, name, description) do
    source = Path.join(root, "zip-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(source, name))

    File.write!(Path.join(source, "#{name}/SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---
    Body
    """)

    zip_path = Path.join(root, "#{name}.zip")

    File.cd!(source, fn ->
      {:ok, _zip_path} =
        :zip.create(
          String.to_charlist(zip_path),
          [String.to_charlist("#{name}/SKILL.md")]
        )
    end)

    File.read!(zip_path)
  end

  defp unsafe_zip!(root) do
    source = Path.join(root, "unsafe-source")
    File.mkdir_p!(Path.join(source, "child"))
    File.write!(Path.join(source, "evil"), "evil")
    zip_path = Path.join(root, "unsafe.zip")

    File.cd!(Path.join(source, "child"), fn ->
      {:ok, _zip_path} = :zip.create(String.to_charlist(zip_path), [~c"../evil"])
    end)

    File.read!(zip_path)
  end
end
