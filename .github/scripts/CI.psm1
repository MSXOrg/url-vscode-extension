<#
.SYNOPSIS
    Shared functions for the CI / Release pipeline.

.DESCRIPTION
    Pure helpers (versioning, glob path-filtering, release-note formatting) and
    thin wrappers around external tools (git, gh, npm, npx/vsce, the VS Code
    Marketplace API). The pure functions take everything through parameters and
    return values — no side effects — so they are unit-testable with Pester
    (see CI.Tests.ps1). The side-effecting wrappers are kept small so the entry
    scripts (Get-Version.ps1, Invoke-*.ps1) stay declarative.

    Import with:
        Import-Module "$PSScriptRoot/CI.psm1" -Force

    This module follows the AI-Platform PowerShell coding standard: advanced
    functions with [CmdletBinding()], typed and validated parameters, and
    comment-based help on every public function.
#>

# ──────────────────────────────────────────────────────────────────────────────
# GitHub Actions output helpers
# ──────────────────────────────────────────────────────────────────────────────

function Write-GitHubOutput {
    <#
    .SYNOPSIS
        Writes a key=value pair to the GitHub Actions step output file.
    .DESCRIPTION
        Appends a 'name=value' line to the file referenced by GITHUB_OUTPUT.
        No-ops when running outside GitHub Actions so local runs do not fail.
    .PARAMETER Name
        The output variable name.
    .PARAMETER Value
        The output variable value (single line).
    .EXAMPLE
        Write-GitHubOutput -Name 'version' -Value '1.2.3'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    Write-Host "output: $Name=$Value"
}

function Write-GitHubNotice {
    <#
    .SYNOPSIS
        Emits a GitHub Actions notice annotation.
    .DESCRIPTION
        Writes a '::notice::' workflow command so the message surfaces on the run
        summary. Falls back to a plain host write outside GitHub Actions.
    .PARAMETER Message
        The notice message to surface.
    .EXAMPLE
        Write-GitHubNotice -Message 'Published v1.2.3'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::notice::$Message"
    } else {
        Write-Host $Message -ForegroundColor Cyan
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Release configuration (.github/release.config.yml)
# ──────────────────────────────────────────────────────────────────────────────

function Import-ReleaseConfig {
    <#
    .SYNOPSIS
        Reads and parses the repository's release configuration.
    .DESCRIPTION
        Parses .github/release.config.yml into an object using the
        powershell-yaml module (which the workflow installs). Returns a
        hashtable with normalised keys: ReleaseBranches, ReleasePaths,
        PrereleaseCleanup. Missing keys fall back to sensible defaults.
    .PARAMETER Path
        Path to the release config file.
    .EXAMPLE
        $config = Import-ReleaseConfig
        $config.ReleasePaths
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Path = '.github/release.config.yml'
    )

    $result = @{
        ReleaseBranches   = @(@{ branch = 'main'; 'release-type' = 'stable' })
        ReleasePaths      = @()
        PrereleaseCleanup = $true
    }

    if (-not (Test-Path $Path)) {
        Write-Host "No release config at $Path; using defaults."
        return $result
    }

    Import-Module powershell-yaml -ErrorAction Stop
    $raw = ConvertFrom-Yaml (Get-Content -Path $Path -Raw)

    if ($raw.ContainsKey('release-branches')) { $result.ReleaseBranches = @($raw['release-branches']) }
    if ($raw.ContainsKey('release-paths')) { $result.ReleasePaths = @($raw['release-paths']) }
    if ($raw.ContainsKey('prerelease-cleanup')) { $result.PrereleaseCleanup = [bool]$raw['prerelease-cleanup'] }

    return $result
}

# ──────────────────────────────────────────────────────────────────────────────
# Versioning (pure)
# ──────────────────────────────────────────────────────────────────────────────

function Get-BumpTypeFromLabels {
    <#
    .SYNOPSIS
        Determines the SemVer bump from a set of pull-request labels.
    .DESCRIPTION
        Implements the release-management spec §5.1: the canonical labels are
        Major / Minor / Patch / NoRelease (matched case-insensitively). Exactly
        one semver label may apply. Returns 'major', 'minor', 'patch', or 'none'
        (NoRelease). The default when no semver label is present is 'patch'.
        Throws when labels are combined illegally (multiple semver levels, or a
        semver label together with NoRelease) — the spec rejects rather than
        guesses.
    .PARAMETER Labels
        A JSON array string of label names, e.g. '["Minor"]'.
    .EXAMPLE
        Get-BumpTypeFromLabels -Labels '["Minor"]'   # → 'minor'
    .EXAMPLE
        Get-BumpTypeFromLabels -Labels '[]'          # → 'patch' (default)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Labels
    )

    $list = @()
    if ($Labels) {
        try { $list = @($Labels | ConvertFrom-Json) } catch { $list = @() }
    }
    $names = $list | ForEach-Object { "$_".Trim() }

    $hasNoRelease = @($names | Where-Object { $_ -ieq 'NoRelease' }).Count -gt 0

    $levels = @()
    if (@($names | Where-Object { $_ -ieq 'Major' }).Count -gt 0) { $levels += 'major' }
    if (@($names | Where-Object { $_ -ieq 'Minor' }).Count -gt 0) { $levels += 'minor' }
    if (@($names | Where-Object { $_ -ieq 'Patch' }).Count -gt 0) { $levels += 'patch' }

    if ($hasNoRelease -and $levels.Count -gt 0) {
        throw "NoRelease must not be combined with a semver label ($($levels -join ', '))."
    }
    if ($hasNoRelease) { return 'none' }
    if ($levels.Count -gt 1) {
        throw "Multiple semver labels found ($($levels -join ', ')); apply exactly one of Major/Minor/Patch."
    }
    if ($levels.Count -eq 1) { return $levels[0] }

    return 'patch'
}

function Get-BumpedVersion {
    <#
    .SYNOPSIS
        Bumps a SemVer version string by the given type.
    .DESCRIPTION
        Increments the major, minor, or patch segment of an X.Y.Z version and
        resets lower segments to zero.
    .PARAMETER Version
        The current SemVer version, e.g. '1.2.3'.
    .PARAMETER BumpType
        One of 'major', 'minor', 'patch'.
    .EXAMPLE
        Get-BumpedVersion -Version '1.2.3' -BumpType 'minor'   # → '1.3.0'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Version,

        [Parameter(Mandatory)]
        [ValidateSet('major', 'minor', 'patch')]
        [string] $BumpType
    )

    $parts = ($Version -replace '^v', '') -split '\.'
    [int]$major = $parts[0]
    [int]$minor = $parts[1]
    [int]$patch = $parts[2]

    switch ($BumpType) {
        'major' { $major++; $minor = 0; $patch = 0 }
        'minor' { $minor++; $patch = 0 }
        'patch' { $patch++ }
    }

    return "$major.$minor.$patch"
}

function Get-PrereleaseIdentifier {
    <#
    .SYNOPSIS
        Normalises a branch name into a SemVer pre-release identifier.
    .DESCRIPTION
        Implements the release-management spec §6.1: strips the conventional
        prefix up to and including the first '/', replaces remaining '/' and any
        character outside [0-9A-Za-z-] with '-', and lowercases the result.
        'feature/add-widgets' → 'add-widgets'; 'bugfix/fix-123' → 'fix-123'.
    .PARAMETER BranchName
        The source branch name.
    .EXAMPLE
        Get-PrereleaseIdentifier -BranchName 'feature/add-widgets'  # → 'add-widgets'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $BranchName
    )

    $id = $BranchName -replace '^[^/]+/', ''
    $id = $id -replace '[^0-9A-Za-z-]', '-'
    $id = $id.ToLowerInvariant()
    if (-not $id) { $id = 'pre' }

    return $id
}

function Get-ReleaseNoteBody {
    <#
    .SYNOPSIS
        Formats a release-note body from a title and description.
    .DESCRIPTION
        Implements the release-management spec §9: the title is rendered as a
        Markdown H1 heading, followed by the description verbatim.
    .PARAMETER Title
        The heading text (PR title or first commit line).
    .PARAMETER Body
        The body text (PR description or remaining commit message). Optional.
    .EXAMPLE
        Get-ReleaseNoteBody -Title 'Add widgets' -Body 'Details here.'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Title,

        [AllowEmptyString()]
        [string] $Body = ''
    )

    $heading = "# $($Title.Trim())"
    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $heading
    }
    return "$heading`n`n$($Body.Trim())"
}

# ──────────────────────────────────────────────────────────────────────────────
# Path filtering (pure) — release-management spec §8
# ──────────────────────────────────────────────────────────────────────────────

function ConvertTo-GlobRegex {
    <#
    .SYNOPSIS
        Converts a glob pattern to an anchored regular expression.
    .DESCRIPTION
        Supports '*' (any run of non-separator characters), '**' (any run
        including separators), and '?' (a single non-separator character). All
        other characters are matched literally. The result is anchored with ^…$.
    .PARAMETER Glob
        The glob pattern, e.g. 'src/**' or '*.png'.
    .EXAMPLE
        ConvertTo-GlobRegex -Glob 'src/**'   # → '^src/.*$'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Glob
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*') {
            if (($i + 1) -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
                # '**' matches across path separators.
                [void]$sb.Append('.*')
                $i++
                # Swallow a following '/' so 'src/**' also matches 'src/a/b'.
                if (($i + 1) -lt $Glob.Length -and $Glob[$i + 1] -eq '/') { $i++ }
            } else {
                [void]$sb.Append('[^/]*')
            }
        } elseif ($c -eq '?') {
            [void]$sb.Append('[^/]')
        } else {
            [void]$sb.Append([regex]::Escape([string]$c))
        }
        $i++
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

function Test-ArtifactAffectingChange {
    <#
    .SYNOPSIS
        Decides whether a change set is artifact-affecting per the path filter.
    .DESCRIPTION
        Implements the release-management spec §8.2 include/exclude semantics: a
        change set is artifact-affecting when at least one changed file matches an
        include rule and is not matched by an exclude rule (a leading '!' marks an
        exclude; excludes take precedence). When the changed-file list is $null —
        meaning the set could not be determined (e.g. workflow_dispatch, or a push
        with no diff base) — the function returns $true so a release is not
        silently suppressed.
    .PARAMETER ChangedFile
        The changed file paths (repo-relative). $null means "unknown".
    .PARAMETER Rule
        The release-paths glob rules; entries beginning with '!' are excludes.
    .EXAMPLE
        Test-ArtifactAffectingChange -ChangedFile @('src/a.js') -Rule @('src/**','!docs/**')
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [string[]] $ChangedFile,

        [Parameter(Mandatory)]
        [string[]] $Rule
    )

    if ($null -eq $ChangedFile) { return $true }
    if ($ChangedFile.Count -eq 0) { return $false }
    if ($Rule.Count -eq 0) { return $true }

    $includes = @()
    $excludes = @()
    foreach ($r in $Rule) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if ($r.StartsWith('!')) {
            $excludes += (ConvertTo-GlobRegex -Glob $r.Substring(1))
        } else {
            $includes += (ConvertTo-GlobRegex -Glob $r)
        }
    }

    foreach ($file in $ChangedFile) {
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $isExcluded = $false
        foreach ($e in $excludes) { if ($file -match $e) { $isExcluded = $true; break } }
        if ($isExcluded) { continue }
        foreach ($inc in $includes) { if ($file -match $inc) { return $true } }
    }

    return $false
}

# ──────────────────────────────────────────────────────────────────────────────
# VS Code Marketplace
# ──────────────────────────────────────────────────────────────────────────────

function Get-MarketplaceVersion {
    <#
    .SYNOPSIS
        Queries the VS Code Marketplace for a published version of an extension.
    .DESCRIPTION
        Calls the public gallery extensionquery API. In 'stable' mode returns the
        latest version not flagged as a pre-release; in 'any' mode returns the
        absolute latest version. Returns an empty string when the extension is not
        found or the query fails.
    .PARAMETER Publisher
        The extension publisher id.
    .PARAMETER ExtensionName
        The extension name (package.json 'name').
    .PARAMETER Mode
        'stable' (default) or 'any'.
    .EXAMPLE
        Get-MarketplaceVersion -Publisher 'MariusStorhaug' -ExtensionName 'remote-folder-url-button'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Publisher,

        [Parameter(Mandatory)]
        [string] $ExtensionName,

        [ValidateSet('stable', 'any')]
        [string] $Mode = 'stable'
    )

    $body = @{
        filters = @(@{ criteria = @(@{ filterType = 7; value = "$Publisher.$ExtensionName" }) })
        flags   = 512
    } | ConvertTo-Json -Depth 6

    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' `
            -ContentType 'application/json' `
            -Headers @{ Accept = 'application/json; api-version=3.0-preview.1' } `
            -Body $body -ErrorAction Stop
    } catch {
        Write-Host "Marketplace query failed: $($_.Exception.Message)"
        return ''
    }

    $extension = $response.results[0].extensions[0]
    if (-not $extension -or -not $extension.versions) { return '' }

    if ($Mode -eq 'any') {
        return [string]$extension.versions[0].version
    }

    foreach ($v in $extension.versions) {
        $pre = $v.properties | Where-Object {
            $_.key -eq 'Microsoft.VisualStudio.Code.PreRelease' -and $_.value -eq 'true'
        }
        if (-not $pre) { return [string]$v.version }
    }
    return ''
}

# ──────────────────────────────────────────────────────────────────────────────
# Git / GitHub queries
# ──────────────────────────────────────────────────────────────────────────────

function Get-PackageInfo {
    <#
    .SYNOPSIS
        Reads identifying fields from package.json.
    .DESCRIPTION
        Returns a PSCustomObject with Name, Publisher, and Version read from the
        given package.json.
    .PARAMETER Path
        Path to package.json.
    .EXAMPLE
        (Get-PackageInfo).Name
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = 'package.json'
    )

    $pkg = Get-Content -Path $Path -Raw | ConvertFrom-Json
    return [pscustomobject]@{
        Name      = $pkg.name
        Publisher = $pkg.publisher
        Version   = $pkg.version
    }
}

function Get-LatestStableVersion {
    <#
    .SYNOPSIS
        Finds the baseline version to bump from.
    .DESCRIPTION
        Resolution order: (1) the latest non-prerelease GitHub release tag,
        (2) the latest stable VS Code Marketplace version (so a repo published to
        the Marketplace before GitHub releases existed still bumps from the real
        baseline), (3) the configured baseline.
    .PARAMETER Publisher
        Extension publisher id (for the Marketplace fallback).
    .PARAMETER ExtensionName
        Extension name (for the Marketplace fallback).
    .PARAMETER VersionPrefix
        Tag prefix to strip, e.g. 'v'.
    .PARAMETER Baseline
        Last-resort version when nothing is published yet.
    .EXAMPLE
        Get-LatestStableVersion -Publisher 'MariusStorhaug' -ExtensionName 'remote-folder-url-button'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Publisher,

        [Parameter(Mandatory)]
        [string] $ExtensionName,

        [string] $VersionPrefix = 'v',

        [string] $Baseline = '0.0.0'
    )

    $tag = gh release list --exclude-drafts --json tagName, isPrerelease `
        --jq '[.[] | select(.isPrerelease == false)][0].tagName // empty' 2>$null
    if ($LASTEXITCODE -eq 0 -and $tag) {
        return ($tag -replace "^$([regex]::Escape($VersionPrefix))", '')
    }

    $marketplace = Get-MarketplaceVersion -Publisher $Publisher -ExtensionName $ExtensionName -Mode 'stable'
    if ($marketplace) { return $marketplace }

    return $Baseline
}

function Get-NextPrereleaseCounter {
    <#
    .SYNOPSIS
        Computes the next pre-release counter for a base version + identifier.
    .DESCRIPTION
        Finds existing GitHub releases tagged v<base>-<identifier>.<N> and returns
        max(N)+1, starting at 1. Plain integer counter per the spec (no padding).
    .PARAMETER BaseVersion
        The bumped base version, e.g. '1.3.0'.
    .PARAMETER Identifier
        The normalised branch identifier, e.g. 'add-widgets'.
    .PARAMETER VersionPrefix
        Tag prefix, e.g. 'v'.
    .EXAMPLE
        Get-NextPrereleaseCounter -BaseVersion '1.3.0' -Identifier 'add-widgets'
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $BaseVersion,

        [Parameter(Mandatory)]
        [string] $Identifier,

        [string] $VersionPrefix = 'v'
    )

    $prefix = "$VersionPrefix$BaseVersion-$Identifier."
    $max = 0
    $tags = gh release list --json tagName --jq '.[].tagName' 2>$null
    foreach ($t in $tags) {
        if (-not $t -or -not $t.StartsWith($prefix)) { continue }
        $suffix = ($t -split '\.')[-1]
        [int]$n = 0
        if ([int]::TryParse($suffix, [ref]$n) -and $n -gt $max) { $max = $n }
    }
    return ($max + 1)
}

function Get-AssociatedPullRequest {
    <#
    .SYNOPSIS
        Finds the pull request associated with a commit.
    .DESCRIPTION
        Uses the GitHub API to find the PR a commit belongs to (e.g. the merge or
        squash commit that landed on the release branch). Returns a PSCustomObject
        with Number, Title, Body, and Labels, or $null when no PR is associated
        (a direct push).
    .PARAMETER CommitSha
        The commit SHA to look up.
    .EXAMPLE
        Get-AssociatedPullRequest -CommitSha $env:GITHUB_SHA
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CommitSha
    )

    $json = gh api "repos/{owner}/{repo}/commits/$CommitSha/pulls" `
        -H 'Accept: application/vnd.github+json' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }

    try { $prs = @($json | ConvertFrom-Json) } catch { return $null }
    if ($prs.Count -eq 0) { return $null }

    $pr = $prs[0]
    return [pscustomobject]@{
        Number = $pr.number
        Title  = $pr.title
        Body   = $pr.body
        Labels = @($pr.labels | ForEach-Object { $_.name })
    }
}

function Get-ChangedFile {
    <#
    .SYNOPSIS
        Lists the files changed for the current event.
    .DESCRIPTION
        For a pull_request, lists the PR's changed files. For a push, diffs the
        before/after commits. Returns $null when the set cannot be determined
        (workflow_dispatch, or a push whose base SHA is unavailable) so callers
        treat the change as artifact-affecting rather than skipping a release.
    .PARAMETER EventName
        The GitHub event name.
    .PARAMETER BaseSha
        The push 'before' SHA (push only).
    .PARAMETER HeadSha
        The push 'after' SHA (push only).
    .PARAMETER PullRequestNumber
        The pull request number (pull_request only).
    .EXAMPLE
        Get-ChangedFile -EventName 'push' -BaseSha $before -HeadSha $after
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $EventName,

        [string] $BaseSha,

        [string] $HeadSha,

        [string] $PullRequestNumber
    )

    switch ($EventName) {
        'pull_request' {
            if (-not $PullRequestNumber) { return $null }
            $files = gh pr diff $PullRequestNumber --name-only 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return [string[]]@($files | Where-Object { $_ })
        }
        'push' {
            if (-not $BaseSha -or $BaseSha -match '^0+$') { return $null }
            $files = git diff --name-only $BaseSha $HeadSha 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return [string[]]@($files | Where-Object { $_ })
        }
        default { return $null }
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Packaging
# ──────────────────────────────────────────────────────────────────────────────

function Set-PackageVersion {
    <#
    .SYNOPSIS
        Stamps a version into package.json and package-lock.json.
    .DESCRIPTION
        Runs 'npm version' with --no-git-tag-version so the version field is
        updated without creating a git commit or tag. Git tags / GitHub releases
        remain the source of truth; the stamp is not committed back.
    .PARAMETER Version
        The X.Y.Z version to stamp.
    .EXAMPLE
        Set-PackageVersion -Version '1.2.3'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Version
    )

    Write-Host "Stamping version $Version into package.json …" -ForegroundColor Cyan
    npm version $Version --no-git-tag-version --allow-same-version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'npm version failed.' }
}

function Set-PackageMetadata {
    <#
    .SYNOPSIS
        Fills repository/homepage/bugs/license in package.json from the repo.
    .DESCRIPTION
        Uses 'gh repo view' to read the canonical repository URL and license and
        writes them into package.json with surgical 'npm pkg set' edits (no full
        JSON round-trip, so the manifest's deep 'contributes' tree is untouched).
        Keeps the Marketplace listing's links and SPDX license accurate.
    .EXAMPLE
        Set-PackageMetadata
    #>
    [CmdletBinding()]
    param()

    $info = gh repo view --json url, licenseInfo 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $info) {
        Write-Host 'Could not read repo metadata; leaving package.json fields as-is.'
        return
    }

    $url = $info.url
    npm pkg set 'repository.type=git' "repository.url=$url.git" "homepage=$url" "bugs.url=$url/issues" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'npm pkg set (metadata) failed.' }

    $licenseKey = $info.licenseInfo.key
    if ($licenseKey) {
        $spdx = switch ($licenseKey) {
            'mit' { 'MIT' }
            'apache-2.0' { 'Apache-2.0' }
            'gpl-3.0' { 'GPL-3.0' }
            'gpl-2.0' { 'GPL-2.0' }
            'bsd-2-clause' { 'BSD-2-Clause' }
            'bsd-3-clause' { 'BSD-3-Clause' }
            'isc' { 'ISC' }
            'mpl-2.0' { 'MPL-2.0' }
            'lgpl-3.0' { 'LGPL-3.0' }
            'unlicense' { 'Unlicense' }
            default { $licenseKey }
        }
        npm pkg set "license=$spdx" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'npm pkg set (license) failed.' }
    }

    Write-Host "Metadata: repository=$url.git, homepage=$url" -ForegroundColor Cyan
}

function New-Vsix {
    <#
    .SYNOPSIS
        Packages the extension into a VSIX file.
    .DESCRIPTION
        Runs '@vscode/vsce package' (without re-stamping the version — the caller
        has already stamped it) and returns the produced filename
        <name>-<version>.vsix. Marks the package as a pre-release when requested.
    .PARAMETER Version
        The version to use in the output filename (must match package.json).
    .PARAMETER PreRelease
        Mark the VSIX as a Marketplace pre-release.
    .EXAMPLE
        New-Vsix -Version '1.2.3'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Version,

        [switch] $PreRelease
    )

    $name = (Get-PackageInfo).Name
    $vsixName = "$name-$Version.vsix"

    $npxArgs = @('@vscode/vsce', 'package', '--no-update-package-json', '--out', $vsixName)
    if ($PreRelease) { $npxArgs += '--pre-release' }

    Write-Host "Packaging VSIX: $vsixName …" -ForegroundColor Cyan
    npx @npxArgs
    if ($LASTEXITCODE -ne 0) { throw 'VSIX packaging failed.' }

    return $vsixName
}

function Test-VsixPackage {
    <#
    .SYNOPSIS
        Validates a built VSIX file.
    .DESCRIPTION
        Verifies the file exists and is non-empty, and that the zip archive
        contains extension/package.json (required of every VS Code extension).
        Throws on any failure. Uses the .NET zip reader so no external 'unzip' is
        required.
    .PARAMETER VsixFile
        Path to the .vsix file.
    .EXAMPLE
        Test-VsixPackage -VsixFile 'remote-folder-url-button-1.2.3.vsix'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $VsixFile
    )

    if (-not (Test-Path $VsixFile) -or (Get-Item $VsixFile).Length -eq 0) {
        throw "VSIX file is missing or empty: $VsixFile"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $VsixFile))
    try {
        $entries = $zip.Entries.FullName
    } finally {
        $zip.Dispose()
    }

    if ($entries -notcontains 'extension/package.json') {
        throw "VSIX is missing extension/package.json — not a valid extension package: $VsixFile"
    }

    Write-Host "VSIX package is valid: $VsixFile" -ForegroundColor Green
}

# ──────────────────────────────────────────────────────────────────────────────
# Publish / Release
# ──────────────────────────────────────────────────────────────────────────────

function Publish-Marketplace {
    <#
    .SYNOPSIS
        Publishes a VSIX to the VS Code Marketplace.
    .DESCRIPTION
        Runs '@vscode/vsce publish' against an already-built VSIX. Authentication
        uses the VSCE_PAT environment variable, which vsce reads automatically.
    .PARAMETER VsixFile
        Path to the .vsix to publish.
    .PARAMETER PreRelease
        Publish as a Marketplace pre-release.
    .EXAMPLE
        Publish-Marketplace -VsixFile 'remote-folder-url-button-1.2.3.vsix'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $VsixFile,

        [switch] $PreRelease
    )

    if (-not $env:VSCE_PAT) { throw 'VSCE_PAT environment variable is required to publish.' }
    if (-not (Test-Path $VsixFile)) { throw "VSIX file not found: $VsixFile" }

    $npxArgs = @('@vscode/vsce', 'publish', '--packagePath', $VsixFile)
    if ($PreRelease) { $npxArgs += '--pre-release' }

    Write-Host "Publishing $VsixFile to the VS Code Marketplace …" -ForegroundColor Cyan
    npx @npxArgs
    if ($LASTEXITCODE -ne 0) { throw 'vsce publish failed.' }

    Write-Host '✅ Published to the VS Code Marketplace.' -ForegroundColor Green
}

function Publish-GitHubRelease {
    <#
    .SYNOPSIS
        Creates a GitHub Release, attaching the VSIX.
    .DESCRIPTION
        Calls 'gh release create' with --target so the tag is created on an
        explicit commit via the Releases API (no git push). The release name is
        the tag (the version). Either an explicit -Body or -GenerateNotes is used
        for the notes. Returns the published release URL.
    .PARAMETER Tag
        The git tag / release name, e.g. 'v1.2.3'.
    .PARAMETER Target
        The commit SHA the tag points at.
    .PARAMETER VsixFile
        VSIX to attach to the release.
    .PARAMETER Body
        Release notes body (ignored when -GenerateNotes is set).
    .PARAMETER GenerateNotes
        Let GitHub auto-generate the notes.
    .PARAMETER IsPrerelease
        Mark the release as a pre-release.
    .EXAMPLE
        Publish-GitHubRelease -Tag 'v1.2.3' -Target $sha -VsixFile $vsix -Body $notes
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Tag,

        [Parameter(Mandatory)]
        [string] $Target,

        [Parameter(Mandatory)]
        [string] $VsixFile,

        [AllowEmptyString()]
        [string] $Body = '',

        [switch] $GenerateNotes,

        [switch] $IsPrerelease
    )

    if (-not (Test-Path $VsixFile)) {
        throw "VSIX file not found: $VsixFile (not creating tag $Tag)."
    }

    Write-Host "Creating GitHub Release $Tag …" -ForegroundColor Cyan

    $ghArgs = @('release', 'create', $Tag, $VsixFile, '--target', $Target, '--title', $Tag)
    if ($GenerateNotes) {
        $ghArgs += '--generate-notes'
    } else {
        $ghArgs += @('--notes', $Body)
    }
    if ($IsPrerelease) { $ghArgs += '--prerelease' }

    gh @ghArgs | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'GitHub release creation failed.' }

    $releaseUrl = gh release view $Tag --json url --jq '.url'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to read published release URL.' }

    Write-Host "✅ GitHub Release $Tag published." -ForegroundColor Green
    return $releaseUrl
}

function Add-PullRequestReleaseComment {
    <#
    .SYNOPSIS
        Comments the artifact reference and release link on a pull request.
    .DESCRIPTION
        Implements the release-management spec §10 interface: after a release the
        pipeline comments on the PR with a link to the GitHub Release and the
        Marketplace install reference, so the release and what it shipped are
        discoverable from the PR. No-ops when no PR number is supplied.
    .PARAMETER PullRequestNumber
        The PR to comment on.
    .PARAMETER ReleaseUrl
        URL of the published GitHub Release.
    .PARAMETER Version
        The released version.
    .PARAMETER ExtensionId
        The publisher.name identifier used by 'code --install-extension'.
    .PARAMETER IsPrerelease
        Whether the release is a pre-release.
    .EXAMPLE
        Add-PullRequestReleaseComment -PullRequestNumber 12 -ReleaseUrl $u -Version '1.2.3' -ExtensionId 'pub.ext'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $PullRequestNumber,

        [Parameter(Mandatory)]
        [string] $ReleaseUrl,

        [Parameter(Mandatory)]
        [string] $Version,

        [Parameter(Mandatory)]
        [string] $ExtensionId,

        [switch] $IsPrerelease
    )

    if (-not $PullRequestNumber) { return }

    $kind = if ($IsPrerelease) { 'Pre-release' } else { 'Release' }
    $preFlag = if ($IsPrerelease) { ' --pre-release' } else { '' }
    $comment = @"
🚀 **$kind published: [$Version]($ReleaseUrl)**

Install from the VS Code Marketplace:

``````
code --install-extension $ExtensionId$preFlag
``````
"@

    gh pr comment $PullRequestNumber --body $comment 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not comment on PR #$PullRequestNumber (continuing)."
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────

function Remove-BranchPrerelease {
    <#
    .SYNOPSIS
        Deletes the pre-releases produced for a branch.
    .DESCRIPTION
        Implements the release-management spec §6.3: deletes the GitHub
        pre-release entries (and their tags) whose tag matches
        v<base>-<identifier>.<N> for the given branch identifier. Only
        pre-releases are removed; stable releases are never touched.
    .PARAMETER Identifier
        The normalised branch identifier (see Get-PrereleaseIdentifier).
    .EXAMPLE
        Remove-BranchPrerelease -Identifier 'add-widgets'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Identifier
    )

    $tags = gh release list --json tagName, isPrerelease `
        --jq ".[] | select(.isPrerelease == true) | .tagName" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Could not list releases; nothing cleaned up.'
        return
    }

    $token = "-$Identifier."
    $removed = 0
    foreach ($t in $tags) {
        if (-not $t -or ($t -notlike "*$token*")) { continue }
        if ($PSCmdlet.ShouldProcess($t, 'Delete pre-release')) {
            gh release delete $t --cleanup-tag --yes 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Deleted pre-release: $t"
                $removed++
            }
        }
    }
    Write-Host "Pre-release cleanup complete ($removed removed)."
}

Export-ModuleMember -Function @(
    'Write-GitHubOutput',
    'Write-GitHubNotice',
    'Import-ReleaseConfig',
    'Get-BumpTypeFromLabels',
    'Get-BumpedVersion',
    'Get-PrereleaseIdentifier',
    'Get-ReleaseNoteBody',
    'ConvertTo-GlobRegex',
    'Test-ArtifactAffectingChange',
    'Get-MarketplaceVersion',
    'Get-PackageInfo',
    'Get-LatestStableVersion',
    'Get-NextPrereleaseCounter',
    'Get-AssociatedPullRequest',
    'Get-ChangedFile',
    'Set-PackageVersion',
    'Set-PackageMetadata',
    'New-Vsix',
    'Test-VsixPackage',
    'Publish-Marketplace',
    'Publish-GitHubRelease',
    'Add-PullRequestReleaseComment',
    'Remove-BranchPrerelease'
)
