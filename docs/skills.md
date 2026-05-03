# AgentMachine Skills

This document defines how AgentMachine skills commands relate to each other,
what is implemented now, and how ClawHub autodiscovery should fit in.

## Concepts

A skill is an installed folder with this shape:

```text
<skills-dir>/<skill-name>/
  SKILL.md
  references/
  assets/
  scripts/
  agents/openai.yaml
```

Only `SKILL.md` is required. It must start with YAML frontmatter:

```markdown
---
name: docs-helper
description: Helps write concise project documentation.
---
Use short sections and command examples.
```

Rules:

- `name` and `description` are required.
- The folder name must match `name`.
- Skill names must be lowercase npm-safe-ish names: letters, digits, `.`, `_`,
  and `-`, starting with a letter or digit.
- Symlinks are rejected inside skill folders.
- `references/` and `assets/` are read-only resource folders.
- `scripts/` is installed but not executable unless script execution is
  explicitly enabled for a run.

## Command Map

Skills have three separate command surfaces:

| Surface | Purpose | Runtime side effects |
| --- | --- | --- |
| `mix agent_machine.skills ...` | Manage skill folders and registries. | Creates, validates, installs, removes skill files. |
| `mix agent_machine.run ... --skills...` | Use installed skills in a run. | Loads selected skill instructions into run context. |
| TUI `/skills ...` | Thin wrapper over CLI commands and saved run config. | Persists TUI config and calls Mix commands. |

The TUI must not parse manifests or implement skill selection. It stores only
mode, directory, selected names, and script permission, then passes explicit CLI
flags to Elixir.

## Skills Directory

All commands that read or write skills need a skills directory:

```sh
mix agent_machine.skills list --skills-dir ~/.agent-machine/skills
```

For run commands, `--skills-dir` may be replaced with
`AGENT_MACHINE_SKILLS_DIR`:

```sh
AGENT_MACHINE_SKILLS_DIR=~/.agent-machine/skills \
mix agent_machine.run ... --skills auto "Update README"
```

Missing directories fail fast when loading skills. Management commands that
create or install skills create the target skills directory if needed.

## Management Commands

### Create

Creates a local skill skeleton and validates it:

```sh
mix agent_machine.skills create docs-helper \
  --skills-dir ~/.agent-machine/skills \
  --description "Helps write concise project documentation"
```

Optional resource directories:

```sh
mix agent_machine.skills create docs-helper \
  --skills-dir ~/.agent-machine/skills \
  --description "Helps write concise project documentation" \
  --resources references,assets,scripts
```

Fails if the skill already exists unless `--force` is provided.

### Generate

Asks the selected provider to draft a local skill, then writes and validates
only `<skills-dir>/<name>/SKILL.md`. The command requires explicit provider,
model, timeout, and pricing values. Remote provider API keys are read from the
same environment variables used by runs, such as `OPENAI_API_KEY` or
`OPENROUTER_API_KEY`.

```sh
mix agent_machine.skills generate docs-helper \
  --skills-dir ~/.agent-machine/skills \
  --description "Helps write concise project documentation" \
  --provider openrouter \
  --model <model-id> \
  --http-timeout-ms 120000 \
  --input-price-per-million <input-price> \
  --output-price-per-million <output-price>
```

Generation fails if the skill already exists. It does not create scripts,
assets, references, README files, or other extra files.

### Validate

Validates a skill folder or `SKILL.md` path:

```sh
mix agent_machine.skills validate ~/.agent-machine/skills/docs-helper
mix agent_machine.skills validate ~/.agent-machine/skills/docs-helper/SKILL.md --json
```

### List

Lists installed skills:

```sh
mix agent_machine.skills list --skills-dir ~/.agent-machine/skills
mix agent_machine.skills list --skills-dir ~/.agent-machine/skills --json
```

### Show

Prints one installed skill, including instructions and resource inventory:

```sh
mix agent_machine.skills show docs-helper --skills-dir ~/.agent-machine/skills
```

### Search

Searches installed skills and the configured registry metadata:

```sh
mix agent_machine.skills search docs --skills-dir ~/.agent-machine/skills
mix agent_machine.skills search docs --skills-dir ~/.agent-machine/skills --registry ./priv/skills/registry.json
```

Current search is metadata search, not remote ClawHub search.

### Install

Installs a skill from an AgentMachine registry entry:

```sh
mix agent_machine.skills install docs-helper --skills-dir ~/.agent-machine/skills
mix agent_machine.skills install docs-helper --skills-dir ~/.agent-machine/skills --registry ./skills.registry.json
```

The install flow:

1. Load registry JSON.
2. Resolve the named skill entry.
3. Copy or clone the source into a staging directory.
4. Validate `SKILL.md`.
5. Move into `<skills-dir>/<name>`.
6. Write `.agent-machine-skills.lock.json`.

Existing installs fail unless `--force` is provided.

### Install From Git

Installs directly from a git repo/ref/path:

```sh
mix agent_machine.skills install-git \
  --repo https://github.com/example/agent-skills.git \
  --ref v1.0.0 \
  --path skills/docs-helper \
  --skills-dir ~/.agent-machine/skills
```

The git ref must be explicit. Do not silently install from a moving default
branch.

### Remove

Removes an installed skill folder and lockfile entry:

```sh
mix agent_machine.skills remove docs-helper --skills-dir ~/.agent-machine/skills
```

## Registry Format

AgentMachine registry JSON currently uses this shape:

```json
{
  "skills": [
    {
      "name": "docs-helper",
      "description": "Helps write concise project documentation.",
      "source": {
        "type": "git",
        "repo": "https://github.com/example/agent-skills.git",
        "ref": "v1.0.0",
        "path": "skills/docs-helper"
      }
    }
  ]
}
```

Local source entries are also supported:

```json
{
  "name": "docs-helper",
  "description": "Helps write concise project documentation.",
  "source": {
    "type": "local",
    "path": "./fixtures/docs-helper"
  }
}
```

Registry validation fails on missing required fields or duplicate names.

## Runtime Use

Skills are off unless requested.

Auto-select by task text:

```sh
mix agent_machine.run \
  --workflow agentic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --skills auto \
  --skills-dir ~/.agent-machine/skills \
  "Update README documentation"
```

Force exact skills:

```sh
mix agent_machine.run \
  --workflow agentic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --skills-dir ~/.agent-machine/skills \
  --skill docs-helper \
  "Update README documentation"
```

Rules:

- `--skills auto` and explicit `--skill` values are mutually exclusive.
- Explicit skill names must exist in `--skills-dir`.
- Auto mode ranks installed skills by `name + description` against the task and
  loads a bounded set of matches.
- Selected `SKILL.md` instructions are injected into planner, worker, and
  finalizer run context.
- Runs emit `skills_loaded` and `skills_selected` events.
- Summaries include top-level `skills`.

## Skill Resource Tools

`SKILL.md` is injected directly. `references/` and `assets/` require the fixed
`skills` tool harness:

```sh
mix agent_machine.run \
  --workflow agentic \
  --provider openrouter \
  --model "YOUR_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 120000 \
  --max-steps 6 \
  --max-attempts 1 \
  --input-price-per-million 0.15 \
  --output-price-per-million 0.60 \
  --skills-dir ~/.agent-machine/skills \
  --skill docs-helper \
  --tool-harness skills \
  --tool-timeout-ms 1000 \
  --tool-max-rounds 2 \
  --tool-approval-mode read-only \
  "Use the docs-helper reference files"
```

The `skills` harness exposes:

- `list_skill_resources`
- `read_skill_resource`

These tools can only read resources from selected skills.

## Skill Scripts

Scripts are denied by default. To expose `run_skill_script`, the run must enable
both the `skills` harness and script execution:

```sh
mix agent_machine.run \
  ... \
  --skills-dir ~/.agent-machine/skills \
  --skill build-helper \
  --tool-harness skills \
  --tool-timeout-ms 1000 \
  --tool-max-rounds 2 \
  --tool-approval-mode full-access \
  --allow-skill-scripts \
  "Run the build-helper script"
```

Script execution still goes through normal tool permission and approval policy.
It should be treated as untrusted command execution.

## TUI Commands

When no skills directory is configured, the TUI initializes
`~/.agent-machine/skills`, creates that directory, and persists it to the TUI
config. The Elixir CLI/runtime still receive an explicit `--skills-dir`.

Set auto mode:

```text
/skills auto ~/.agent-machine/skills
```

Set the directory and choose explicit skills:

```text
/skills dir ~/.agent-machine/skills
/skills add docs-helper
/skills remove docs-helper
/skills clear
```

Inspect and install via Elixir CLI:

```text
/skills list
/skills search docs
/skills search docs downloads
/skills show docs-helper
/skills show clawhub:docs-helper
/skills install docs-helper
/skills install clawhub:docs-helper
/skills update docs-helper
/skills update --all
/skills create docs-helper Helps write concise documentation
/skills generate docs-helper Helps write concise documentation
```

`/skills list` opens a picker for installed skills in the configured directory.
Use Up/Down to move, type to filter by name or description, and press Enter to
select or unselect an explicit skill. Selecting from the picker clears auto mode
because the saved config now contains explicit skill names.

Control script exposure:

```text
/skills scripts on
/skills scripts off
```

Disable skills:

```text
/skills off
```

## ClawHub Autodiscovery

ClawHub is supported as a remote registry adapter, not as a replacement for the
local AgentMachine registry format. AgentMachine talks to the ClawHub HTTP API
directly and never shells out to the `clawhub` CLI.

Search ClawHub:

```sh
mix agent_machine.skills search docs \
  --source clawhub \
  --sort downloads \
  --limit 20
```

Use `*` as the query to browse by sort order:

```sh
mix agent_machine.skills search '*' \
  --source clawhub \
  --sort downloads \
  --limit 20
```

Show remote metadata:

```sh
mix agent_machine.skills show clawhub:docs-helper
```

Install a version-pinned zip bundle:

```sh
mix agent_machine.skills install clawhub:docs-helper \
  --skills-dir ~/.agent-machine/skills \
  --version latest

mix agent_machine.skills install clawhub:owner/docs-helper \
  --skills-dir ~/.agent-machine/skills

mix agent_machine.skills install clawhub:docs-helper \
  --skills-dir ~/.agent-machine/skills \
  --version 1.2.3
```

Update ClawHub-installed skills from lockfile provenance:

```sh
mix agent_machine.skills update clawhub:docs-helper \
  --skills-dir ~/.agent-machine/skills

mix agent_machine.skills update --all \
  --skills-dir ~/.agent-machine/skills
```

The default registry base URL is `https://clawhub.ai`. Override it with either:

```sh
AGENT_MACHINE_CLAWHUB_REGISTRY=http://127.0.0.1:4000 \
  mix agent_machine.skills search docs --source clawhub

mix agent_machine.skills search docs \
  --source clawhub \
  --clawhub-registry http://127.0.0.1:4000
```

Integration rules:

- Search uses `GET /api/v1/search?q=...`; `*` uses
  `GET /api/v1/skills?sort=...`.
- Show uses `GET /api/v1/skills/{slug}` plus versions metadata.
- Install resolves `latest` to a concrete version before downloading with
  `GET /api/v1/download?slug=...&version=...`.
- Validate the downloaded `SKILL.md` with the same local validator before
  install.
- Write ClawHub source metadata, resolved version, registry URL, remote metadata
  snapshot, bundle hash, and installed hash into `.agent-machine-skills.lock.json`.
- Refuse install when the bundle contains unsafe zip paths, symlinks, multiple
  skill roots, or invalid manifests.
- Reject hidden, removed, suspicious, or malware-blocked skills when the API
  exposes those flags.
- Refuse update over local modifications unless `--force` is explicit.
- Never auto-enable scripts from ClawHub skills.
- Show provenance in CLI/TUI output: source, slug, version, author, downloads,
  stars, updated time, and suspicious/hidden flags if the API exposes them.

## Security Defaults

- Skills are disabled unless explicitly configured.
- Remote skills are untrusted.
- Manifest validation is mandatory before install.
- Resource reads are read-only and scoped to selected skills.
- Scripts require explicit run flags and normal command-risk approval.
- Skill commands should fail fast on missing directories, unknown skills,
  duplicate names, invalid registry entries, and unsafe paths.
