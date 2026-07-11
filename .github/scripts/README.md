# Release pipeline scripts

PowerShell glue for [`release.yml`](../workflows/release.yml). The workflow stays
declarative (what runs, in what order, with what permissions); the *how* lives
here in linted, testable `.ps1` files, per the AI-Platform
[Code-in-Code-Files](https://dnb.ghe.com/AI-Platform/ai-platform/blob/main/docs/internal/principles-and-practices/code-in-code-files.md)
principle and the [PowerShell coding standard](https://dnb.ghe.com/AI-Platform/ai-platform/blob/main/docs/internal/standards/coding/powershell.md).

## Layout

| File | Role |
|------|------|
| `CI.psm1` | Shared module. Pure functions (versioning, glob path-filter, note formatting) and thin wrappers around `git` / `gh` / `npm` / `vsce` / the Marketplace API. |
| `Get-Version.ps1` | Computes the version + release decision once for the run (`find-version` job). |
| `Invoke-Lint.ps1` | Runs `npm run lint` (`lint` job). |
| `Invoke-Build.ps1` | Stamps the version + metadata and packages the VSIX (`build` job). |
| `Invoke-Test.ps1` | Verifies the built VSIX (`test` job). |
| `Invoke-Publish.ps1` | Publishes the VSIX to the VS Code Marketplace (`publish` job). |
| `Invoke-Release.ps1` | Creates the GitHub Release + tag and comments it on the PR (`release` job). |
| `Invoke-CleanupPrerelease.ps1` | Deletes a branch's pre-releases on PR close (`cleanup` job). |
| `CI.Tests.ps1` | Pester tests for the pure functions in `CI.psm1`. |

## How releasing works

Configured in [`release.config.yml`](../release.config.yml). Versioning is
label-driven ([Release Management spec](https://dnb.ghe.com/AI-Platform/ai-platform/blob/main/docs/internal/specifications/release-management.md)):

| Trigger | Outcome |
|---------|---------|
| PR labelled `Major` / `Minor` / `Patch` (default `Patch`), merged to `main` | Stable release + Marketplace publish |
| PR labelled `NoRelease` | No release |
| Open PR labelled `Prerelease` | Pre-release on every push (`v<base>-<branch>.<n>`) |
| `workflow_dispatch` (`bump` input) | Manual release |

`Major`/`Minor`/`Patch` must not be combined, and a semver label must not be
combined with `NoRelease` — the pipeline rejects the combination rather than
guessing.

The git tag / GitHub Release carries the full SemVer version (with any
pre-release suffix); the VS Code Marketplace package version is the numeric
`x.y.z` form, since the Marketplace rejects pre-release suffixes.

## Local development

```powershell
# Run the unit tests
Invoke-Pester ./.github/scripts/CI.Tests.ps1

# Lint
Invoke-ScriptAnalyzer -Path ./.github/scripts -Recurse
```

Most functions read their inputs from environment variables (mirroring the
workflow) and write results to `GITHUB_OUTPUT`; the pure functions in `CI.psm1`
take parameters and return values, so they run and test in isolation.
