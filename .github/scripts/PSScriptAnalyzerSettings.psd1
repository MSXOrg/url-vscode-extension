# PSScriptAnalyzer settings for the release-pipeline scripts.
#
# These scripts are CI glue (not operational automation), which makes three
# default rules inappropriate here. Each exclusion is deliberate and documented.
@{
    # Fail the build only on real problems.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Write-Host is the correct, reliable way to write progress to the GitHub
        # Actions log; Write-Output would pollute function return values.
        'PSAvoidUsingWriteHost',

        # These helpers run non-interactively in CI; -WhatIf / -Confirm add no
        # value to a throwaway build checkout. (Remove-BranchPrerelease still
        # opts into ShouldProcess because it deletes published releases.)
        'PSUseShouldProcessForStateChangingFunctions',

        # Domain nouns: "Labels" (a PR carries many) and "Metadata"
        # (uncountable) are intentionally not singularised.
        'PSUseSingularNouns'
    )
}
