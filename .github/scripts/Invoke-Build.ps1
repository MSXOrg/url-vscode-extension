<#
.SYNOPSIS
    Stamps the version + metadata and packages the VSIX.

.DESCRIPTION
    Stamps PACKAGE_VERSION into package.json, refreshes the repository metadata
    (repository/homepage/bugs/license) from the GitHub repo, and packages a
    single VSIX. That VSIX is the one artifact carried through the rest of the
    pipeline — test verifies it, publish ships it, release attaches it. Nothing
    is rebuilt downstream. Git tags remain the source of truth for the version;
    the stamp is not committed back.

    Required env: PACKAGE_VERSION, GH_TOKEN.
    Optional env: IS_PRERELEASE.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/CI.psm1" -Force

if (-not $env:PACKAGE_VERSION) { throw 'PACKAGE_VERSION environment variable is required.' }
$version = $env:PACKAGE_VERSION
$isPrerelease = $env:IS_PRERELEASE -eq 'true'

Set-PackageVersion -Version $version
Set-PackageMetadata

$vsix = if ($isPrerelease) { New-Vsix -Version $version -PreRelease } else { New-Vsix -Version $version }
Write-GitHubOutput -Name 'vsix' -Value $vsix

Write-Host "✅ Build complete. Artifact: $vsix" -ForegroundColor Green

exit 0  # success; don't let a tolerated tool's non-zero $LASTEXITCODE fail the step
