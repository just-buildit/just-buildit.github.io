#!/bin/bash
# ############################################################################
# EXECUTABLE: install-deps.sh                                                #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################
set -euo pipefail
IFS=$'\n\t'

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_SCRIPT_DIR}/toml.sh"
# shellcheck source=/dev/null
source "${_SCRIPT_DIR}/pkg.sh"

DRY_RUN=0
VERBOSE=0
SECTION_OVERRIDE=""
GROUPS_STR=""
GROUPS_EXPLICIT=0
TEMPLATE=0
TEMPLATE_PATH="-"

read -r -d '' HELP <<-'EOF' || true
	Usage: install-deps.sh [OPTIONS] [DEPS_FILE]

	  Install system packages for the detected OS from a declarative TOML file.
	  Auto-detects the package manager from the OS. By default installs ALL
	  groups defined in the file.
	  Input resolution: DEPS_FILE arg > jb-deps.toml > jb.toml > stdin.

	  Section format — standard install:

	    [GROUP.PACKAGE_MANAGER]
	    packages = ["pkg1", "pkg2"]

	  Section format — custom command (escape hatch, overrides packages):

	    [GROUP.PACKAGE_MANAGER]
	    cmd = ["sudo", "apt-get", "install", "-y", "pkg=1.2.3"]

	  Examples:

	    [runtime.pacman]
	    packages = ["zeromq", "fftw"]

	    [dev.apt]
	    packages = ["build-essential", "cmake"]

	    [pinned.apt]
	    cmd = ["apt-get", "install", "-y", "libzmq3-dev=4.3.4-1"]

	  Supported package managers: apt, pacman, brew, dnf, zypper, apk, msys2.

	  Default groups: all groups found in the file. To restrict defaults,
	  set groups = [...] under [tools.install-deps] in jb.toml.

	Options:
	  -h / --help              Show this message and exit.
	  -n / --dry-run           Print commands without executing them.
	  -v / --verbose           Print section, groups, and packages before acting.
	  -s / --section SECTION   Override auto-detected package manager.
	  -g / --groups  GROUP     Comma-separated groups to install (overrides all
	                           defaults; e.g. -g runtime or -g runtime,dev).
	       --template [PATH]   Write a scaffold deps.toml to PATH (default: stdout).

	Arguments:
	  DEPS_FILE  Path to TOML file. Omit to auto-discover jb-deps.toml or jb.toml.
EOF

# ---------------------------------------------------------------------------
# Argument parsing — manual loop to support both short and long options.
# ---------------------------------------------------------------------------
DEPS_FILE=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		echo "${HELP}"
		exit 0
		;;
	-n | --dry-run)
		DRY_RUN=1
		shift
		;;
	-v | --verbose)
		VERBOSE=1
		shift
		;;
	-s | --section)
		SECTION_OVERRIDE="${2:?Option $1 requires an argument.}"
		shift 2
		;;
	-g | --groups)
		GROUPS_STR="${2:?Option $1 requires an argument.}"
		GROUPS_EXPLICIT=1
		shift 2
		;;
	--template)
		TEMPLATE=1
		if [[ $# -gt 1 && "${2}" != -* ]]; then
			TEMPLATE_PATH="${2}"
			shift 2
		else
			TEMPLATE_PATH="-"
			shift
		fi
		;;
	-*)
		echo "Invalid option: $1"
		echo "${HELP}"
		exit 1
		;;
	*)
		DEPS_FILE="$1"
		shift
		;;
	esac
done

# ---------------------------------------------------------------------------
# _log: print to stderr when verbose is on.
# ---------------------------------------------------------------------------
_log() { [[ ${VERBOSE} -eq 1 ]] && echo "$*" >&2 || true; }

# ---------------------------------------------------------------------------
# _template: emit a scaffold deps.toml to stdout or a file.
# ---------------------------------------------------------------------------
_template() {
	local dest="${1}"
	if [[ "${dest}" == "-" ]]; then
		cat "${_SCRIPT_DIR}/template.toml"
	else
		cat "${_SCRIPT_DIR}/template.toml" >"${dest}"
		echo "wrote ${dest}" >&2
	fi
}

# ---------------------------------------------------------------------------
# _do_install: run or print the install command for the detected section.
# ---------------------------------------------------------------------------
_do_install() {
	local section="$1"
	shift
	case "${section}" in
	apt)
		if [ "${DRY_RUN}" -eq 1 ]; then
			echo "sudo apt-get update"
			(
				IFS=' '
				echo "sudo apt-get install -y --no-install-recommends $*"
			)
			return
		fi
		sudo apt-get update
		sudo apt-get install -y --no-install-recommends "$@"
		;;
	pacman)
		if [ "${DRY_RUN}" -eq 1 ]; then
			(
				IFS=' '
				echo "sudo pacman -Sy --needed --noconfirm $*"
			)
			return
		fi
		sudo pacman -Sy --needed --noconfirm "$@"
		;;
	brew)
		if [ "${DRY_RUN}" -eq 1 ]; then
			(
				IFS=' '
				echo "brew install $*"
			)
			return
		fi
		brew install "$@"
		;;
	dnf)
		if [ "${DRY_RUN}" -eq 1 ]; then
			(
				IFS=' '
				echo "sudo dnf install -y $*"
			)
			return
		fi
		sudo dnf install -y "$@"
		;;
	zypper)
		if [ "${DRY_RUN}" -eq 1 ]; then
			(
				IFS=' '
				echo "sudo zypper install -y $*"
			)
			return
		fi
		sudo zypper install -y "$@"
		;;
	apk)
		if [ "${DRY_RUN}" -eq 1 ]; then
			(
				IFS=' '
				echo "sudo apk add $*"
			)
			return
		fi
		sudo apk add "$@"
		;;
	msys2)
		# msys2 is Windows — always print instructions, never run.
		echo "Windows/MSYS2: open a UCRT64 shell and run:"
		(
			IFS=' '
			echo "  pacman -S $*"
		)
		exit 0
		;;
	*)
		echo "error: unknown section '${section}'" >&2
		exit 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ ${TEMPLATE} -eq 1 ]]; then
	_template "${TEMPLATE_PATH}"
	exit 0
fi

# Slurp deps content: explicit file > jb-deps.toml > jb.toml > stdin.
if [ -n "${DEPS_FILE}" ]; then
	CONTENT=$(cat "${DEPS_FILE}")
elif [ -f "jb-deps.toml" ]; then
	CONTENT=$(cat "jb-deps.toml")
elif [ -f "jb.toml" ]; then
	CONTENT=$(cat "jb.toml")
else
	CONTENT=$(cat)
fi

# Resolve groups: explicit -g > [tools.install-deps].groups in toml > all.
if [[ ${GROUPS_EXPLICIT} -eq 0 ]]; then
	_toml_g=$(printf '%s\n' "${CONTENT}" | toml_get_tool_groups "install-deps")
	if [[ -n "${_toml_g}" ]]; then
		GROUPS_STR="${_toml_g}"
	else
		GROUPS_STR=$(printf '%s\n' "${CONTENT}" | toml_discover_groups)
	fi
fi

SECTION="${SECTION_OVERRIDE:-$(get-pkg-mgr)}"

_log "section:  ${SECTION}"
_log "groups:   ${GROUPS_STR}"

# Process each group: cmd wins over packages; each runs independently.
_any=0
while IFS= read -r _group; do
	[ -z "${_group}" ] && continue

	_cmd=()
	while IFS= read -r _c; do _cmd+=("${_c}"); done \
		< <(printf '%s\n' "${CONTENT}" | toml_get_cmd "${_group}" "${SECTION}")

	if [ "${#_cmd[@]}" -gt 0 ]; then
		_any=1
		(
			IFS=' '
			_log "cmd: ${_cmd[*]}"
		)
		if [ "${DRY_RUN}" -eq 1 ]; then
			(
				IFS=' '
				echo "${_cmd[*]}"
			)
		else
			"${_cmd[@]}"
		fi
		continue
	fi

	_pkgs=()
	while IFS= read -r _p; do _pkgs+=("${_p}"); done \
		< <(printf '%s\n' "${CONTENT}" | toml_get_packages "${_group}" "${SECTION}")
	[ "${#_pkgs[@]}" -eq 0 ] && continue
	_any=1
	(
		IFS=' '
		_log "packages: ${_pkgs[*]}"
	)
	_do_install "${SECTION}" "${_pkgs[@]}"
done < <(tr ',' '\n' <<<"${GROUPS_STR}")
unset _group _cmd _pkgs _p _c

if [ "${_any}" -eq 0 ]; then
	echo "error: no packages or cmd found for group(s) '${GROUPS_STR}'" \
		"section '${SECTION}' in deps file" >&2
	exit 1
fi
