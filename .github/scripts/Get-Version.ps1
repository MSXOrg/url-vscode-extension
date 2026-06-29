<#
.SYNOPSIS
    Computes the release version and decision for this run, writing GITHUB_OUTPUT.

.DESCRIPTION
    Reads the event context from environment variables and decides:
      - version         : SemVer for the git tag / GitHub Release (may carry a
                          pre-release suffix, e.g. 1.3.0-add-widgets.1).
      - package-version : numeric X.Y.Z stamped into package.json and published
                          to the Marketplace (which rejects pre-release suffixes).
      - tag             : 'v' + version.
      - bump            : major | minor | patch | none.
      - is-prerelease   : 'true' | 'false'.
      - should-release  : 'true' when this run should publish + release.
      - pr-number       : associated PR number, or '' for a direct push/dispatch.

    Trigger handling (release-management spec §3):
      push          -> stable release; bump from the merged PR's label (or 'patch'
                       for a direct push); gated by the path filter (§8).
      pull_request  -> validation always; a release only when a pre-release label
                       is present on an open, same-repo PR (§6.1).
      dispatch      -> manual release; bump from the 'bump' input (§5.1).

    Required env: EVENT_NAME, GH_TOKEN.
    Optional env (by event): BUMP_INPUT, PR_NUMBER, PR_LABELS, HEAD_REF,
      IS_FORK_PR, BASE_SHA, HEAD_SHA.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/CI.psm1" -Force

if (-not $env:EVENT_NAME) { throw 'EVENT_NAME environment variable is required.' }
$eventName = $env:EVENT_NAME

$pkg = Get-PackageInfo
$config = Import-ReleaseConfig
$prereleaseLabels = @('Prerelease', 'pre-release')

# Defaults
$bump = 'patch'
$isPrerelease = $false
$shouldRelease = $false
$prNumber = ''
$version = ''
$packageVersion = ''

$latestStable = Get-LatestStableVersion -Publisher $pkg.Publisher -ExtensionName $pkg.Name

switch ($eventName) {
    'workflow_dispatch' {
        $bump = if ($env:BUMP_INPUT) { $env:BUMP_INPUT } else { 'patch' }
        $packageVersion = Get-BumpedVersion -Version $latestStable -BumpType $bump
        $version = $packageVersion
        $shouldRelease = $true
    }

    'pull_request' {
        $labels = if ($env:PR_LABELS) { $env:PR_LABELS } else { '[]' }
        $bump = Get-BumpTypeFromLabels -Labels $labels   # throws on illegal combos
        $prNumber = if ($env:PR_NUMBER) { $env:PR_NUMBER } else { '' }

        $labelList = @()
        try { $labelList = @($labels | ConvertFrom-Json) } catch { $labelList = @() }
        $hasPrerelease = $false
        foreach ($label in $labelList) {
            foreach ($p in $prereleaseLabels) {
                if ("$label" -ieq $p) { $hasPrerelease = $true }
            }
        }
        $isForkPr = $env:IS_FORK_PR -eq 'true'

        if ($bump -eq 'none') {
            # NoRelease wins — validate only.
            $packageVersion = $latestStable
            $version = $latestStable
        } elseif ($hasPrerelease -and -not $isForkPr) {
            $isPrerelease = $true
            $shouldRelease = $true
            if (-not $env:HEAD_REF) { throw 'HEAD_REF is required for a pre-release.' }
            $base = Get-BumpedVersion -Version $latestStable -BumpType $bump
            $id = Get-PrereleaseIdentifier -BranchName $env:HEAD_REF
            $counter = Get-NextPrereleaseCounter -BaseVersion $base -Identifier $id
            $version = "$base-$id.$counter"
            # The Marketplace needs a strictly-increasing X.Y.Z with no suffix, so
            # take the absolute latest published version and bump its patch — every
            # push to the PR then publishes higher than anything already live.
            $mpLatest = Get-MarketplaceVersion -Publisher $pkg.Publisher -ExtensionName $pkg.Name -Mode 'any'
            $packageVersion = if ($mpLatest) { Get-BumpedVersion -Version $mpLatest -BumpType 'patch' } else { $base }
        } else {
            # Open PR with no pre-release request (or a fork) — validate only.
            $packageVersion = Get-BumpedVersion -Version $latestStable -BumpType $bump
            $version = $packageVersion
        }
    }

    'push' {
        if (-not $env:HEAD_SHA) { throw 'HEAD_SHA is required for a push.' }
        $pr = Get-AssociatedPullRequest -CommitSha $env:HEAD_SHA
        if ($pr) {
            $labelsJson = (@($pr.Labels) | ConvertTo-Json -Compress)
            if ($null -eq $labelsJson) { $labelsJson = '[]' }
            if ($labelsJson -notmatch '^\[') { $labelsJson = "[$labelsJson]" }
            $bump = Get-BumpTypeFromLabels -Labels $labelsJson
            $prNumber = "$($pr.Number)"
        } else {
            $bump = 'patch'   # direct push, no PR -> default patch
        }

        if ($bump -eq 'none') {
            $packageVersion = $latestStable
            $version = $latestStable
        } else {
            $packageVersion = Get-BumpedVersion -Version $latestStable -BumpType $bump
            $version = $packageVersion
            $changed = Get-ChangedFile -EventName 'push' -BaseSha $env:BASE_SHA -HeadSha $env:HEAD_SHA
            $shouldRelease = Test-ArtifactAffectingChange -ChangedFile $changed -Rule $config.ReleasePaths
            if (-not $shouldRelease) {
                Write-GitHubNotice -Message "No artifact-affecting changes; skipping release of v$version."
            }
        }
    }

    default { throw "Unsupported event: $eventName" }
}

$tag = "v$version"

Write-Host "Event           : $eventName"
Write-Host "Latest stable   : $latestStable"
Write-Host "Bump            : $bump"
Write-Host "Version (tag)   : $version"
Write-Host "Package version : $packageVersion"
Write-Host "Pre-release     : $isPrerelease"
Write-Host "Should release  : $shouldRelease"
Write-Host "PR number       : $prNumber"

Write-GitHubOutput -Name 'version' -Value $version
Write-GitHubOutput -Name 'package-version' -Value $packageVersion
Write-GitHubOutput -Name 'tag' -Value $tag
Write-GitHubOutput -Name 'bump' -Value $bump
Write-GitHubOutput -Name 'is-prerelease' -Value $(if ($isPrerelease) { 'true' } else { 'false' })
Write-GitHubOutput -Name 'should-release' -Value $(if ($shouldRelease) { 'true' } else { 'false' })
Write-GitHubOutput -Name 'pr-number' -Value $prNumber

if ($shouldRelease) {
    Write-GitHubNotice -Message "Working on $tag (prerelease=$isPrerelease)"
}
