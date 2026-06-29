<#
.SYNOPSIS
    Verifies the built VSIX.

.DESCRIPTION
    Locates the VSIX (restored from the build artifact) and validates that it is
    a non-empty, well-formed extension package. Throws on any problem.

    Optional env: VSIX_FILE (otherwise the single *.vsix in the working
    directory is used).
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
if (-not $vsix) { throw 'No VSIX file found to verify.' }

Test-VsixPackage -VsixFile $vsix
