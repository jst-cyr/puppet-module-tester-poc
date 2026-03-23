# AGENTS Guide

This file is for coding agents working in this repository.

## Scope

- Use this guide for automated edits related to module intake, CI behavior, and compatibility test execution.
- Keep user-facing documentation in `README.md` and contributor process in `CONTRIBUTING.md`.

## Primary Files

- `config/modules.json`: module definitions used by local runs and CI matrix generation.
- `config/modules.schema.json`: schema for module config validation.
- `scripts/validate_modules_config.py`: local schema validation helper.
- `.github/workflows/compatibility-runner.yml`: CI pipeline and matrix execution.
- `profiles/puppet_profiles.json`: profile constraints used by the runner.

## Module Addition Workflow (Agent)

1. Add a module object under `modules` in `config/modules.json`.
2. Set `repo` (required), optionally `ref`, `id`, `os`, and `prereqs`.
3. Default behavior when omitted:
   - `ref`: treated as `main` by runner logic.
   - `os`: defaults to `ubuntu-latest` in workflow behavior.
   - `id`: derived from repo name.
4. Validate against schema before proposing completion.

## Decision Rules

- Set `os` only when a module truly requires a specific runner image.
- Use `windows-latest` for Windows-only modules/providers.
- Use `macos-latest` only when explicitly required.
- Omit `os` for general modules to keep Ubuntu as default.
- Add `prereqs` only when requirements are known and verifiable.
- Do not guess system package prerequisites.
- If requirements are unclear, omit `prereqs` first and use failing logs to guide follow-up.
- Add explicit `id` only when stable custom naming is needed in artifacts/reporting.

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

## Editing Expectations for Agents

- Keep README user-focused and free from agent-operational instructions.
- Keep CONTRIBUTING focused on contributor process and schema rules.
- Put agent-specific process updates in this file.
