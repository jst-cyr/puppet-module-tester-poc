# puppet-module-tester-poc
This is a proof-of-concept to see if there is a simpler way of testing modules against Puppet Core.

## Goal

Run compatibility tests for Vox Pupuli (and other community) modules against Puppet Core, using an external harness and GitHub Actions, without requiring source changes in the tested module.

## What is implemented

- Ruby CLI runner: `bin/puppet-module-tester`
- Module intake from `config/modules.json`
- Compatibility profiles from `profiles/puppet_profiles.json`
- Preflight checks:
	- clone module repo/ref
	- discover capabilities (`Gemfile`, `Rakefile`, `spec/`, acceptance assets)
	- evaluate `metadata.json` Puppet requirement vs target profile
	- enforce auth requirement for private artifact mode
- Execution adapters:
	- PDK-first: `pdk validate`, `pdk test unit`
	- fallback Rake: `bundle exec rake validate/spec/test` when available
	- optional acceptance stage (`--allow-acceptance`)
- Outputs:
	- JSON report: `results/.../compatibility-report.json`
	- JUnit report: `results/.../compatibility-report.junit.xml`
	- Markdown summary: `results/.../compatibility-summary.md`
- GitHub Actions workflow with module matrix: `.github/workflows/compatibility-runner.yml`

## Quick start (local)

1. Install Ruby 3.2+ and Bundler.
2. From repo root:

	 `bundle install`

3. Run:

	 `ruby bin/puppet-module-tester --modules-file config/modules.json --profiles-file profiles/puppet_profiles.json --profile 8-latest-maintained --metadata-mode warn --workspace-dir workspace --output-dir results/local`

4. Review reports in `results/local`.

## Configure target modules

Edit `config/modules.json`:

```json
{
	"modules": [
		{
			"repo": "https://github.com/voxpupuli/puppet-windows_firewall",
			"ref": "main"
		}
	]
}
```

## Configure compatibility profiles

Edit `profiles/puppet_profiles.json` to pin Puppet/Ruby/Bundler and artifact mode.

- `gem_source_mode=private` requires `PUPPET_CORE_API_KEY`
- `metadata_mode=warn` keeps metadata mismatches as warnings (phase-1 policy)

## GitHub Actions secret setup

This project assumes Puppet Core artifacts may require authenticated access.

In your GitHub repository, go to **Settings → Secrets and variables → Actions → New repository secret** and create:

- `PUPPET_CORE_API_KEY`  
	API key/token for your Puppet account that has access to Puppet Core artifacts.

Optional (if your endpoint is not the default used by your workflow/app):

- `PUPPET_CORE_SOURCE_URL`  
	Base URL for the artifact source (gem repo/package endpoint/mirror).

Optional (for custom auth header schemes):

- `PUPPET_CORE_AUTH_HEADER`  
	Header name expected by the source. Example: `Authorization`.

## GitHub Actions usage

Workflow file: `.github/workflows/compatibility-runner.yml`

- Trigger: **Actions → Puppet Module Compatibility Runner → Run workflow**
- Inputs:
	- `profile` (default `8-latest-maintained`)
	- `metadata_mode` (`warn` or `fail`, default `warn`)
	- `modules_json` (optional JSON array override)

Example `modules_json` input:

`[{"repo":"https://github.com/voxpupuli/puppet-windows_firewall","ref":"main"}]`

## Environment variables expected by the runner/workflow

Use these env vars in your GitHub Actions workflow jobs:

- `PUPPET_CORE_API_KEY` (required)
- `PUPPET_CORE_SOURCE_URL` (optional)
- `PUPPET_CORE_AUTH_HEADER` (optional)
- `PUPPET_COMPAT_METADATA_MODE` (recommended): set to `warn` for phase 1

Recommended defaults for this POC:

- `PUPPET_COMPAT_METADATA_MODE=warn`
- `PUPPET_COMPAT_TARGET=8-latest-maintained`

## Policy decisions currently in effect

- Puppet Core source priority: community-accessible source usable by users who accepted EULA terms and have an API key.
- Secret storage: GitHub Actions repository secrets.
- Metadata mismatch handling: warning only (does not hard fail phase-1 compatibility).

## Operational notes

- Do not commit tokens to the repo.
- Do not print secrets in logs; mask values in workflow output.
- Keep Puppet target versions aligned with maintained releases from Puppet lifecycle guidance on help.puppet.com.

## Next step

After secrets are configured, run the GitHub Actions workflow and review uploaded artifacts per module matrix entry.
