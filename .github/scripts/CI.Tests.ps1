#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for the pure functions in CI.psm1.
.DESCRIPTION
    Covers the versioning, glob path-filter, and release-note logic. Run with:
        Invoke-Pester ./.github/scripts/CI.Tests.ps1
#>

BeforeAll {
    Import-Module "$PSScriptRoot/CI.psm1" -Force
}

Describe 'Get-BumpTypeFromLabels' {
    It 'returns patch by default when no semver label is present' {
        Get-BumpTypeFromLabels -Labels '[]' | Should -Be 'patch'
        Get-BumpTypeFromLabels -Labels '["enhancement"]' | Should -Be 'patch'
    }

    It 'maps each canonical label (case-insensitively)' {
        Get-BumpTypeFromLabels -Labels '["Major"]' | Should -Be 'major'
        Get-BumpTypeFromLabels -Labels '["Minor"]' | Should -Be 'minor'
        Get-BumpTypeFromLabels -Labels '["Patch"]' | Should -Be 'patch'
        Get-BumpTypeFromLabels -Labels '["minor"]' | Should -Be 'minor'
    }

    It 'returns none for NoRelease' {
        Get-BumpTypeFromLabels -Labels '["NoRelease"]' | Should -Be 'none'
    }

    It 'rejects multiple semver labels' {
        { Get-BumpTypeFromLabels -Labels '["Major","Minor"]' } | Should -Throw
    }

    It 'rejects a semver label combined with NoRelease' {
        { Get-BumpTypeFromLabels -Labels '["Minor","NoRelease"]' } | Should -Throw
    }
}

Describe 'Get-BumpedVersion' {
    It 'bumps major and resets lower segments' {
        Get-BumpedVersion -Version '1.2.3' -BumpType 'major' | Should -Be '2.0.0'
    }
    It 'bumps minor and resets patch' {
        Get-BumpedVersion -Version '1.2.3' -BumpType 'minor' | Should -Be '1.3.0'
    }
    It 'bumps patch' {
        Get-BumpedVersion -Version '1.2.3' -BumpType 'patch' | Should -Be '1.2.4'
    }
    It 'tolerates a leading v' {
        Get-BumpedVersion -Version 'v1.2.3' -BumpType 'patch' | Should -Be '1.2.4'
    }
}

Describe 'Get-PrereleaseIdentifier' {
    It 'strips the conventional prefix up to the first slash' {
        Get-PrereleaseIdentifier -BranchName 'feature/add-widgets' | Should -Be 'add-widgets'
        Get-PrereleaseIdentifier -BranchName 'bugfix/fix-123-crash' | Should -Be 'fix-123-crash'
    }
    It 'replaces unsafe characters and lowercases' {
        Get-PrereleaseIdentifier -BranchName 'Feature/Add_Widgets!' | Should -Be 'add-widgets-'
    }
    It 'keeps a name with no prefix' {
        Get-PrereleaseIdentifier -BranchName 'hotfix' | Should -Be 'hotfix'
    }
}

Describe 'Get-ReleaseNoteBody' {
    It 'renders the title as an H1 heading' {
        Get-ReleaseNoteBody -Title 'Add widgets' | Should -Be '# Add widgets'
    }
    It 'appends the body after a blank line' {
        Get-ReleaseNoteBody -Title 'Add widgets' -Body 'Details.' | Should -Be "# Add widgets`n`nDetails."
    }
}

Describe 'ConvertTo-GlobRegex' {
    It 'matches a single-star segment but not a separator' {
        'icon.png' | Should -Match (ConvertTo-GlobRegex -Glob '*.png')
        'media/icon.png' | Should -Not -Match (ConvertTo-GlobRegex -Glob '*.png')
    }
    It 'matches a double-star across separators' {
        'src/a.js' | Should -Match (ConvertTo-GlobRegex -Glob 'src/**')
        'src/deep/a.js' | Should -Match (ConvertTo-GlobRegex -Glob 'src/**')
    }
    It 'matches a literal path' {
        'package.json' | Should -Match (ConvertTo-GlobRegex -Glob 'package.json')
        'src/package.json' | Should -Not -Match (ConvertTo-GlobRegex -Glob 'package.json')
    }
}

Describe 'Test-ArtifactAffectingChange' {
    BeforeAll {
        $rules = @('src/**', 'package.json', 'README.md', '!docs/**', '!.github/**')
    }

    It 'treats an unknown change set as affecting' {
        Test-ArtifactAffectingChange -ChangedFile $null -Rule $rules | Should -BeTrue
    }
    It 'treats an empty change set as not affecting' {
        Test-ArtifactAffectingChange -ChangedFile @() -Rule $rules | Should -BeFalse
    }
    It 'is affecting when a source file changes' {
        Test-ArtifactAffectingChange -ChangedFile @('src/extension.js') -Rule $rules | Should -BeTrue
    }
    It 'is not affecting for docs-only changes' {
        Test-ArtifactAffectingChange -ChangedFile @('docs/guide.md') -Rule $rules | Should -BeFalse
    }
    It 'is not affecting for workflow-only changes' {
        Test-ArtifactAffectingChange -ChangedFile @('.github/workflows/release.yml') -Rule $rules | Should -BeFalse
    }
    It 'is affecting when at least one file qualifies' {
        Test-ArtifactAffectingChange -ChangedFile @('docs/guide.md', 'src/extension.js') -Rule $rules | Should -BeTrue
    }
}
