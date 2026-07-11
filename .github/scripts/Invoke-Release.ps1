<#
.SYNOPSIS
    Publishes a GitHub Release for the already-built VSIX and links it on the PR.

.DESCRIPTION
    Composes the release note per the release-management spec §9:
      - pull_request -> the PR title as an H1 heading, then the PR body;
      - push (merged PR) -> the merged PR's title + body;
      - push (direct)    -> the first line of the commit message + the rest;
      - workflow_dispatch -> GitHub-generated notes.
    Creates the GitHub Release with the tag on TARGET_SHA via the Releases API
    (no git push), then comments the release link + install reference back on the
    PR (spec §10).

    Required env: EVENT_NAME, VERSION, TAG, TARGET_SHA, IS_PRERELEASE, VSIX_FILE,
      GH_TOKEN.
    Optional env: PR_NUMBER, PR_TITLE, PR_BODY.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/CI.psm1" -Force

foreach ($required in 'EVENT_NAME', 'VERSION', 'TAG', 'TARGET_SHA', 'IS_PRERELEASE', 'VSIX_FILE', 'GH_TOKEN') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($required))) {
        throw "$required environment variable is required."
    }
}
if ($env:IS_PRERELEASE -notin @('true', 'false')) {
    throw "IS_PRERELEASE must be 'true' or 'false', got '$($env:IS_PRERELEASE)'."
}

$eventName = $env:EVENT_NAME
$version = $env:VERSION
$tag = $env:TAG
$targetSha = $env:TARGET_SHA
$vsix = $env:VSIX_FILE
$isPrerelease = $env:IS_PRERELEASE -eq 'true'
$prNumber = if ($env:PR_NUMBER) { $env:PR_NUMBER } else { '' }

$generate = $false
$title = ''
$body = ''

switch ($eventName) {
    'pull_request' {
        $title = if ($env:PR_TITLE) { $env:PR_TITLE } else { $tag }
        $body = if ($env:PR_BODY) { $env:PR_BODY } else { '' }
    }
    'push' {
        if ($prNumber) {
            $pr = gh pr view $prNumber --json title,body | ConvertFrom-Json
            $title = $pr.title
            $body = $pr.body
        } else {
            # Direct push: first line of the commit message is the heading.
            $message = git log -1 --format=%B $targetSha
            $lines = $message -split "`n"
            $title = $lines[0]
            $body = ($lines | Select-Object -Skip 1) -join "`n"
        }
    }
    'workflow_dispatch' { $generate = $true }
    default { throw "Unsupported event: $eventName" }
}

if ($generate) {
    $releaseUrl = Publish-GitHubRelease -Tag $tag -Target $targetSha -VsixFile $vsix `
        -GenerateNotes -IsPrerelease:$isPrerelease
} else {
    $notes = Get-ReleaseNoteBody -Title $title -Body $body
    $releaseUrl = Publish-GitHubRelease -Tag $tag -Target $targetSha -VsixFile $vsix `
        -Body $notes -IsPrerelease:$isPrerelease
}

$pkg = Get-PackageInfo
$extensionId = "$($pkg.Publisher).$($pkg.Name)"
Add-PullRequestReleaseComment -PullRequestNumber $prNumber -ReleaseUrl $releaseUrl `
    -Version $version -ExtensionId $extensionId -IsPrerelease:$isPrerelease

$kind = if ($isPrerelease) { 'prerelease' } else { 'release' }
Write-GitHubNotice -Message "Published $kind ${tag}: $releaseUrl"
Write-Host "✅ Release ($kind) complete." -ForegroundColor Green

exit 0  # success; don't let a tolerated tool's non-zero $LASTEXITCODE fail the step
