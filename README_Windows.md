# Windows Local Setup Guide

This guide covers running the compatibility runner natively on Windows (no WSL).

## 1) Prerequisites

- RubyInstaller Ruby (x64 UCRT) installed (example: Ruby 3.2.x)
- Git installed
- Administrative PowerShell access (for one-time long-path setting)

Validate basics:

```powershell
ruby -v
bundle -v
git --version
ridk version
```

## 2) Enable long paths (one-time)

Run in **Admin PowerShell**:

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
```

Reboot Windows after changing this setting.

Verify:

```powershell
(Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled).LongPathsEnabled
```

Expected: `1`

## 3) Install MSYS2/UCRT build dependencies

Run in VS Code terminal (or "Start Command Prompt with Ruby"):

```powershell
ridk install
ridk exec pacman -Syu --noconfirm
ridk exec pacman -Syu --noconfirm
ridk exec pacman -S --needed --noconfirm base-devel mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-libffi mingw-w64-ucrt-x86_64-pkgconf
```

Verify `libffi`:

```powershell
ridk exec bash -lc "pkg-config --modversion libffi"
```

## 4) Configure local credentials

Use `.puppet-module-tester.local.yml` for local settings:

```yaml
puppet_core_api_key: "<YOUR_API_KEY>"
puppet_core_source_url: "https://rubygems-puppetcore.puppet.com"
puppet_core_auth_header: "X-Api-Key"
puppet_compat_metadata_mode: "warn"
puppet_compat_target: "8-latest-maintained"
puppet_compat_workspace_dir: "C:/Temp/pmt-workspace"
puppet_compat_bundle_path: "C:/Temp/pmt-bundle"
puppet_compat_output_dir: "results/local"
```

Never commit this file.

Recommended on Windows: keep `puppet_compat_workspace_dir` and `puppet_compat_bundle_path` under a short root like `C:/Temp` to avoid deep-path failures in Ruby/Bundler toolchains.

## 5) Run locally

From repo root:

```powershell
ruby scripts/run_local.rb
```

Reports are written to:

- `results/local/compatibility-report.json`
- `results/local/compatibility-report.junit.xml`
- `results/local/compatibility-summary.md`

## 6) If bootstrap fails

1. Clean the module bundle and rerun:

```powershell
Remove-Item -Recurse -Force C:\Temp\pmt-workspace -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\Temp\pmt-bundle -ErrorAction SilentlyContinue
ruby scripts/run_local.rb
```

2. If native extension errors persist (for example `fiddle`/`libffi`), rerun package install step in section 3.
3. Confirm long paths are enabled and that runtime paths are short (`C:\Temp\...`) while keeping repo path reasonably short (for example `C:\GitHub\puppet-module-tester-poc`).

## Notes

- The runner uses split gem sources by default:
  - Puppet/Facter from `https://rubygems-puppetcore.puppet.com`
  - Vox/community test gems from `https://rubygems.org`
- Harness errors make the runner exit non-zero by design so failures are visible in CI.
