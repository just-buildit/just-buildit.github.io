# shellcheck shell=bash
# Finding a PowerShell that can read this repo's files, and speaking to it in
# paths it understands. Sourced, never executed.
#
# This is the genuinely general part of running PowerShell from a Unix-shaped
# shell, which is why it lives in this repo rather than in whichever consumer
# needed it first. A second copy of "which pwsh, and does it need its paths
# translated" is exactly the kind of duplicate that drifts until one caller
# silently stops finding an interpreter the other still finds.
#
# Three cases, decided by capability rather than by distro, so a machine nobody
# here has thought about still gets the right answer:
#
#   * a native pwsh on PATH (Linux, macOS, a Windows shell) -- the paths are
#     already in its vocabulary and pass through untouched;
#   * WSL, where the only PowerShell is Windows' own pwsh.exe. A Linux path
#     like /home/you/x.ps1 means nothing to it, so wslpath -w rewrites each one
#     into the \\wsl.localhost\... spelling it can open;
#   * neither -- which the CALLER must treat as a failure. A linter that is
#     missing checks nothing, and an unrunnable gate that returns 0 is the
#     inert-gate failure this repo has already been bitten by.

# shellcheck disable=SC2034  # PWSH and PWSH_TRANSLATE are set here and read
# by the scripts that source this file, which shellcheck cannot see from here.

#: Set by pwsh_find: the interpreter, and whether its paths need translating.
PWSH=""
PWSH_TRANSLATE=0

# Locate an interpreter. Returns 1 when there is none, and prints nothing --
# the caller decides whether that is fatal, because "no .ps1 files to check"
# and "files to check and no way to check them" are different answers.
pwsh_find() {
	if command -v pwsh >/dev/null 2>&1; then
		PWSH=pwsh
		PWSH_TRANSLATE=0
		return 0
	fi
	if command -v pwsh.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
		PWSH=pwsh.exe
		PWSH_TRANSLATE=1
		return 0
	fi
	return 1
}

# Echo one path in the interpreter's vocabulary.
pwsh_path() {
	if [ "$PWSH_TRANSLATE" -eq 1 ]; then
		wslpath -w "$1"
	else
		printf '%s\n' "$1"
	fi
}

# The flags every invocation wants, as words on stdout for the caller to read
# into an array. -NoProfile so a machine's own profile cannot change a verdict;
# -NonInteractive so a missing module fails instead of prompting forever; and,
# only when running Windows' pwsh.exe against a path it considers remote,
# -ExecutionPolicy Bypass -- the default RemoteSigned refuses an unsigned
# script loaded over a UNC path, which is every file in this repo when it is
# reached from WSL. The flag is Windows-only, so it is never passed to a
# native pwsh, where it would be meaningless.
pwsh_flags() {
	printf '%s\n' -NoProfile -NonInteractive
	if [ "$PWSH_TRANSLATE" -eq 1 ]; then
		printf '%s\n' -ExecutionPolicy Bypass
	fi
}

# What to say when there is no interpreter at all.
pwsh_not_found() {
	echo "  install PowerShell 7+ (https://aka.ms/powershell), or run this" >&2
	echo "  from WSL on a host that has pwsh.exe" >&2
}
