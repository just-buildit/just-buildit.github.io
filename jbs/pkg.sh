#!/bin/bash
# ############################################################################
# LIBRARY: pkg.sh                                                            #
# PACKAGE: just-bashit version 0.2.0                                        #
# ############################################################################
# Package manager detection and version querying.                            #
# ############################################################################

(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

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
		  One of: apt, pacman, brew, dnf, zypper, apk, msys2.

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

	local os
	os="$(uname -s)"
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
		echo "msys2"
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
		  PM   Package manager name: apt, pacman, brew, dnf, zypper, apk, msys2.
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
	*)
		printf "error: unknown package manager '%s'\n" "${pm}" >&2
		return 1
		;;
	esac

}
