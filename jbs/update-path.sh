#!/bin/bash
# ############################################################################
# EXECUTABLE: update-path.sh                                                 #
# PACKAGE: just-bashit                                                       #
# ############################################################################
# Put ~/.local/bin on PATH for good, in every shell this user has. That is   #
# where get-jb.sh installs jbx and where tools such as just-makeit's `jm`,   #
# uv and pipx link their commands; it is on PATH by default almost nowhere.  #
#                                                                            #
#   bash      ~/.bashrc                                                      #
#   zsh       ~/.zshrc, when zsh is installed or ~/.zshrc exists, and always #
#             on macOS, where zsh is the login shell and reads no ~/.bashrc  #
#   Windows   the USER Path in the registry (Git Bash, MSYS2, Cygwin; and    #
#             from PowerShell, whose jbx function runs this in Git Bash)     #
#                                                                            #
# An rc file is left alone when it already has an uncommented line naming   #
# .local/bin, or sources just-bashit's own bashrc.sh or profile.sh (which    #
# put it on PATH): a user's own line is never rewritten. Otherwise a marked  #
# block is appended, and a later run finds it and changes nothing. The       #
# Windows entry is added only when no entry of the user Path already         #
# expands to that directory; every other entry, and the value's type         #
# (REG_EXPAND_SZ keeps its %VARS% unexpanded), is kept as it was.            #
#                                                                            #
# Run through the jbx function (jbx-shell.sh, or get-jb.ps1's in            #
# PowerShell), the calling shell gets the directory too, at once: the        #
# function exports JB_RELOAD_MARKER, and this appends `path DIR` there.      #
#                                                                            #
# Prints one line per place: what it wrote there, or why it wrote nothing.   #
#                                                                            #
# Environment:                                                               #
#   JB_UPDATE_PATH_DIR  the directory (default ~/.local/bin; tests)          #
#   JB_UNAME_S          what `uname -s` says (tests)                         #
#   JB_WIN_ENV_KEY      the registry key holding the user Path (default      #
#                       HKCU:\Environment; tests point it at a scratch key)  #
#                                                                            #
# Example:                                                                   #
#   jbx update-path                                                          #
# ############################################################################
# shellcheck disable=SC2016  # rc-file and PowerShell text: their $, not ours
set -euo pipefail
IFS=$'\n\t'

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# _powershell_bin: the one way just-bashit finds Windows PowerShell.
# shellcheck source=pkg.sh
source "${_SCRIPT_DIR}/pkg.sh"

_UP_DIR="${JB_UPDATE_PATH_DIR:-${HOME}/.local/bin}"
_UP_BEGIN='# >>> just-bashit update-path >>>'
_UP_END='# <<< just-bashit update-path <<<'

_up_say() { printf 'update-path: %s\n' "$*"; }

# _up_tilde PATH -- PATH with a leading $HOME shown as ~.
_up_tilde() {
	# shellcheck disable=SC2088  # a ~ to print, not to expand
	case "$1" in
	"${HOME}"/*) printf '~/%s\n' "${1#"${HOME}"/}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# _up_block -- the lines the block holds. POSIX sh, so bash and zsh read it
# alike; $HOME is left for the shell, so the line survives a moved home.
_up_block() {
	local dir="${_UP_DIR}"
	[[ ${dir} == "${HOME}/"* ]] && dir='${HOME}/'"${dir#"${HOME}"/}"
	printf '%s\n' "${_UP_BEGIN}"
	printf 'case ":${PATH}:" in *":%s:"*) ;; *) export PATH="%s:${PATH}" ;; esac\n' \
		"${dir}" "${dir}"
	printf '%s\n' "${_UP_END}"
}

# _up_covered FILE -- the first line of FILE that already puts the directory
# on PATH (an uncommented line naming it, or sourcing just-bashit's
# bashrc.sh / profile.sh), with its number; nothing when there is none.
_up_covered() {
	local line n=0 name="${_UP_DIR#"${HOME}"/}"
	[[ -f $1 ]] || return 0
	while IFS= read -r line || [[ -n ${line} ]]; do
		n=$((n + 1))
		[[ ${line} == "${_UP_BEGIN}" ]] && return 0
		[[ ${line} =~ ^[[:space:]]*# ]] && continue
		if [[ ${line} == *"${name}"* ||
			${line} == *just-bashit/bashrc.sh* ||
			${line} == *just-bashit/profile.sh* ]]; then
			printf '%s: %s\n' "${n}" "${line}"
			return 0
		fi
	done <"$1"
}

# _up_rc FILE -- ensure FILE puts the directory on PATH; say what happened.
_up_rc() {
	local file="$1" shown covered
	shown="$(_up_tilde "${file}")"
	if [[ -f ${file} ]] && grep -qxF "${_UP_BEGIN}" "${file}"; then
		_up_say "${shown}: already has the just-bashit block -- unchanged"
		return 0
	fi
	covered="$(_up_covered "${file}")"
	if [[ -n ${covered} ]]; then
		_up_say "${shown}: line ${covered%%: *} already covers it -- unchanged"
		return 0
	fi
	{
		[[ -s ${file} ]] && printf '\n'
		_up_block
	} >>"${file}"
	_up_say "${shown}: appended"
	_up_block | sed 's/^/    /'
}

# The PowerShell half of _up_windows: prints "present" or "added".
_UP_PS='
$ErrorActionPreference = "Stop"
$key = $env:JB_UP_KEY
$want = $env:JB_UP_WIN.TrimEnd([char]92)
if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
$k = Get-Item -LiteralPath $key
$raw = [string]$k.GetValue("Path", "", "DoNotExpandEnvironmentNames")
$kind = "ExpandString"
if ($k.GetValueNames() -contains "Path") { $kind = [string]$k.GetValueKind("Path") }
$found = $false
foreach ($e in ($raw -split ";")) {
    $x = [Environment]::ExpandEnvironmentVariables($e).TrimEnd([char]92)
    if ($x -and $x -eq $want) { $found = $true }
}
if ($found) { "present" } else {
    $old = $raw.TrimEnd(";")
    $new = if ($old) { $old + ";" + $want } else { $want }
    New-ItemProperty -LiteralPath $key -Name Path -Value $new -PropertyType $kind -Force | Out-Null
    if (-not $env:JB_WIN_ENV_KEY) {
        # Tell running programs (Explorer, so new windows) the environment changed.
        $sig = "[DllImport(""user32.dll"", CharSet = CharSet.Auto)] public static extern IntPtr " +
            "SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);"
        $t = Add-Type -MemberDefinition $sig -Name JbSettingChange -Namespace JustBashit -PassThru
        $r = [UIntPtr]::Zero
        [void]$t::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$r)
    }
    "added"
}
'

# _up_windows -- add the directory to the Windows USER Path in the registry,
# once. Native Windows shells only: under WSL ~/.local/bin is a Linux path.
_up_windows() {
	local ps win out
	case "${JB_UNAME_S:-$(uname -s 2>/dev/null || echo unknown)}" in
	MINGW* | MSYS* | CYGWIN*) ;;
	*) return 0 ;;
	esac
	if ! ps="$(_powershell_bin)" || ! command -v cygpath >/dev/null 2>&1; then
		_up_say "Windows user Path: no powershell.exe or cygpath here -- unchanged"
		return 0
	fi
	win="$(cygpath -w "${_UP_DIR}")"
	# The script and its values cross in the environment, not on the command
	# line, which the MSYS runtime would re-quote. The value is read and
	# written unexpanded, with its type kept: SetEnvironmentVariable would
	# expand every %VAR% in it for good and write REG_SZ.
	out="$(JB_UP_PS="${_UP_PS}" JB_UP_WIN="${win}" \
		JB_UP_KEY="${JB_WIN_ENV_KEY:-HKCU:\\Environment}" \
		"${ps}" -NoProfile -NonInteractive -Command 'Invoke-Expression $env:JB_UP_PS' 2>&1 | tr -d '\r')" || {
		_up_say "Windows user Path: could not be updated (${out//$'\n'/ })"
		return 1
	}
	case "${out}" in
	*present) _up_say "Windows user Path: already has ${win} -- unchanged" ;;
	*added) _up_say "Windows user Path: appended ${win} (new windows see it)" ;;
	*)
		_up_say "Windows user Path: unexpected answer (${out//$'\n'/ })"
		return 1
		;;
	esac
}

# _up_this_shell -- the directory on the calling shell's PATH now, through
# the jbx function's reload marker, when there is one to write.
_up_this_shell() {
	if [[ -n ${JB_RELOAD_MARKER:-} ]]; then
		mkdir -p "${JB_RELOAD_MARKER%/*}"
		printf 'path %s\n' "${_UP_DIR}" >>"${JB_RELOAD_MARKER}"
		_up_say "this shell: jbx puts $(_up_tilde "${_UP_DIR}") on PATH when this exits"
	else
		case ":${PATH}:" in
		*":${_UP_DIR}:"*) ;;
		*) _up_say "this shell: open a new one to see it (not run through the jbx function)" ;;
		esac
	fi
}

_up_main() {
	local rc=0 os
	os="${JB_UNAME_S:-$(uname -s 2>/dev/null || echo unknown)}"
	_up_rc "${HOME}/.bashrc"
	if [[ ${os} == Darwin || -f "${HOME}/.zshrc" ]] || command -v zsh >/dev/null 2>&1; then
		_up_rc "${HOME}/.zshrc"
	fi
	_up_windows || rc=1
	_up_this_shell
	return "${rc}"
}

_up_main "$@"
