<#
.SYNOPSIS
    Runs the extension's linters.

.DESCRIPTION
    Runs 'npm run lint' (dependencies are installed by the workflow with
    'npm ci'). Throws on any lint failure so the job fails.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/CI.psm1" -Force

Write-Host '── Lint ──' -ForegroundColor Cyan
npm run lint --if-present
if ($LASTEXITCODE -ne 0) { throw 'Lint failed.' }

Write-Host '✅ Lint passed.' -ForegroundColor Green
