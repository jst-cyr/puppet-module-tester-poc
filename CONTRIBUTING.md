# Contributing

This project uses [config/modules.json](config/modules.json) to define which upstream Puppet modules are tested.

## Add a module

1. Open [config/modules.json](config/modules.json).
2. Add a new object under `modules`.
3. At minimum, set `repo`.
4. Optionally set `ref`, `id`, `os`, and `prereqs`.

Minimal example:

```json
{
  "repo": "https://github.com/voxpupuli/puppet-firewalld",
  "ref": "master"
}
```

Example with optional fields:

```json
{
  "id": "puppet-augeasproviders_core",
  "repo": "https://github.com/voxpupuli/puppet-augeasproviders_core",
  "ref": "master",
  "os": "ubuntu-latest",
  "prereqs": {
    "apt": ["libaugeas-dev", "augeas-tools", "pkg-config", "build-essential"]
  }
}
```

## Validate modules.json against schema

Schema file: [config/modules.schema.json](config/modules.schema.json)

Validation script: [scripts/validate_modules_config.py](scripts/validate_modules_config.py)

Run locally:

```bash
python -m pip install jsonschema
python scripts/validate_modules_config.py --config config/modules.json --schema config/modules.schema.json
```

Expected success output:

```text
OK: config/modules.json is valid against config/modules.schema.json
```

If invalid, the script prints path-based errors and exits non-zero.

## CI validation gate

The GitHub Actions workflow validates [config/modules.json](config/modules.json) before building the module matrix.

Workflow: [.github/workflows/compatibility-runner.yml](.github/workflows/compatibility-runner.yml)

If schema validation fails, the `prepare` job fails and module test jobs are blocked.

## Schema reference

Top-level shape:

```json
{
  "modules": [
    {
      "repo": "https://github.com/org/repo",
      "ref": "main"
    }
  ]
}
```

Field definitions for each module item:

- `repo` (required, string): Git repository URL. Must start with `https://` or `git@`.
- `ref` (optional, string): Branch, tag, or commit-ish to clone. Defaults to `main` in runner logic when omitted.
- `id` (optional, string): Stable identifier for reporting/artifacts. Allowed characters: letters, numbers, `_`, `.`, `-`.
- `os` (optional, string): Allowed values are `ubuntu-latest`, `windows-latest`, `macos-latest`.
- `prereqs` (optional, object): Package-manager specific prerequisites.

`prereqs` subfields (each optional):

- `apt`: array of package names
- `dnf`: array of package names
- `yum`: array of package names
- `apk`: array of package names
- `brew`: array of package names
- `choco`: array of package names
- `pacman`: array of package names

Rules for each package list:

- Must be an array of non-empty strings.
- Must not contain duplicates.

## Common mistakes

- Missing required `repo`.
- Extra unexpected keys in module objects.
- Empty package names in `prereqs` lists.
- Invalid `id` characters.
- Invalid `repo` format (must start with `https://` or `git@`).

## Recommended PR checklist

- Add/update module entries in [config/modules.json](config/modules.json).
- Run schema validation locally.
- Ensure no duplicate `id` values in the list.
- Include `prereqs` for modules with known native/system package requirements.
