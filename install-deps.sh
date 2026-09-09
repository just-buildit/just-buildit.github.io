#!/bin/bash
# ############################################################################
# EXECUTABLE: install-deps.sh                                                #
# PACKAGE: just-bashit version 0.5.1                                         #
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
SUDO_MODE="auto"
PROXY_URL=""
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
	  Input resolution: DEPS_FILE arg > bootstrap.toml > stdin.
	  (jb-deps.toml and jb.toml are still read, and deprecated.)

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

	  Privilege escalation is DERIVED, not assumed: sudo is used only when
	  the manager needs root, the caller is not already root, and sudo is
	  on PATH. A root CI container therefore needs no flag and no sudo
	  package. --sudo / --no-sudo force it either way. `cmd` arrays are
	  still run verbatim — leave sudo out of them and they work in both.

	  Proxies come from the standard environment variables (http_proxy,
	  https_proxy, all_proxy, no_proxy, and their uppercase spellings), or
	  from --proxy. Every supported manager fetches over libcurl or reads
	  those names directly, so they are all that is needed — but sudo
	  RESETS the environment, so they are re-applied explicitly on the far
	  side of it rather than relying on the sudoers env_keep list.

	  Default groups: all groups found in the file. To restrict defaults,
	  set groups = [...] under [tools.install-deps] in bootstrap.toml.

	Options:
	  -h / --help              Show this message and exit.
	  -n / --dry-run           Print commands without executing them.
	  -v / --verbose           Print section, groups, and packages before acting.
	  -s / --section SECTION   Override auto-detected package manager.
	  -g / --groups  GROUP     Comma-separated groups to install (overrides all
	                           defaults; e.g. -g runtime or -g runtime,dev).
	       --no-sudo           Never prefix sudo (root containers, CI images
	                           with no sudo package installed).
	       --sudo              Always prefix sudo, even when already root.
	       --proxy URL         Proxy for package downloads. Overrides the
	                           environment; passed through sudo. Applies to
	                           http_proxy/https_proxy and their uppercase
	                           spellings. all_proxy and no_proxy are taken
	                           from the environment when already set.
	       --template [PATH]   Write a scaffold deps.toml to PATH (default: stdout).

	Arguments:
	  DEPS_FILE  Path to TOML file. Omit to auto-discover bootstrap.toml.
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
	--no-sudo)
		SUDO_MODE="no"
		shift
		;;
	--sudo)
		SUDO_MODE="yes"
		shift
		;;
	--proxy)
		PROXY_URL="${2:?Option $1 requires an argument.}"
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

# Every proxy variable this script knows how to carry. Both spellings are
# listed because the managers disagree: apt, apk and libcurl read the
# lowercase names, Homebrew's Ruby reads the uppercase ones, and a machine
# that has only ever been used interactively usually has just one of them.
# An array, not a string: this script runs under IFS=$'\n\t', so a
# space-separated list would expand as one long word.
_PROXY_VARS=(
	http_proxy https_proxy all_proxy no_proxy
	HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
)

# ---------------------------------------------------------------------------
# _resolve_proxy: settle the proxy environment once, for every group.
#
# --proxy sets the http/https names in both spellings; all_proxy and no_proxy
# are only ever carried through from the environment, since a single URL says
# nothing about which hosts to bypass.
#
# The variables are exported here so that verbatim `cmd` arrays inherit them
# too — a cmd is not rewritten, but it does run in this process's environment.
# _PROXY_ENV then holds the same values as NAME=VALUE arguments, because sudo
# resets the environment and would otherwise drop every one of them. That is
# the actual reason `http_proxy=... make install-deps` appears to be ignored
# today, and it is not fixable from the caller's side.
# ---------------------------------------------------------------------------
_PROXY_ENV=()
_resolve_proxy() {
	local _v _name

	if [ -n "${PROXY_URL}" ]; then
		export http_proxy="${PROXY_URL}"
		export https_proxy="${PROXY_URL}"
		export HTTP_PROXY="${PROXY_URL}"
		export HTTPS_PROXY="${PROXY_URL}"
	fi

	# A no_proxy on its own describes exceptions to a proxy that is not
	# configured, so it is not worth wrapping any command in `env` for.
	local _have=0
	for _name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
		_v="${!_name:-}"
		[ -n "${_v}" ] && _have=1
	done
	[ "${_have}" -eq 0 ] && return 0

	for _name in "${_PROXY_VARS[@]}"; do
		_v="${!_name:-}"
		[ -z "${_v}" ] && continue
		export "${_name}=${_v}"
		_PROXY_ENV+=("${_name}=${_v}")
	done
}

# ---------------------------------------------------------------------------
# _resolve_prefix: decide once what every install command is prefixed with.
#
# Sets _PREFIX — ONE declaration, read by both the dry-run printer and the
# executor in _run, so what -n prints is exactly what would have run. It holds
# the sudo binary, if any, followed by `env NAME=VALUE ...` when a proxy is in
# play, in that order: the assignments have to land on the far side of sudo to
# survive its env_reset.
#
# The sudo half is what lets a single bootstrap.toml serve a workstation
# (unprivileged, sudo present) and a CI container (already root, no sudo
# package installed) with no flag and no second package list. brew is exempt
# on purpose: Homebrew refuses to run under sudo and manages its own prefix,
# so it never gets one even with --sudo.
# ---------------------------------------------------------------------------
_PREFIX=()
_resolve_prefix() {
	local section="$1"
	local sudo_bin=""

	if [ "${section}" != "brew" ]; then
		case "${SUDO_MODE}" in
		no) ;;
		yes)
			sudo_bin="sudo"
			;;
		*)
			if [ "$(id -u)" -eq 0 ]; then
				:
			elif command -v sudo >/dev/null 2>&1; then
				sudo_bin="sudo"
			else
				# Not root and no sudo: run bare and let the package manager
				# report the permission failure itself. Guessing a different
				# escalation tool here would only hide the real cause.
				printf 'warning: not root and sudo not found; running %s\n' \
					"${section} unprivileged" >&2
			fi
			;;
		esac
	fi

	_PREFIX=()
	[ -n "${sudo_bin}" ] && _PREFIX+=("${sudo_bin}")
	if [ "${#_PROXY_ENV[@]}" -gt 0 ]; then
		_PREFIX+=("env")
		_PREFIX+=("${_PROXY_ENV[@]}")
	fi
}

# ---------------------------------------------------------------------------
# _run: print (dry run) or execute one install command, prefix included.
# ---------------------------------------------------------------------------
_run() {
	if [ "${DRY_RUN}" -eq 1 ]; then
		if [ "${#_PREFIX[@]}" -gt 0 ]; then
			(
				IFS=' '
				echo "${_PREFIX[*]} $*"
			)
		else
			(
				IFS=' '
				echo "$*"
			)
		fi
		return
	fi
	if [ "${#_PREFIX[@]}" -gt 0 ]; then
		"${_PREFIX[@]}" "$@"
	else
		"$@"
	fi
}

# ---------------------------------------------------------------------------
# _do_install: run or print the install command for the detected section.
# ---------------------------------------------------------------------------
_do_install() {
	local section="$1"
	shift
	_resolve_prefix "${section}"
	case "${section}" in
	apt)
		_run apt-get update
		_run apt-get install -y --no-install-recommends "$@"
		;;
	pacman)
		_run pacman -Sy --needed --noconfirm "$@"
		;;
	brew)
		_run brew install "$@"
		;;
	dnf)
		_run dnf install -y "$@"
		;;
	zypper)
		_run zypper install -y "$@"
		;;
	apk)
		_run apk add "$@"
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

# Manifest discovery: bootstrap.toml, then the deprecated jb-prefixed names.
# `jb` reads as just-buildit — the PEP 517 backend, which never opens this
# file — so the old name pointed at the wrong tool. Both legacy names are
# still read, and warn, because this script is fetched live from the CDN on
# every CI run: a hard cutover would break every repo that had not yet
# renamed, in the window between the publish and their rename.
_find_bootstrap_toml() {
	local _n
	for _n in bootstrap.toml jb-deps.toml jb.toml; do
		if [ -f "${_n}" ]; then
			if [ "${_n}" != "bootstrap.toml" ]; then
				printf 'warning: %s is deprecated, rename it to bootstrap.toml\n' \
					"${_n}" >&2
			fi
			printf '%s\n' "${_n}"
			return 0
		fi
	done
	return 1
}

# Slurp deps content: explicit file > discovered manifest > stdin.
if [ -n "${DEPS_FILE}" ]; then
	CONTENT=$(cat "${DEPS_FILE}")
elif _found=$(_find_bootstrap_toml); then
	CONTENT=$(cat "${_found}")
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

# Settled once, before any group runs: the proxy does not vary per group or
# per section, and exporting it here is what puts it in scope for verbatim
# `cmd` arrays as well as for the managers.
_resolve_proxy

_log "section:  ${SECTION}"
_log "groups:   ${GROUPS_STR}"
if [ "${#_PROXY_ENV[@]}" -gt 0 ]; then
	(
		IFS=' '
		_log "proxy:    ${_PROXY_ENV[*]}"
	)
fi

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
