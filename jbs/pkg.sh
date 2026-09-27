#!/bin/bash
# ############################################################################
# LIBRARY: pkg.sh                                                            #
# PACKAGE: just-bashit version 0.6.0                                        #
# ############################################################################
# Package manager detection and version querying.                            #
# ############################################################################

(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

# ---------------------------------------------------------------------------
# winget-bin
#
# Print the winget executable to invoke, or return 1 when there is none.
#
# The NAME differs by which bash is running. MSYS2, Cygwin and Git Bash
# resolve a bare `winget`, because the Windows loader appends PATHEXT; from
# WSL only the explicit `winget.exe` resolves, because a Linux PATH lookup
# has no PATHEXT to append and the interop directory holds only the .exe.
# Both are tried rather than one being assumed.
#
# JB_WINGET overrides, set to a stub for a test or to empty for "none here".
# PATH cannot express either: the WindowsApps interop directory is on PATH in
# both shells, and a name removed from it is still reachable by the other
# spelling.
# ---------------------------------------------------------------------------
winget-bin() {
	local _b
	if [ -n "${JB_WINGET+x}" ]; then
		[ -n "${JB_WINGET}" ] || return 1
		printf '%s\n' "${JB_WINGET}"
		return 0
	fi
	for _b in winget winget.exe; do
		if command -v "${_b}" >/dev/null 2>&1; then
			printf '%s\n' "${_b}"
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# get-pkg-mgr
# ---------------------------------------------------------------------------
get-pkg-mgr() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: get-pkg-mgr

		  Print the name of the active package manager for the running OS.
		  Exits non-zero and prints to stderr if the OS is unrecognised.

		Options:
		  -h  Show this message and exit.

		Output:
		  One of: apt, pacman, brew, dnf, zypper, apk, msys2, winget.

		Examples:
		  pm=$(get-pkg-mgr)
		  get-pkg-mgr   # prints e.g. "pacman" on Arch Linux
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	# Read through JB_UNAME_S so a test can pin a platform. Without it the
	# Windows arm below is exercised on no runner at all: the Linux and
	# macOS ones never reach it, and the Windows one has pacman, so its
	# winget branch would never run.
	local os
	os="${JB_UNAME_S:-$(uname -s)}"
	case "${os}" in
	Darwin)
		echo "brew"
		;;
	Linux)
		local ID="" ID_LIKE=""
		[ -f /etc/os-release ] && . /etc/os-release
		case "${ID_LIKE:-} ${ID:-}" in
		*debian* | *ubuntu*) echo "apt" ;;
		*arch* | *cachyos* | *manjaro*) echo "pacman" ;;
		*fedora* | *rhel* | *centos* | *rocky* | *alma*) echo "dnf" ;;
		*suse*) echo "zypper" ;;
		*alpine*) echo "apk" ;;
		*)
			printf 'error: unrecognized distro (ID=%s)\n' "${ID}" >&2
			printf '       Use --section to specify a package manager.\n' >&2
			return 1
			;;
		esac
		;;
	MINGW* | MSYS* | CYGWIN*)
		# MSYS2 and Git Bash report the same uname, so uname alone cannot
		# tell them apart — pacman is what does. MSYS2 has it and owns the
		# UCRT64 toolchain, so it keeps the msys2 section. Git Bash has no
		# pacman at all and until now was handed pacman instructions it had
		# no way to run; winget is the manager that machine actually has.
		#
		# Neither present falls back to msys2, whose section only ever
		# prints what to run by hand.
		if command -v pacman >/dev/null 2>&1; then
			echo "msys2"
		elif winget-bin >/dev/null 2>&1; then
			echo "winget"
		else
			echo "msys2"
		fi
		;;
	*)
		printf "error: unsupported OS '%s'\n" "${os}" >&2
		return 1
		;;
	esac

}

# ---------------------------------------------------------------------------
# get-pkg-version
# ---------------------------------------------------------------------------
get-pkg-version() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: get-pkg-version PM PKG

		  Print the installed version of PKG using package manager PM.
		  Prints nothing (not an error) if the package is not installed.

		Options:
		  -h  Show this message and exit.

		Arguments:
		  PM   Package manager name: apt, pacman, brew, dnf, zypper, apk,
		       msys2, winget.
		  PKG  Package name as known to the package manager.

		Examples:
		  get-pkg-version apt curl
		  get-pkg-version pacman bash
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	local pm="${1:-}" pkg="${2:-}" out
	case "${pm}" in
	pacman | msys2)
		out=$(pacman -Q "${pkg}" 2>/dev/null) || true
		if [[ -n "${out}" ]]; then printf '%s\n' "${out#* }"; fi
		;;
	apt)
		dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null || true
		;;
	brew)
		out=$(brew list --versions "${pkg}" 2>/dev/null) || true
		if [[ -n "${out}" ]]; then printf '%s\n' "${out#* }"; fi
		;;
	dnf | zypper)
		if rpm -q "${pkg}" &>/dev/null; then
			out=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "${pkg}" 2>/dev/null) || true
			[[ -n "${out}" ]] && printf '%s\n' "${out}"
		fi
		;;
	apk)
		out=$(apk info "${pkg}" 2>/dev/null | head -1) || true
		if [[ -n "${out}" ]]; then
			local name="${out%% *}"
			printf '%s\n' "${name#"${pkg}"-}"
		fi
		;;
	winget)
		local _w
		_w="$(winget-bin)" || return 0
		# winget.exe writes CRLF, which would otherwise ride along on the
		# version and compare unequal to every string it should match.
		#
		# The Name column contains spaces, so the version is not a fixed
		# field number: it is the token AFTER the one that equals the id.
		# Passed through ENVIRON rather than -v, which processes escape
		# sequences in the assignment.
		out=$("${_w}" list --id "${pkg}" --exact --disable-interactivity \
			2>/dev/null | tr -d '\r') || true
		[ -n "${out}" ] || return 0
		printf '%s\n' "${out}" | _pkg_id="${pkg}" awk \
			'{for (i = 1; i <= NF; i++) if ($i == ENVIRON["_pkg_id"]) {
				print $(i + 1); exit
			}}'
		;;
	*)
		printf "error: unknown package manager '%s'\n" "${pm}" >&2
		return 1
		;;
	esac

}
