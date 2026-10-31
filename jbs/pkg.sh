#!/bin/bash
# ############################################################################
# LIBRARY: pkg.sh                                                            #
# PACKAGE: just-bashit                                                       #
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
# _winget_installed BIN ID — is this exact id installed already?
#
# A `list` probe rather than a reading of the install's own exit code. winget
# returns HRESULTs and a shell sees only the low byte: `list` for an absent
# package returns 0x8A150014 and arrives as 20 — a value another tool would
# use for something else entirely, and nothing in the byte says which. That
# much was measured on 2026-09-20 against winget v1.29.290, where a present
# id exits 0 and an absent one exits 20. The 0/non-zero answer needs no
# decoding, which is why the probe reads it and the install's code is left
# alone.
# ---------------------------------------------------------------------------
_winget_installed() {
	"$1" list --id "$2" --exact --disable-interactivity >/dev/null 2>&1
}

# The flags every winget install carries (install-deps and install-uv), bare id or not: no prompt for an
# agreement or a source, so a run never stops to ask.
_WINGET_INSTALL_FLAGS=(
	--exact --source winget --silent --accept-package-agreements
	--accept-source-agreements --disable-interactivity
)

# ---------------------------------------------------------------------------
# The Visual Studio probe, shared by install-deps (which installs a
# vs_requires workload and decides the outcome by it, #67) and
# setup-system's installed report (which reports each vs_requires id by it,
# #180): one probe, so the two cannot disagree about what is installed.
# ---------------------------------------------------------------------------

# _powershell_bin -- Windows PowerShell, by either spelling (see winget-bin
# for why both are tried).
_powershell_bin() {
	local _b
	for _b in powershell powershell.exe; do
		if command -v "${_b}" >/dev/null 2>&1; then
			printf '%s\n' "${_b}"
			return 0
		fi
	done
	return 1
}

# _win_path LOCAL / _local_path WINDOWS -- translate a path across the
# boundary: wslpath under WSL, cygpath under MSYS2, Cygwin and Git Bash.
_win_path() {
	if command -v wslpath >/dev/null 2>&1; then
		wslpath -w "$1"
	else
		cygpath -w "$1"
	fi
}
_local_path() {
	if command -v wslpath >/dev/null 2>&1; then
		wslpath -u "$1"
	else
		cygpath -u "$1"
	fi
}

# _vs_installer_dir -- the Visual Studio Installer directory, which holds
# vswhere.exe and setup.exe, as a local path. It is
# %ProgramFiles(x86)%\Microsoft Visual Studio\Installer on every install;
# the variable is read through PowerShell because a shell cannot name it
# (parentheses are not legal in a variable name). JB_VS_INSTALLER
# overrides, set to a directory of stubs for a test.
_vs_installer_dir() {
	local _ps _raw
	if [ -n "${JB_VS_INSTALLER+x}" ]; then
		printf '%s\n' "${JB_VS_INSTALLER}"
		return 0
	fi
	_ps="$(_powershell_bin)" || return 1
	# shellcheck disable=SC2016  # PowerShell expands it, not this shell
	_raw="$("${_ps}" -NoProfile -NonInteractive \
		-Command '${env:ProgramFiles(x86)}' 2>/dev/null | tr -d '\r\n')" ||
		_raw=""
	[ -n "${_raw}" ] || return 1
	_local_path "${_raw}\\Microsoft Visual Studio\\Installer"
}

# _vswhere DIR ARGS... -- the first installationPath vswhere prints for
# ARGS over every product, or nothing. No vswhere is no instance.
_vswhere() {
	local _dir="$1" _l
	shift
	[ -f "${_dir}/vswhere.exe" ] || return 0
	while IFS= read -r _l; do
		_l="${_l%$'\r'}"
		if [ -n "${_l}" ]; then
			printf '%s\n' "${_l}"
			return 0
		fi
	done < <("${_dir}/vswhere.exe" -products '*' "$@" \
		-property installationPath 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# install-uv [-n]
#
# Install uv, the ONE way every just-bashit entry point does it: get-jb.sh,
# setup-system's tools step and jbx's Python runner all call this (#171).
#
# On Windows (a MINGW/MSYS/CYGWIN uname) with winget present, through winget
# (id astral-sh.uv). winget chooses the build for the MACHINE: on ARM64
# Windows it lists uv-aarch64-pc-windows-msvc.zip (measured 2026-10-31).
# astral's install.sh chooses from `uname -m` alone, with no override, and
# from x64 Git Bash -- an emulated process on ARM64 Windows -- that reads
# x86_64, so it installed an x64 uv that then ran emulated. Choosing the
# architecture is left to winget, so nothing here detects one.
#
# Everywhere else, and on Windows when winget is absent or fails, astral's
# install.sh. It needs awk (a minimal Debian 13 WSL image has none) and
# curl, and is refused with the reason when either is missing.
#
# Prints the directory uv is in on stdout, and only that; the installers'
# own output goes to stderr. winget links a portable package into
# %LOCALAPPDATA%\Microsoft\WinGet\Links and adds that to the USER PATH, which
# reaches new shells and not the running one -- so the caller, which knows
# whether it can change its own PATH, decides what to do with the directory.
#
# -n prints the command that would run, and runs nothing.
#
# Example:
#   dir="$(install-uv)" && PATH="${dir}:${PATH}"
# ---------------------------------------------------------------------------
_UV_WINGET_ID="astral-sh.uv"
_UV_INSTALL_SH="https://astral.sh/uv/install.sh"

# _winget_links_dir -- where winget links a portable package's executables,
# as a path this shell can open. Read from LOCALAPPDATA, which Git Bash and
# MSYS2 inherit from Windows.
_winget_links_dir() {
	local base="${LOCALAPPDATA:-}"
	[ -n "${base}" ] || return 1
	if command -v cygpath >/dev/null 2>&1; then
		base="$(cygpath -u "${base}")" || return 1
	fi
	printf '%s\n' "${base}/Microsoft/WinGet/Links"
}

# _uv_dir_in DIR [last] -- print the directory uv resolves to with DIR
# added to PATH -- first, or last with `last` -- or return 1. A resolution
# rather than a test for DIR/uv: Git Bash finds uv.exe as `uv`, and astral's
# installer honours UV_INSTALL_DIR, so DIR is only where it USUALLY lands.
_uv_dir_in() {
	local p search="${1}:${PATH}"
	[ "${2:-}" = last ] && search="${PATH}:${1}"
	p="$(PATH="${search}" command -v uv 2>/dev/null)" || return 1
	printf '%s\n' "${p%/*}"
}

install-uv() {
	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: install-uv [-n]

		  Install uv: through winget (astral-sh.uv) on Windows, which picks
		  the machine's native build; through astral's install.sh elsewhere,
		  or when winget is absent or fails. Prints the directory uv is in.

		Options:
		  -n  Print the command that would run, and run nothing.
		  -h  Show this message and exit.
	EOF

	local dry=0 OPTARG="" OPTIND=0 option
	while getopts ":nh" option; do
		case $option in
		n) dry=1 ;;
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}" >&2
			echo "${HELP}" >&2
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	local os _w links dir tmp
	os="${JB_UNAME_S:-$(uname -s)}"
	case "${os}" in
	MINGW* | MSYS* | CYGWIN*)
		if _w="$(winget-bin)"; then
			if [ "${dry}" -eq 1 ]; then
				# IFS set here: setup-system sources this under IFS=$'\n\t',
				# which would join the flags one per line.
				(
					IFS=' '
					printf '%s install --id %s %s\n' "${_w}" \
						"${_UV_WINGET_ID}" "${_WINGET_INSTALL_FLAGS[*]}"
				)
				return 0
			fi
			if links="$(_winget_links_dir)" &&
				{ _winget_installed "${_w}" "${_UV_WINGET_ID}" ||
					"${_w}" install --id "${_UV_WINGET_ID}" \
						"${_WINGET_INSTALL_FLAGS[@]}" >&2; } &&
				dir="$(_uv_dir_in "${links}")"; then
				printf '%s\n' "${dir}"
				return 0
			fi
			echo "install-uv: winget did not install ${_UV_WINGET_ID};" \
				"falling back to ${_UV_INSTALL_SH}, whose build matches" \
				"this shell's architecture, not the machine's" >&2
		fi
		;;
	esac

	if [ "${dry}" -eq 1 ]; then
		printf 'curl -LsSf %s | sh\n' "${_UV_INSTALL_SH}"
		return 0
	fi
	if ! command -v curl >/dev/null 2>&1; then
		echo "install-uv: curl not installed -- cannot fetch ${_UV_INSTALL_SH}" >&2
		return 1
	fi
	# uv's installer runs awk; without it, it failed its own checksum
	# ("got:" empty) and still looked like it had run (2026-10-03).
	if ! command -v awk >/dev/null 2>&1; then
		echo "install-uv: uv's installer needs awk, and there is none here" >&2
		return 1
	fi
	# JB_NO_VERIFY=1 is how `jbx --no-verify` reaches this fetch: it
	# documents covering the nested uv install, and this is that download.
	local tls=()
	[ "${JB_NO_VERIFY:-0}" = 1 ] && tls=(--insecure)
	tmp="$(mktemp "${TMPDIR:-/tmp}/uv-install.XXXXXX")" || return 1
	if ! curl -LsSf --proto '=https' --tlsv1.2 "${tls[@]+"${tls[@]}"}" \
		-o "${tmp}" "${_UV_INSTALL_SH}" ||
		! sh "${tmp}" >&2; then
		rm -f "${tmp}"
		echo "install-uv: ${_UV_INSTALL_SH} failed" >&2
		return 1
	fi
	rm -f "${tmp}"
	if ! dir="$(_uv_dir_in "${HOME}/.local/bin" last)"; then
		echo "install-uv: ${_UV_INSTALL_SH} ran, but no uv can be found" >&2
		return 1
	fi
	printf '%s\n' "${dir}"
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
