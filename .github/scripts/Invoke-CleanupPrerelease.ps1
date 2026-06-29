<#
.SYNOPSIS
    Deletes the pre-releases produced for a closed PR's branch.

.DESCRIPTION
    Runs when a pull request is closed (merged or abandoned). Reads the cleanup
    toggle from .github/release.config.yml and, when enabled, removes the
    branch's pre-release tags and GitHub Releases (spec §6.3). Stable releases
    are never touched.

    Required env: HEAD_REF, GH_TOKEN.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/CI.psm1" -Force

if (-not $env:HEAD_REF) { throw 'HEAD_REF environment variable is required.' }

$config = Import-ReleaseConfig
if (-not $config.PrereleaseCleanup) {
    Write-Host 'Pre-release cleanup is disabled in release.config.yml; nothing to do.'
    return
}

$id = Get-PrereleaseIdentifier -BranchName $env:HEAD_REF
Write-Host "Cleaning up pre-releases for branch identifier: $id"
Remove-BranchPrerelease -Identifier $id
