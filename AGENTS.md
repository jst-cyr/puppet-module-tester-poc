# AGENTS Guide

This file is for coding agents working in this repository.

## Scope

- Use this guide for automated edits related to module intake, CI behavior, and compatibility test execution.
- Keep user-facing documentation in `README.md` and contributor process in `CONTRIBUTING.md`.

## Primary Files

- `config/modules.json`: module definitions used by local runs and CI matrix generation.
- `config/modules.schema.json`: schema for module config validation.
- `config/beaker/setfiles/`: Beaker host definition files (one per acceptance target, e.g. `el9.yml`).
- `scripts/validate_modules_config.py`: local schema validation helper.
- `.github/workflows/compatibility-runner.yml`: CI pipeline and matrix execution.
- `profiles/puppet_profiles.json`: profile constraints used by the runner.

## Module Addition Workflow (Agent)

1. Inspect the target module repository first (do not skip this step).
2. Add a module object under `modules` in `config/modules.json`.
3. Set `repo` (required), optionally `ref`, `id`, `os`, and `prereqs`.
4. Default behavior when omitted:
   - `ref`: treated as `main` by runner logic.
   - `os`: defaults to `ubuntu-latest` in workflow behavior.
   - `id`: derived from repo name.
5. Validate against schema before proposing completion.

## Decision Rules

- Set `os` only when a module truly requires a specific runner image.
- Use `windows-latest` for Windows-only modules/providers.
- Use `macos-latest` only when explicitly required.
- Omit `os` for general modules to keep Ubuntu as default.
- Do not guess system package prerequisites.
- Determine `prereqs` from repository evidence before finalizing a module addition.
- Add explicit `id` only when stable custom naming is needed in artifacts/reporting.

## Mandatory Prereq Discovery

Before proposing a new module entry, agents must fetch and analyze the target repository at the selected `ref` (or default branch if `ref` is omitted).

Minimum files/signals to inspect:

- `Gemfile` and `Gemfile.lock`
- `Rakefile` and custom rake tasks used by validate/spec/test
- `metadata.json`
- `.fixtures.yml` or `.sync.yml` (if present)
- `spec/spec_helper.rb`, `spec/spec_helper_local.rb`, and unit/integration specs under `spec/`
- acceptance helpers/assets under `spec/acceptance/` or `acceptance/`
- Any scripts invoked by tests (for example in `script/`, `tasks/`, or CI config)

What to extract:

- Native/system tools and libraries required by tests or providers.
- OS-specific requirements (Linux/macOS/Windows) that imply package-manager entries.
- Commands in specs/rake tasks that call external binaries.

How to write `prereqs`:

- Add only package-manager keys supported by schema (`apt`, `dnf`, `yum`, `apk`, `brew`, `choco`, `pacman`).
- Include only non-empty unique package names.
- If repo evidence shows no system prereqs, `prereqs` may be omitted.
- If evidence is inconclusive, run a scoped CI attempt and derive prereqs from failure logs before finalizing.

Evidence requirement in agent response:

- Summarize which repository files were inspected.
- State why `prereqs` were added or omitted.
- Call out any assumptions and required follow-up if evidence was partial.

## Validation Checklist

Run:

```bash
python -m pip install jsonschema
python scripts/validate_modules_config.py --config config/modules.json --schema config/modules.schema.json
```

Expected result:

```text
OK: config/modules.json is valid against config/modules.schema.json
```

Also confirm:

- No duplicate `id` values.
- No unexpected module keys outside schema.
- Package lists in `prereqs` are non-empty strings without duplicates.

## Quick CI Scope Test

When you need a narrow CI run, use workflow input `modules_json` with only new or changed entries, for example:

```json
[{"repo":"https://github.com/voxpupuli/puppet-windowsfeature","ref":"master","os":"windows-latest"}]
```

## CI Behavior Notes

- Workflow validates `config/modules.json` before matrix fan-out.
- Matrix `runs-on` follows per-module `os` when set; otherwise Ubuntu default applies.
- Cross-platform prereqs are installed by package-manager keys in `prereqs` (such as `apt`, `choco`, `brew`).
- Acceptance jobs always run on `ubuntu-latest`; the SUT is a Docker container controlled by `BEAKER_SETFILE`.
- When `PUPPET_CORE_API_KEY` is set, the runner uses a **two-stage isolation model**:
  1. **Build stage** (`build_sut_image`): runs `docker build` with the API key passed as a build arg. Puppet Core agent is installed and credentials are scrubbed from repo config files in the same Dockerfile layer so they never persist in the image.
  2. **Test stage** (`acceptance`): runs untrusted module test code (Beaker/rspec) with **no secrets in the environment**. The runner strips `PUPPET_CORE_API_KEY`, `PASSWORD`, `USERNAME`, and `BUNDLE_RUBYGEMS___PUPPETCORE__PUPPET__COM` from the env before invoking tests. The setfile references the pre-built local image tag — no credentials are embedded in the setfile.
- This design ensures third-party module test code cannot exfiltrate the API key.
- Without an API key, acceptance falls back to the public FOSS puppet-agent from `yum.puppet.com` (capped at 8.10.0).

## Beaker Setfiles

- Each acceptance target in `config/modules.json` references a `setfile` by name (filename stem).
- Corresponding YAML files live under `config/beaker/setfiles/` (e.g. `el9` → `config/beaker/setfiles/el9.yml`).
- The setfile defines the Docker image and platform for the Beaker SUT.
- At runtime, the runner builds a Docker image from the base setfile parameters (image, platform, docker_image_commands) plus Puppet Core install steps, then writes a clean setfile to `workspace/.beaker-setfiles/` that references the locally-built image tag.
- The rewritten setfile contains no secrets — only the image tag and platform metadata.
- When adding a new target OS, create the setfile first, then reference it in `modules.json`.

## Editing Expectations for Agents

- Keep README user-focused and free from agent-operational instructions.
- Keep CONTRIBUTING focused on contributor process and schema rules.
- Put agent-specific process updates in this file.
