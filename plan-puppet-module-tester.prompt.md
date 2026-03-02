## Plan: External Puppet Core Compatibility Runner (REVISED)

This plan can accomplish your goal with adjustments. The original draft is directionally correct (external harness, no required module edits, staged testing), but it needs stronger controls around credentialed Puppet Core access, deterministic runtime mapping, and consistent result taxonomy across heterogeneous Vox modules.

The revised approach follows Puppet guidance on:
- module structure and metadata discipline: https://help.puppet.com/core/current/Content/PuppetCore/module_structure.htm and https://help.puppet.com/core/current/Content/PuppetCore/modules_metadata.htm
- validation and unit testing workflow with PDK: https://help.puppet.com/pdk/current/topics/pdk_testing.htm, https://help.puppet.com/pdk/current/topics/validate_module.htm, and https://help.puppet.com/pdk/current/topics/unit_test_module.htm
- testing only maintained Puppet Core releases: https://help.puppet.com/core/current/Content/PuppetCore/platform_lifecycle.htm

## Goal Fit Assessment

What already works in the draft:
1. External runner architecture is correct for “no mandatory module changes”.
2. Preflight metadata checks are necessary and align with Puppet metadata requirements.
3. Fast-to-slow execution ordering (lint/unit before acceptance) is the right default.

Gaps that would block scale or reliability:
1. No explicit credential strategy for retrieving Puppet Core artifacts/gems in CI.
2. No pinned compatibility profile (Puppet/Ruby/Bundler) per target release.
3. No fallback strategy when modules use Vox/OpenVox-specific env vars or custom Rake tasks.
4. No normalized error model to distinguish “unsupported by metadata” from “harness failure” and “test failure”.
5. No governance for re-running against newly maintained Puppet 8 releases.

## Revised Implementation Plan

### 1) Define runner contract and module capability detection
Build a module intake contract:
- Input: repo URL/ref, target Puppet Core profile, optional credentials reference.
- Discovery: inspect `metadata.json`, `Gemfile`, `Rakefile`, `.fixtures.yml`, `spec/`, and acceptance helpers.
- Output: capability map (`has_validate`, `has_unit`, `has_acceptance`, `windows_provider_signals`, `uses_vox_vars`, `requires_private_artifacts`).

### 2) Add secure Puppet Core artifact/auth layer (mandatory)
Implement an artifact provider abstraction:
- `public` provider (no auth), `private` provider (token/API key), and `mirror` provider.
- Pull credentials only from CI secrets (never repository files, never logs).
- Emit explicit auth diagnostics: `auth_missing`, `auth_invalid`, `artifact_unreachable`.

Phase-1 source/auth policy:
- Prioritize a community-accessible Puppet Core source where users with accepted EULA terms and a valid API key can authenticate.
- Standardize runner auth on GitHub Actions repository secrets.

### 3) Build deterministic compatibility profiles
Create pinned test profiles per maintained Puppet Core target:
- `puppet_core_version`, `ruby_version`, `bundler_version`, `gem_source_mode`.
- Start with `8-latest-maintained`, then add `8-previous-maintained` for drift detection.
- Source maintained versions from Puppet lifecycle guidance and refresh profile data on a schedule.

### 4) Preflight policy engine before test execution
Evaluate module viability before running tests:
- Parse `metadata.json` requirements/dependencies and classify support against target Puppet profile.
- Validate metadata/schema and key completeness as a separate gate.
- Classify outcomes:
	- `supported`
	- `unsupported_by_metadata`
	- `requires_manual_review` (ambiguous/incomplete metadata)

### 5) Execution adapters (PDK-first, Vox-compatible fallback)
Use ordered execution adapters per module:
1. PDK path: `pdk validate --puppet-version <major>` then `pdk test unit --puppet-version <major>`.
2. Rake path: module-defined `rake`/`bundle exec rake` tasks when PDK path is absent.
3. Acceptance path: run only if acceptance assets and supported nodesets/providers are present.

Adapter requirements:
- honor module-local conventions without mutating module sources
- inject env vars through runner policy (allowlist only)
- separate adapter failure from test failure in reporting

### 6) Result taxonomy and compatibility scoring
Produce structured JSON + JUnit + summary markdown:
- Dimensions: metadata support, validate status, unit status, acceptance status, harness health.
- Top-level compatibility state:
	- `compatible`
	- `conditionally_compatible` (tests pass but metadata mismatch)
	- `not_compatible`
	- `inconclusive` (infra/auth/harness issues)

Phase-1 policy for metadata mismatches:
- Treat metadata mismatches as warnings, not hard failures.
- Keep overall state as `conditionally_compatible` when test stages pass and only metadata support declaration is missing or mismatched.

### 7) GitHub Actions orchestration at scale
Implement matrix strategy:
- axes: `module`, `puppet_profile`, `os` (Linux for unit/lint, Windows only when needed for provider/acceptance checks)
- cache Bundler and fixture dependencies
- publish artifacts and a run-level dashboard summary
- enforce concurrency controls and retry policy for transient network/artifact issues

### 8) Maintainer-facing outputs and recommendation policy
For each module run, output:
- “runner execution requires no module edits” verdict
- optional “recommended updates” list (metadata bounds, test entrypoint normalization, docs alignment)
- confidence indicator based on executed stage depth

## Verification Strategy

1. Runner self-tests using fixture repositories for: modulesync-standard Vox, custom Rake, PDK-native, acceptance-enabled, Windows provider modules.
2. Pilot: this module + at least 10 additional Vox modules across differing maturity levels.
3. Determinism check: repeat same matrix twice; require stable classification and near-identical artifacts.
4. Quality gates:
	 - no secret leakage in logs
	 - all failures mapped to taxonomy
	 - reproducible exit codes and machine-readable summaries

## Phase Decisions

- Decision: external harness only; module repos are treated as immutable test inputs.
- Decision: Puppet Core first, PE deferred.
- Decision: phase 1 pass signal = metadata gate + validate/unit outcomes; acceptance remains conditional.
- Decision: test against maintained Puppet Core releases only, with scheduled profile refresh.
- Decision: Puppet Core source should be community-accessible for EULA-accepted users with API key access.
- Decision: secrets are stored as GitHub Actions repository secrets.
- Decision: metadata mismatch is warning-only in phase 1.
