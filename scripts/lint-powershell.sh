#!/usr/bin/env bash
# Run PSScriptAnalyzer over the PowerShell files named as arguments.
#
# Finding an interpreter is the awkward part and it lives in pwsh-lib.sh, which
# the behaviour tests share -- see that file for why WSL needs its paths
# translated.
#
# Usage:
#   scripts/lint-powershell.sh install.ps1 ensure-gitconfig-include.ps1
#   scripts/lint-powershell.sh $(git ls-files '*.ps1')
#
# Exit status: 0 clean, 1 the analyzer reported something, 2 it could not be
# run at all (no PowerShell, or the module is not installed).
set -euo pipefail

. "$(dirname "$0")/pwsh-lib.sh"

# No PowerShell in the tree is not a failure -- there is simply nothing to
# check. Tested BEFORE the interpreter hunt so a machine with no pwsh and no
# .ps1 files keeps a green `make lint`.
if [ "$#" -eq 0 ]; then
	echo "psscriptanalyzer: no .ps1 files"
	exit 0
fi

if ! pwsh_find; then
	echo "psscriptanalyzer: no PowerShell found, so $# .ps1 file(s) went unchecked" >&2
	pwsh_not_found
	exit 2
fi

# Build a PowerShell array literal of single-quoted paths. A literal single
# quote is escaped by doubling it, which is PowerShell's own rule.
paths=""
for f in "$@"; do
	p="$(pwsh_path "$f")"
	paths="${paths}'${p//\'/\'\'}',"
done
paths="${paths%,}"

mapfile -t flags < <(pwsh_flags)

"$PWSH" "${flags[@]}" -Command "
\$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Error 'PSScriptAnalyzer is not installed. Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 2
}
Import-Module PSScriptAnalyzer
\$found = @(@($paths) | ForEach-Object { Invoke-ScriptAnalyzer -Path \$_ -Severity Error,Warning })
if (\$found.Count -gt 0) {
    \$found | Format-Table Severity,RuleName,Line,ScriptName,Message -AutoSize | Out-String -Width 200
    exit 1
}
exit 0
" || exit $?

echo "psscriptanalyzer: $# file(s) clean"
