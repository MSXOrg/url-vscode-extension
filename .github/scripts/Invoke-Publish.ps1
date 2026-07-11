<#
.SYNOPSIS
    Publishes the built VSIX to the VS Code Marketplace.

.DESCRIPTION
    Publishes the already-built VSIX with '@vscode/vsce publish'. Marks the
    upload as a pre-release when IS_PRERELEASE is 'true'.

    Required env: VSCE_PAT.
    Optional env: VSIX_FILE, IS_PRERELEASE.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/CI.psm1" -Force

$vsix = if ($env:VSIX_FILE) {
    $env:VSIX_FILE
} else {
    (Get-ChildItem -Filter '*.vsix' | Select-Object -First 1).Name
}
if (-not $vsix) { throw 'No VSIX file found to publish.' }

$isPrerelease = $env:IS_PRERELEASE -eq 'true'
if ($isPrerelease) {
    Publish-Marketplace -VsixFile $vsix -PreRelease
} else {
    Publish-Marketplace -VsixFile $vsix
}

exit 0  # success; don't let a tolerated tool's non-zero $LASTEXITCODE fail the step
