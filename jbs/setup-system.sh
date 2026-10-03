#!/bin/bash
# ############################################################################
# EXECUTABLE: setup-system.sh                                                #
# PACKAGE: just-bashit                                                       #
# ############################################################################
# One command to take a freshly installed machine to a working one: system   #
# packages, shell configuration, ssh, git defaults, and dev tooling. Every   #
# step is idempotent — re-running it is how you upgrade, not a mistake.      #
# ############################################################################
set -euo pipefail
IFS=$'\n\t'

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pages CDN mirror of src/just_bashit/ — used only when a sibling asset is
# missing, i.e. when this script was fetched standalone by jbx.
_JBS_BASE="${JB_JBS_BASE:-https://just-buildit.github.io/jbs}"

# Order matters: packages first (later steps want git, curl and ssh), shell
# before ssh (the agent lives in the shell config), tools and pwsh before
# claude. pwsh comes after deps because it downloads with curl and unpacks
# with tar, both of which the deps step is what puts on a bare machine.
# Kept as an array as well as a string because IFS is newline+tab here, so
# a space-separated string does not word-split.
_STEPS_ALL=(deps shell ssh sshd git tools pwsh claude)
_STEPS_ALL_STR="deps shell ssh sshd git tools pwsh claude"

# Steps that run only when named with -s or in bootstrap.toml. sshd opens a
# listening port on the machine, which is not something a default run gets
# to decide on the user's behalf.
_STEPS_OPT_IN_STR="sshd"

DRY_RUN=0
VERBOSE=0
ASSUME_YES=0
STEPS_STR=""
STEPS_EXPLICIT=0
SKIP_STR=""
PREFIX="${JB_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/just-bashit}"
KEY_NAME=""
SSHD_GITHUB_USER=""
SSHD_ALLOW=""
TEMPLATE=""
TEMPLATE_PATH="-"

read -r -d '' HELP <<-'EOF' || true
	Usage: setup-system.sh [OPTIONS]

	  Configure a fresh machine. Runs every step below unless told otherwise,
	  and every step is safe to re-run — nothing is duplicated or clobbered.

	Steps:
	  deps    Install a baseline toolchain (C compiler, make, cmake,
	          pkg-config, git, curl, ssh), then the packages of any
	          bootstrap.toml in the current directory (delegates to
	          install-deps).
	  shell   Install the opinionated bash configuration to
	          ~/.config/just-bashit/{bashrc,profile}.sh and add one source
	          line to ~/.bashrc and ~/.profile. Your files stay yours.
	  ssh     Ensure ~/.ssh permissions and an ed25519 key named after this
	          host; print the public key to register with GitHub.
	  sshd    Windows only (WSL or native MSYS2 / Git Bash), and only
	          when asked for (-s sshd): run Windows' OpenSSH server as a
	          boot-time service -- key-only, keys from
	          github.com/<user>.keys, pwsh.exe as the login shell -- so
	          the machine is reachable over ssh even when WSL is not
	          running. Raises one UAC prompt on the Windows desktop.
	  git     Set global git defaults that are not already set. An unset
	          user.name / user.email comes from GIT_AUTHOR_NAME /
	          GIT_AUTHOR_EMAIL, else is asked for at a terminal.
	  tools   Install uv if missing; install pre-commit hooks when the
	          current directory is a repo with .pre-commit-config.yaml.
	  pwsh    Install PowerShell 7 and the PSScriptAnalyzer module, so
	          .ps1 files can be linted here. Linux and macOS only.
	  claude  Install Claude Code if the claude command is missing.

	Options:
	  -h / --help                Show this message and exit.
	  -n / --dry-run             Print what would happen; change nothing.
	  -v / --verbose             Print extra detail.
	  -y / --yes                 Never prompt. Generates the ssh key with an
	                             EMPTY passphrase — see the docs first.
	  -s / --steps STEPS         Comma-separated steps to run (overrides the
	                             default set), e.g. -s shell,ssh
	  -x / --skip STEPS          Comma-separated steps to leave out.
	       --prefix DIR          Config directory to install into
	                             (default: ~/.config/just-bashit).
	       --key-name NAME       ssh key filename (default: this hostname).
	       --github-user NAME    sshd: authorize github.com/NAME.keys
	                             (default: the account gh is signed in to).
	       --sshd-allow ADDRS    sshd: comma-separated addresses the
	                             firewall admits to port 22 (default: any),
	                             e.g. 100.64.0.0/10,fd7a:115c:a1e0::/48
	                             for a Tailscale tailnet only.
	       --template [PATH]     Write the bashrc template to PATH (or stdout).
	       --template-profile [PATH]
	                             Write the profile template to PATH (or stdout).

	Default steps: all of them except sshd. To restrict the default set, declare
	steps = [...] under [tools.setup-system] in bootstrap.toml.

	Examples:
	  setup-system.sh --dry-run           # see the whole plan, touch nothing
	  setup-system.sh -s shell            # just the bash configuration
	  setup-system.sh -x claude,deps      # everything except those two
EOF

# ---------------------------------------------------------------------------
# Argument parsing — manual loop to support both short and long options.
# ---------------------------------------------------------------------------
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
	-y | --yes)
		ASSUME_YES=1
		shift
		;;
	-s | --steps)
		STEPS_STR="${2:?Option $1 requires an argument.}"
		STEPS_EXPLICIT=1
		shift 2
		;;
	-x | --skip)
		SKIP_STR="${2:?Option $1 requires an argument.}"
		shift 2
		;;
	--prefix)
		PREFIX="${2:?Option $1 requires an argument.}"
		shift 2
		;;
	--key-name)
		KEY_NAME="${2:?Option $1 requires an argument.}"
		shift 2
		;;
	--github-user)
		SSHD_GITHUB_USER="${2:?Option $1 requires an argument.}"
		shift 2
		;;
	--sshd-allow)
		SSHD_ALLOW="${2:?Option $1 requires an argument.}"
		shift 2
		;;
	--template | --template-profile)
		case "$1" in
		--template) TEMPLATE="bashrc-template.sh" ;;
		*) TEMPLATE="profile-template.sh" ;;
		esac
		if [[ $# -gt 1 && "${2}" != -* ]]; then
			TEMPLATE_PATH="${2}"
			shift 2
		else
			TEMPLATE_PATH="-"
			shift
		fi
		;;
	*)
		echo "Invalid option: $1" >&2
		echo "${HELP}" >&2
		exit 1
		;;
	esac
done

# ---------------------------------------------------------------------------
# Output helpers. Progress goes to stdout; only trouble goes to stderr.
# ---------------------------------------------------------------------------
_say() { printf '%s\n' "$*"; }
_head() { printf '\n==> %s\n' "$*"; }
_info() { printf '    %s\n' "$*"; }
_warn() { printf '    warning: %s\n' "$*" >&2; }
_log() { [[ ${VERBOSE} -eq 1 ]] && printf '    %s\n' "$*" >&2 || true; }

# Records one "step: outcome" line per step for the closing summary.
_RESULTS=()
_result() { _RESULTS+=("$1"); }

# ---------------------------------------------------------------------------
# _run CMD... — execute, or print the command when --dry-run is set.
# ---------------------------------------------------------------------------
_run() {
	if [[ ${DRY_RUN} -eq 1 ]]; then
		(
			IFS=' '
			printf '    would run: %s\n' "$*"
		)
		return 0
	fi
	"$@"
}

# ---------------------------------------------------------------------------
# _have CMD — is CMD on PATH?
# ---------------------------------------------------------------------------
_have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# _asset NAME — path to a readable copy of a sibling file, fetching it from
# the Pages CDN when this script is running standalone from jbx's cache.
#
# The download lands next to this script whenever that directory is writable
# (it is, inside the cache) so the asset's own siblings resolve too.
# ---------------------------------------------------------------------------
# Retry flags the curl at hand understands. `--retry-all-errors` needs curl
# >= 7.71; RHEL/Oracle/Rocky/Alma 8 ship 7.61, where the unknown flag aborts
# the fetch. `--retry`/`--retry-connrefused` still ride out throttling there;
# the all-errors flag is added only where supported. Probed once. (Kept in sync
# with just-runit's copy — both fetch from the same Pages CDN.)
#
# Populated as an ARRAY, not a space-joined string: this file runs under the
# strict `IFS=$'\n\t'` set at the top, so an unquoted `$(...)` of a
# space-separated string would NOT word-split — curl would see the whole
# "--retry 3 --retry-connrefused ..." as one bogus option and abort every
# fetch. `"${_CURL_RETRY_OPTS[@]}"` expands to distinct args regardless of IFS.
_curl_retry_opts_init() {
	if [[ -z ${_CURL_RETRY_OPTS+x} ]]; then
		_CURL_RETRY_OPTS=(--retry 3 --retry-connrefused)
		if curl --retry-all-errors --help >/dev/null 2>&1; then
			_CURL_RETRY_OPTS+=(--retry-all-errors)
		fi
	fi
}

_asset() {
	local name="$1" dest
	if [[ -r "${_SCRIPT_DIR}/${name}" ]]; then
		printf '%s\n' "${_SCRIPT_DIR}/${name}"
		return 0
	fi
	if [[ -w ${_SCRIPT_DIR} ]]; then
		dest="${_SCRIPT_DIR}/${name}"
	else
		dest="$(mktemp "${TMPDIR:-/tmp}/jb-${name}.XXXXXX")"
	fi
	_log "fetching ${_JBS_BASE}/${name}"
	_curl_retry_opts_init
	if ! curl -sSL --fail "${_CURL_RETRY_OPTS[@]}" --connect-timeout 30 \
		-o "${dest}" "${_JBS_BASE}/${name}"; then
		rm -f "${dest}"
		echo "error: cannot obtain ${name} (no sibling copy, fetch failed)" >&2
		return 1
	fi
	printf '%s\n' "${dest}"
}

# The libraries this script sources, loaded through _asset: the sibling copy
# when there is one (a checkout, or jbx's co-fetch), else fetched from the
# mirror beside this script. A jbx install carries its own list of libraries
# to co-fetch and nothing updates it, so one older than a library -- windows.sh
# against a 0.4.1 jbx, measured on zen-ai445 -- would otherwise die here on a
# missing file (#75).
for _lib in toml.sh file.sh windows.sh; do
	_lib_path="$(_asset "${_lib}")" || exit 1
	# shellcheck source=/dev/null
	source "${_lib_path}"
done
unset _lib _lib_path

# ---------------------------------------------------------------------------
# _install_file SRC DEST — copy when the content differs, keeping a .bak of
# anything it replaces. Reports which of the three happened.
# ---------------------------------------------------------------------------
_install_file() {
	local src="$1" dest="$2"
	if [[ -r ${dest} ]] && cmp -s "${src}" "${dest}"; then
		_info "up to date: ${dest}"
		return 0
	fi
	if [[ -e ${dest} ]]; then
		_info "updating:   ${dest} (previous copy kept as ${dest##*/}.bak)"
		_run cp -p "${dest}" "${dest}.bak"
	else
		_info "creating:   ${dest}"
	fi
	_run cp "${src}" "${dest}"
	_run chmod 0644 "${dest}"
}

# ---------------------------------------------------------------------------
# _source_line FILE LINE — ensure FILE contains LINE exactly once.
#
# add-line (file.sh) does the idempotent append; this adds the dry-run path
# and a comment above the line on first write.
# ---------------------------------------------------------------------------
_source_line() {
	local file="$1" line="$2"
	if [[ -r ${file} ]] && grep -qxF "${line}" "${file}"; then
		_info "already sourced from ${file}"
		return 0
	fi
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would append to ${file}: ${line}"
		return 0
	fi
	_info "appending source line to ${file}"
	add-line '' "${file}" >/dev/null
	add-line '# just-bashit — configuration installed by setup-system' \
		"${file}" >/dev/null
	add-line "${line}" "${file}" >/dev/null
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

# deps — hand the project's deps file to install-deps.
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

# The toolchain every machine gets, whatever directory this runs from: a C
# compiler, make, cmake, pkg-config, and the git/curl/ssh the later steps
# lean on. Before this existed, deps read only a bootstrap.toml in the
# current directory, so the documented fresh-machine run -- from $HOME --
# installed nothing, and the first C build on a new box failed with no
# compiler at all.
#
# It is a manifest in bootstrap.toml's own format and goes through the same
# install-deps call as a project's, so there is one installer and one
# per-manager naming scheme, not a second list with its own rules. It lives
# in this file rather than beside it because the jbs Pages mirror copies
# only *.sh: a sibling .toml would never reach a standalone jbx run.
#
# Deliberately a toolchain and nothing more. Language runtimes and project
# libraries (python3-dev, numpy, rust) are a project's to declare, in its
# own bootstrap.toml, which this step still installs afterwards.
read -r -d '' _BASELINE_TOML <<-'EOF' || true
	[baseline.apt]
	packages = ["build-essential", "cmake", "pkg-config", "git", "curl", "ca-certificates", "openssh-client", "tar"]

	[baseline.pacman]
	packages = ["base-devel", "cmake", "pkgconf", "git", "curl", "openssh", "tar"]

	[baseline.dnf]
	packages = ["gcc", "make", "cmake", "pkgconf-pkg-config", "diffutils", "git", "curl", "openssh-clients", "tar"]

	[baseline.zypper]
	packages = ["gcc", "make", "cmake", "pkg-config", "diffutils", "git", "curl", "openssh", "tar"]

	[baseline.apk]
	packages = ["build-base", "cmake", "pkgconf", "bash", "git", "curl", "openssh-keygen", "tar"]

	# The compiler on macOS is the Xcode Command Line Tools, which brew itself
	# requires, so brew has only the build tools to add.
	[baseline.brew]
	packages = ["cmake", "pkg-config"]

	# Git Bash with no pacman (install-deps' winget section, #60). The
	# compiler is clang-cl, the toolchain just-makeit builds Windows with; it
	# also needs the MSVC Build Tools' C++ workload, which winget installs
	# only with an --override this manifest has no way to pass yet -- see
	# #67. Windows 10+ ships tar.exe and curl.exe itself.
	[baseline.winget]
	packages = ["Kitware.CMake", "Git.Git", "LLVM.LLVM"]

	[baseline.msys2]
	packages = ["mingw-w64-ucrt-x86_64-gcc", "mingw-w64-ucrt-x86_64-cmake", "make", "pkg-config", "git", "curl", "openssh"]
EOF

# _install_manifest INSTALLER FILE LABEL — one install-deps run over FILE,
# reported under LABEL. Returns install-deps' own status.
_install_manifest() {
	local installer="$1" file="$2" label="$3"
	local args=()
	[[ ${DRY_RUN} -eq 1 ]] && args+=("--dry-run")
	[[ ${VERBOSE} -eq 1 ]] && args+=("--verbose")
	_info "installing packages from ${label}"
	if bash "${installer}" "${args[@]+"${args[@]}"}" "${file}"; then
		return 0
	fi
	_warn "install-deps reported a failure for ${label}"
	return 1
}

step_deps() {
	_head "deps — system packages"

	local installer
	installer="$(_asset install-deps.sh)" || {
		_warn "install-deps.sh unavailable"
		_result "deps:    failed (install-deps.sh unavailable)"
		return 0
	}

	local baseline ok=1 done_list="baseline toolchain"
	baseline="$(mktemp "${TMPDIR:-/tmp}/jb-baseline.XXXXXX")"
	printf '%s\n' "${_BASELINE_TOML}" >"${baseline}"
	_install_manifest "${installer}" "${baseline}" "the baseline toolchain" ||
		ok=0
	rm -f "${baseline}"

	local deps_file=""
	deps_file="$(_find_bootstrap_toml || true)"
	if [[ -n ${deps_file} ]]; then
		_install_manifest "${installer}" "${deps_file}" "${deps_file}" || ok=0
		done_list="${done_list} + ${deps_file}"
	else
		_log "no bootstrap.toml in $(pwd) — baseline only"
	fi

	if [[ ${ok} -eq 1 ]]; then
		_result "deps:    ok (${done_list})"
	else
		_result "deps:    failed (${done_list})"
	fi
}

# shell — the bashrc/profile templates plus their one-line hooks.
step_shell() {
	_head "shell — bash configuration"

	local bashrc="${PREFIX}/bashrc.sh"
	local profile="${PREFIX}/profile.sh"

	_run mkdir -p "${PREFIX}" "${PREFIX}/bashrc.d"

	local src_bashrc src_profile
	src_bashrc="$(_asset bashrc-template.sh)" || {
		_result "shell:   failed (template unavailable)"
		return 0
	}
	src_profile="$(_asset profile-template.sh)" || {
		_result "shell:   failed (template unavailable)"
		return 0
	}

	_install_file "${src_bashrc}" "${bashrc}"
	_install_file "${src_profile}" "${profile}"

	# Written with $HOME unexpanded when the prefix is the default, so the
	# same line works in a home directory that later moves or is mounted
	# elsewhere. A custom --prefix is written literally.
	local rc_path pf_path
	if [[ ${PREFIX} == "${HOME}/"* ]]; then
		rc_path="\$HOME/${bashrc#"${HOME}"/}"
		pf_path="\$HOME/${profile#"${HOME}"/}"
	else
		rc_path="${bashrc}"
		pf_path="${profile}"
	fi

	_source_line "${HOME}/.bashrc" \
		"if [ -r \"${rc_path}\" ]; then . \"${rc_path}\"; fi"

	# ~/.profile covers login shells everywhere; bash prefers ~/.bash_profile
	# and ignores ~/.profile entirely when that file exists, which is the
	# default on macOS — so keep both in step when both are present.
	_source_line "${HOME}/.profile" \
		"if [ -r \"${pf_path}\" ]; then . \"${pf_path}\"; fi"
	if [[ -f "${HOME}/.bash_profile" ]]; then
		_source_line "${HOME}/.bash_profile" \
			"if [ -r \"${pf_path}\" ]; then . \"${pf_path}\"; fi"
	fi

	_info "customise by adding *.sh to ${PREFIX}/bashrc.d/"
	_info "apply now with: exec bash -l"
	_result "shell:   ok (${PREFIX})"
}

# ---------------------------------------------------------------------------
# _ssh_harden: strip group and other off everything in ~/.ssh that must not
# be readable by them.
#
# For a directory that arrived from somewhere unable to carry POSIX modes.
# rsync -a and tar both preserve permissions, so a Linux-to-Linux copy needs
# nothing; this is for the crossings where no copy command can help — a
# Windows filesystem under WSL (DrvFs has no modes and reports 0777), a FAT
# stick, a zip, or a git checkout, which records only the exec bit. ssh then
# refuses the key with UNPROTECTED PRIVATE KEY FILE and does not say how to
# fix it.
#
# `go-rwx` rather than a literal 0600, so this only ever TIGHTENS: a key
# already at 0400 keeps its 0400 instead of gaining owner-write, and running
# it twice changes nothing the second time.
#
# A private key is recognised by its PEM header rather than its name — a key
# with no matching .pub, or not called id_*, still has to be locked down.
# `read` is a builtin, so this adds nothing to the set of commands a
# PATH-restricted machine needs to reach this step.
#
# .pub files are left alone: they are public, and rewriting them would be
# churn for its own sake.
# ---------------------------------------------------------------------------
_ssh_harden() {
	local dir="$1" f name first

	# u+rwx as well here: a directory arriving at 0000 would otherwise stay
	# unusable, and ~/.ssh has to be enterable by its owner to be any use.
	_run chmod u+rwx,go-rwx "${dir}"

	for f in "${dir}"/* "${dir}"/.*; do
		[[ -e ${f} ]] || continue
		name="${f##*/}"
		[[ ${name} == "." || ${name} == ".." ]] && continue

		if [[ -d ${f} ]]; then
			_run chmod u+rwx,go-rwx "${f}"
			continue
		fi
		[[ -f ${f} ]] || continue

		case "${name}" in
		*.pub) continue ;;
		config | authorized_keys | authorized_keys2)
			_run chmod go-rwx "${f}"
			continue
			;;
		esac

		# Anything else is only touched if it actually IS a private key.
		first=""
		read -r first <"${f}" 2>/dev/null || true
		case "${first}" in
		-----BEGIN*PRIVATE\ KEY-----*) _run chmod go-rwx "${f}" ;;
		esac
	done
}

# ssh — directory permissions, then a key if the user has none.
step_ssh() {
	_head "ssh — agent keys"

	# Permissions and the existing-key check come first because neither needs
	# ssh-keygen: a machine with openssh-client absent but keys already synced
	# into place still wants its 0700, and still must not be told it is being
	# skipped. Only generation requires the binary.
	local dir="${HOME}/.ssh"
	_run mkdir -p "${dir}"
	_ssh_harden "${dir}"

	# Any private key with a matching .pub counts; a machine that already
	# has an identity does not need another one.
	local pub existing=0
	for pub in "${dir}"/*.pub; do
		[[ -r ${pub} ]] || continue
		[[ -r ${pub%.pub} ]] || continue
		existing=1
		_log "found key ${pub%.pub}"
	done

	if [[ ${existing} -eq 1 ]]; then
		_info "existing key(s) found in ${dir} — not generating another"
		_result "ssh:     ok (existing key)"
		return 0
	fi

	if ! _have ssh-keygen; then
		_info "ssh-keygen not installed — skipping key generation"
		_result "ssh:     skipped (no ssh-keygen)"
		return 0
	fi

	local name="${KEY_NAME}"
	if [[ -z ${name} ]]; then
		name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo id_ed25519)"
	fi
	local key="${dir}/${name}"

	_info "generating ed25519 key ${key}"
	if [[ ${ASSUME_YES} -eq 1 ]]; then
		_warn "--yes: creating the key with an EMPTY passphrase"
		_run ssh-keygen -q -t ed25519 -C "$(id -un)@${name}" \
			-f "${key}" -N ""
	else
		_info "you will be prompted for a passphrase (empty = no passphrase)"
		_run ssh-keygen -t ed25519 -C "$(id -un)@${name}" -f "${key}"
	fi

	if [[ ${DRY_RUN} -eq 0 && -r "${key}.pub" ]]; then
		# Still explicit: the sweep above ran before this key existed.
		_run chmod go-rwx "${key}"
		_say ""
		_info "public key — add it to GitHub:"
		_say ""
		cat "${key}.pub"
		_say ""
		_info "gh ssh-key add ${key}.pub --title '${name}'"
	fi
	_result "ssh:     ok (created ${key})"
}

# ---------------------------------------------------------------------------
# sshd — Windows' own OpenSSH server as a boot-time service, driven from WSL.
#
# An ssh server inside WSL2 dies with the WSL VM, and the VM stops on its own
# when idle or after a crash -- so the machine is unreachable at exactly the
# moments you need to reach it. Windows' sshd is a service that starts at
# boot whether or not WSL ever does, and `wsl` is one command away from it.
#
# The work is windows-sshd.ps1, which has to run elevated. This step copies
# it to the Windows temp directory (an elevated process cannot be relied on
# to read \\wsl.localhost paths), raises the UAC prompt with Start-Process
# -Verb RunAs, waits, and relays the script's log -- the elevated window is
# hidden, so without the log a failure would be invisible.
#
# It runs from WSL or from native Windows (MSYS2 / Git Bash); the two differ
# only in how a Windows path becomes a local one (wslpath, cygpath).
#
# Nothing is quoted across a process boundary. The elevated body is written
# to run.ps1 and the UAC hop to launch.ps1, both beside the copied script;
# each finds its neighbours through $PSScriptRoot, so no path is spliced
# into PowerShell, and powershell.exe gets only `-File launch.ps1` -- one
# plain argument. The alternative, a command string, crosses bash, the
# outer command line and Start-Process's argument list, and each has its
# own quoting rule (a bash quirk broke it on macOS, gh-69's CI).
# WaitForExit rather than Start-Process -Wait: in Windows PowerShell -Wait
# also waits for every descendant, and the MSI installs this triggers can
# leave one running -- an outer wait that then never returns.
# ---------------------------------------------------------------------------

# Overridable so the suite can run this on a Linux runner (as ssh-to-windows
# does): a WSL-only step tested only by hand is eventually not tested.
_PROC_VERSION="${JB_PROC_VERSION:-/proc/version}"

# _sshd_github_user — whose keys to authorize: --github-user, else the
# account gh is signed in to. Printed, or return 1 when neither is known.
_sshd_github_user() {
	local u="${SSHD_GITHUB_USER}"
	if [[ -z ${u} ]] && _have gh; then
		u="$(gh api user --jq .login 2>/dev/null || true)"
	fi
	[[ -n ${u} ]] || return 1
	printf '%s\n' "${u}"
}

step_sshd() {
	_head "sshd — Windows OpenSSH server, started at boot"

	# WSL, or native Windows under MSYS2 / Git Bash: the same Windows
	# service either way, reached through a different path translator.
	local topath
	_pwsh_uname_init
	if [[ -r ${_PROC_VERSION} ]] && grep -qi microsoft "${_PROC_VERSION}"; then
		topath=wslpath
	else
		case "${_UNAME_S}" in
		MINGW* | MSYS* | CYGWIN*) topath=cygpath ;;
		*)
			_info "not Windows — on Linux enable the distro's own sshd unit"
			_result "sshd:    skipped (not Windows)"
			return 0
			;;
		esac
	fi

	local ps_exe cmd_exe c
	ps_exe="$(win-exe powershell.exe)" || ps_exe=""
	cmd_exe="$(win-exe cmd.exe)" || cmd_exe=""
	for c in "${ps_exe:-powershell.exe}" "${cmd_exe:-cmd.exe}" "${topath}"; do
		if [[ ${c} != */* ]] && ! _have "${c}"; then
			_warn "${c} not found — this step drives Windows from here"
			_result "sshd:    skipped (no ${c})"
			return 0
		fi
	done
	# MSYS rewrites any argument that looks like a POSIX path before a
	# Windows program sees it: `cmd /c` would arrive as `cmd C:/`. Off for
	# every call below; WSL ignores both variables.
	local -x MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1

	local user
	if ! user="$(_sshd_github_user)"; then
		_warn "no GitHub user: pass --github-user NAME, or sign in to gh"
		_result "sshd:    skipped (no GitHub user)"
		return 0
	fi
	# Both values are spliced into a PowerShell command. Checked against what
	# they can legitimately contain, so neither can carry a quote into it.
	if [[ ! ${user} =~ ^[A-Za-z0-9-]+$ ]]; then
		_warn "not a GitHub user name: ${user}"
		_result "sshd:    failed (bad --github-user)"
		return 0
	fi
	if [[ -n ${SSHD_ALLOW} && ! ${SSHD_ALLOW} =~ ^[0-9A-Za-z.:/,-]+$ ]]; then
		_warn "not an address list: ${SSHD_ALLOW}"
		_result "sshd:    failed (bad --sshd-allow)"
		return 0
	fi

	local ps1
	if ! ps1="$(_asset windows-sshd.ps1)"; then
		_result "sshd:    failed (windows-sshd.ps1 unavailable)"
		return 0
	fi

	local wtemp
	wtemp="$( (
		cd /mnt/c 2>/dev/null || true
		"${cmd_exe}" /c 'echo %TEMP%' 2>/dev/null
	) | tr -d '\r\n')" || wtemp=""
	if [[ -z ${wtemp} ]]; then
		_warn "could not resolve the Windows %TEMP% through cmd.exe"
		_result "sshd:    failed (no %TEMP%)"
		return 0
	fi
	local wdir="${wtemp}\\jb-windows-sshd"
	local dir
	dir="$("${topath}" -u "${wdir}")"

	# The same PowerShell pin the pwsh step installs on Linux, so every
	# machine this sets up runs one release. Both values were checked above
	# to hold no quote. The list is joined through ${sq} rather than an
	# escaped quote in the replacement, whose meaning changed across bash
	# releases.
	local ps_args="-GitHubUser '${user}' -PwshVersion '${_PS_VER}'"
	if [[ -n ${SSHD_ALLOW} ]]; then
		local sq="'"
		ps_args="${ps_args} -RemoteAddress ${sq}${SSHD_ALLOW//,/${sq},${sq}}${sq}"
	fi

	# An elevated ssh session to this machine's own sshd, when one exists
	# (every run after a box's first): no UAC prompt, so nobody has to be at
	# the desktop, and the output streams back live (windows.sh says why).
	local chan=""
	chan="$(win-admin-channel)" || chan=""

	if [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would copy windows-sshd.ps1 to ${wdir}"
		if [[ -n ${chan} ]]; then
			_info "would run it over the admin ssh channel (${chan}), no UAC prompt:"
		else
			_info "would raise a UAC prompt and run, elevated:"
		fi
		_info "  windows-sshd.ps1 ${ps_args}"
		_result "sshd:    ok (dry run)"
		return 0
	fi

	mkdir -p "${dir}"
	cp "${ps1}" "${dir}/windows-sshd.ps1"
	rm -f "${dir}/log.txt"

	if [[ -n ${chan} ]]; then
		_info "running over the admin ssh channel (${chan}) -- no UAC prompt"
		# The script is named by the far end's own $env:TEMP -- the same
		# user, so the same directory -- rather than a Windows path spliced
		# into the command. The session survives the sshd restart the script
		# ends with (measured on yoga-x2p).
		local rc=0
		# WIN_SSH_OPTS comes from windows.sh; ps_args expands HERE on purpose
		# (it was checked above to hold no quote).
		# shellcheck disable=SC2154,SC2029
		ssh "${WIN_SSH_OPTS[@]}" "${chan}" \
			"& (Join-Path \$env:TEMP 'jb-windows-sshd\\windows-sshd.ps1') ${ps_args}" |
			tr -d '\r' || rc=$?
		if [[ ${rc} -eq 0 ]]; then
			_result "sshd:    ok (keys from github.com/${user}.keys, over ssh)"
		else
			_result "sshd:    failed (see above)"
		fi
		return 0
	fi
	# The elevated window is hidden, so its whole output goes to log.txt.
	cat >"${dir}/run.ps1" <<-EOF
		\$log = Join-Path \$PSScriptRoot 'log.txt'
		try {
		    & (Join-Path \$PSScriptRoot 'windows-sshd.ps1') ${ps_args} *>&1 |
		        Out-File -FilePath \$log -Encoding utf8
		    exit 0
		} catch {
		    \$_ | Out-File -FilePath \$log -Append -Encoding utf8
		    exit 1
		}
	EOF
	# Start-Process joins -ArgumentList with spaces, so the one path in it
	# is quoted; a Windows path cannot itself hold a double quote. A
	# declined UAC prompt is a NON-terminating error: without Stop the
	# script runs on to `exit $null.ExitCode`, which is exit 0 -- success.
	cat >"${dir}/launch.ps1" <<-'EOF'
		$ErrorActionPreference = 'Stop'
		$run = Join-Path $PSScriptRoot 'run.ps1'
		$p = Start-Process powershell.exe -Verb RunAs -PassThru -WindowStyle Hidden `
		    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$run`""
		$p.WaitForExit()
		exit $p.ExitCode
	EOF

	_info "approve the UAC prompt on the Windows desktop to continue"
	local rc=0
	(
		cd /mnt/c 2>/dev/null || true
		"${ps_exe}" -NoProfile -ExecutionPolicy Bypass -File "${wdir}\\launch.ps1"
	) || rc=$?

	if [[ -r "${dir}/log.txt" ]]; then
		# Out-File's utf8 in Windows PowerShell writes a BOM; drop it and the
		# CRs so the relayed lines read like the rest of this output.
		sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "${dir}/log.txt"
	fi
	if [[ ${rc} -eq 0 ]]; then
		_result "sshd:    ok (keys from github.com/${user}.keys)"
	elif [[ ! -r "${dir}/log.txt" ]]; then
		_warn "the elevated run did not start — was the UAC prompt declined?"
		_result "sshd:    failed (not elevated)"
	else
		_result "sshd:    failed (see the log above)"
	fi
}

# git — opinionated global defaults, none of which overwrite a choice the
# user has already made.
step_git() {
	_head "git — global defaults"

	if ! _have git; then
		_info "git not installed — skipping"
		_result "git:     skipped (no git)"
		return 0
	fi

	# key|value — a separator that cannot appear in a git config key.
	local pairs=(
		"init.defaultBranch|main"
		"pull.rebase|true"
		"rebase.autoStash|true"
		"push.default|simple"
		"push.autoSetupRemote|true"
		"fetch.prune|true"
		"diff.colorMoved|zebra"
		"color.ui|auto"
		"core.editor|${EDITOR:-vi}"
	)

	local pair key value current set_count=0
	for pair in "${pairs[@]}"; do
		key="${pair%%|*}"
		value="${pair#*|}"
		current="$(git config --global --get "${key}" 2>/dev/null || true)"
		if [[ -n ${current} ]]; then
			_log "${key} already set to ${current} — left alone"
			continue
		fi
		_info "git config --global ${key} ${value}"
		_run git config --global "${key}" "${value}"
		set_count=$((set_count + 1))
	done

	local who_count=0
	_git_identity user.name "${GIT_AUTHOR_NAME:-}" "your name" &&
		who_count=$((who_count + 1))
	_git_identity user.email "${GIT_AUTHOR_EMAIL:-}" "your email" &&
		who_count=$((who_count + 1))
	_result "git:     ok (${set_count} default(s) set, ${who_count} identity value(s) set)"
}

# _git_identity KEY FROM_ENV LABEL — set a global identity value that is
# absent, taking it from the environment or, failing that, from the person.
#
# A fresh machine with no identity is not neutral: tools that decide what a
# machine is FOR from `git config --global user.email` see nothing and quietly
# do nothing, and the first commit fails or goes out under a guessed
# `user@host` address. So an unset value is filled rather than left for later,
# in this order:
#
#   1. already set globally -> left alone, like every default above;
#   2. GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL set -> used as-is (git's own names
#      for these, so a CI job or provisioning script already exporting them
#      needs nothing new);
#   3. stdin is a terminal and --yes was not given -> asked; an empty answer
#      skips, because a blank identity is worse than none;
#   4. otherwise -> a warning naming the exact command, never a guess.
#
# Global, not per-repo: a per-repo identity still overrides it wherever one
# is set, so this only fills the gap no repo covers.
#
# Returns 0 when it set a value, 1 otherwise, so the caller can count.
_git_identity() {
	local key="$1" value="$2" label="$3" current
	current="$(git config --global --get "${key}" 2>/dev/null || true)"
	if [[ -n ${current} ]]; then
		_log "${key} already set to ${current} — left alone"
		return 1
	fi

	if [[ -z ${value} ]]; then
		if [[ ${ASSUME_YES} -eq 1 || ! -t 0 ]]; then
			_warn "${key} is not set — run: git config --global ${key} \"${label}\""
			return 1
		fi
		if [[ ${DRY_RUN} -eq 1 ]]; then
			_info "would ask for ${label} (git ${key} is not set)"
			return 1
		fi
		read -r -p "    git ${key} is not set — ${label} (empty to skip): " \
			value || true
		if [[ -z ${value} ]]; then
			_warn "${key} left unset"
			return 1
		fi
	fi

	_info "git config --global ${key} ${value}"
	_run git config --global "${key}" "${value}"
}

# tools — uv, then this repo's pre-commit hooks if that applies here.
step_tools() {
	_head "tools — dev bootstrap"

	if _have uv; then
		_info "uv already installed ($(uv --version 2>/dev/null || echo ok))"
	elif ! _have curl; then
		_warn "curl not installed — cannot install uv"
	else
		_info "installing uv"
		if [[ ${DRY_RUN} -eq 1 ]]; then
			_info "would run: curl -LsSf https://astral.sh/uv/install.sh | sh"
		else
			curl -LsSf https://astral.sh/uv/install.sh | sh
		fi
	fi

	if [[ -f .pre-commit-config.yaml && -d .git ]]; then
		_info "installing pre-commit hooks in $(pwd)"
		if _have pre-commit; then
			_run pre-commit install
		elif _have uv; then
			_run uv tool run pre-commit install
		else
			_warn "neither pre-commit nor uv available — hooks not installed"
		fi
	else
		_log "no .pre-commit-config.yaml in a git repo here — hooks skipped"
	fi

	_result "tools:   ok"
}

# ---------------------------------------------------------------------------
# pwsh — native PowerShell 7, plus the PSScriptAnalyzer module the .ps1 lint
# gate needs.
#
# Unix side only, for now: install-deps has a winget section (#60), but this
# step does not route through it yet (#59), so on Windows it reports that it
# skipped rather than pretending to have done something.
#
# A native interpreter is what removes the WSL path-translation problem
# wholesale: with pwsh on PATH, Linux paths are passed through untouched
# instead of being rewritten with `wslpath -w` for pwsh.exe.
#
# The version is PINNED so an upgrade is one you chose, not whatever was
# released this morning. Bump it here.
# ---------------------------------------------------------------------------
_PS_VER="7.6.6"
_PWSH_DIR="/opt/microsoft/powershell/7"
_PWSH_LINK="/usr/bin/pwsh"

# The interpreter this step looks for and then drives. Named through a
# variable so a test can point it at an interpreter that is not there, or at
# a stub that is: PATH cannot express either, since /bin is a symlink to
# /usr/bin on Debian and a name removed from one is still found through the
# other. Every runner that already ships pwsh — GitHub's macOS and Windows
# images do — would otherwise take the "already installed" path and test
# nothing.
_PWSH_BIN="${JB_PWSH:-pwsh}"

# Why the step could not install anything here, phrased for the summary. An
# install helper returns 2 and sets this when the machine cannot have pwsh
# (no upstream build, no downloader, no Homebrew), and 1 when it tried and
# the install itself failed — the summary must not call the first a failure.
_PWSH_SKIP=""

# uname is read through these so a test can pin a platform. PATH cannot do
# that job: hiding `pwsh` by editing PATH would hide it from the check AND
# from the install, so the test would pass with the feature deleted.
#
# Read inside the step, never at file scope: every other step — and --help —
# would otherwise die under `set -e` on a machine with no uname, which is
# what a PATH-restricted run is. An absent uname leaves the platform
# "unknown", and the step says so rather than guessing Linux.
_UNAME_S=""
_UNAME_M=""
_pwsh_uname_init() {
	_UNAME_S="${JB_UNAME_S:-$(uname -s 2>/dev/null || echo unknown)}"
	_UNAME_M="${JB_UNAME_M:-$(uname -m 2>/dev/null || echo unknown)}"
}

# ---------------------------------------------------------------------------
# _pwsh_arch — the PowerShell build name for this machine, DERIVED from
# uname rather than typed. Several of these boxes are arm64, and a hardcoded
# x64 tarball fails inside tar with a message that names neither the
# architecture nor the download.
# ---------------------------------------------------------------------------
_pwsh_arch() {
	case "${_UNAME_M}" in
	x86_64) printf 'x64\n' ;;
	aarch64 | arm64) printf 'arm64\n' ;;
	armv7l) printf 'arm32\n' ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# _pwsh_sudo_init — the privilege prefix, derived the same way install-deps
# derives its own: nothing when already root, sudo when it exists, and bare
# otherwise so the failure comes from the command that actually needed root.
#
# An ARRAY, because IFS is newline+tab here: an empty string variable would
# expand to one empty argument rather than to nothing.
# ---------------------------------------------------------------------------
_PWSH_SUDO=()
_pwsh_sudo_init() {
	if [[ $(id -u) -ne 0 ]] && _have sudo; then
		_PWSH_SUDO=(sudo)
	fi
}

# _pwsh_priv CMD... — _run with that prefix in front, so --dry-run prints
# exactly the command a real run would execute, sudo included.
_pwsh_priv() {
	_run "${_PWSH_SUDO[@]+"${_PWSH_SUDO[@]}"}" "$@"
}

# ---------------------------------------------------------------------------
# _pwsh_install_linux — the pinned tarball into /opt, symlinked onto PATH.
# ---------------------------------------------------------------------------
_pwsh_install_linux() {
	local arch url tarball
	if ! arch="$(_pwsh_arch)"; then
		_warn "no PowerShell build for ${_UNAME_M}"
		_PWSH_SKIP="no build for ${_UNAME_M}"
		return 2
	fi
	if ! _have curl; then
		_warn "curl not installed — cannot download PowerShell"
		_PWSH_SKIP="no curl"
		return 2
	fi
	if ! _have tar; then
		_warn "tar not installed — cannot unpack PowerShell"
		_PWSH_SKIP="no tar"
		return 2
	fi

	url="https://github.com/PowerShell/PowerShell/releases/download/v${_PS_VER}/powershell-${_PS_VER}-linux-${arch}.tar.gz"
	tarball="${TMPDIR:-/tmp}/powershell-${_PS_VER}-linux-${arch}.tar.gz"

	_info "installing PowerShell ${_PS_VER} (linux-${arch}) into ${_PWSH_DIR}"
	_curl_retry_opts_init
	if ! _run curl -sSL --fail "${_CURL_RETRY_OPTS[@]}" --connect-timeout 30 \
		-o "${tarball}" "${url}"; then
		_warn "could not download ${url}"
		return 1
	fi

	_pwsh_sudo_init
	# -f on the symlink, not a bare ln: re-running this step is how an
	# upgrade lands, and a second ln over an existing link is an error
	# rather than a no-op.
	if _pwsh_priv mkdir -p "${_PWSH_DIR}" &&
		_pwsh_priv tar zxf "${tarball}" -C "${_PWSH_DIR}" &&
		_pwsh_priv chmod +x "${_PWSH_DIR}/pwsh" &&
		_pwsh_priv ln -sf "${_PWSH_DIR}/pwsh" "${_PWSH_LINK}"; then
		_run rm -f "${tarball}"
		return 0
	fi
	_warn "unpacking PowerShell failed"
	_run rm -f "${tarball}"
	return 1
}

# ---------------------------------------------------------------------------
# _pwsh_icu_apt — the ICU runtime's apt name, which Debian and Ubuntu version
# by soname (libicu76 on Debian 13, libicu74 on Ubuntu 24.04), so it is
# derived from apt's own lists rather than typed: a hardcoded name is right
# on exactly one release. The newest is taken; ICU sonames install side by
# side, so an older one already present is left alone.
#
# Prints nothing where there is no apt-cache, or where apt's lists are
# empty (a container that never ran `apt-get update`).
# ---------------------------------------------------------------------------
_pwsh_icu_apt() {
	_have apt-cache || return 0
	apt-cache pkgnames libicu 2>/dev/null |
		grep -E '^libicu[0-9]+$' | sort -V | tail -n 1 || true
}

# ---------------------------------------------------------------------------
# _pwsh_icu — the ICU runtime the Linux tarball needs and does not carry.
#
# .NET aborts at startup without it ("Couldn't find a valid ICU package
# installed on the system"), before PowerShell parses a single argument, so
# a pwsh unpacked onto a minimal Debian answered nothing: not --version, not
# the PSScriptAnalyzer probe, not the lint gate. Measured on a Debian 13
# WSL2 box, 2026-10-03.
#
# Runs on every Linux pass, not only after a fresh unpack: a pwsh installed
# by an earlier run that lacked this step is the box this fixes. It goes
# through install-deps like the baseline does, so the install, the dry run
# and sudo behave the same way. Names checked 2026-10-03: pacman `icu`,
# dnf `libicu`, apk `icu-libs` (Microsoft's per-distro dependency lists).
# zypper is absent deliberately: openSUSE versions the name too, with a
# suffix scheme not verified here, so install-deps says it has nothing for
# zypper rather than this step guessing.
# ---------------------------------------------------------------------------
_pwsh_icu() {
	local installer manifest apt_name rc=0
	installer="$(_asset install-deps.sh)" || {
		_warn "install-deps.sh unavailable — cannot install ICU"
		return 1
	}
	apt_name="$(_pwsh_icu_apt)"
	manifest="$(mktemp "${TMPDIR:-/tmp}/jb-icu.XXXXXX")"
	{
		if [[ -n ${apt_name} ]]; then
			printf '[icu.apt]\npackages = ["%s"]\n\n' "${apt_name}"
		fi
		printf '[icu.pacman]\npackages = ["icu"]\n\n'
		printf '[icu.dnf]\npackages = ["libicu"]\n\n'
		printf '[icu.apk]\npackages = ["icu-libs"]\n'
	} >"${manifest}"
	_install_manifest "${installer}" "${manifest}" \
		"the PowerShell runtime (ICU)" || rc=1
	rm -f "${manifest}"
	return "${rc}"
}

# _pwsh_starts — true when the interpreter actually runs. Being on PATH is
# not that: the tarball's pwsh resolves and then aborts without ICU, and an
# "already installed" that only checked PATH reported it as fine.
_pwsh_starts() {
	"${_PWSH_BIN}" -NoProfile -NonInteractive -Command 'exit 0' \
		>/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _pwsh_install_darwin — Homebrew, because the tarball above is a LINUX
# build. Downloading it on a Mac would install something that cannot run,
# and the first sign of it would be an exec format error from the lint gate.
# ---------------------------------------------------------------------------
_pwsh_install_darwin() {
	if ! _have brew; then
		_warn "Homebrew not installed — cannot install PowerShell here"
		_PWSH_SKIP="no brew"
		return 2
	fi
	_info "installing PowerShell via Homebrew"
	_run brew install --cask powershell
}

# ---------------------------------------------------------------------------
# _pwsh_analyzer — the module `make lint-psscriptanalyzer` requires. It fails
# loudly when the module is absent, deliberately: an analyzer that never ran
# has checked nothing.
#
# -Scope CurrentUser needs no elevation. The Get-Module probe is what keeps
# this idempotent — Install-Module -Force reinstalls over the network every
# time it is asked, however recent the copy on disk.
# ---------------------------------------------------------------------------
_pwsh_analyzer() {
	if _have "${_PWSH_BIN}" && "${_PWSH_BIN}" -NoProfile -Command \
		'if (Get-Module -ListAvailable -Name PSScriptAnalyzer) { exit 0 } else { exit 1 }' \
		>/dev/null 2>&1; then
		_info "PSScriptAnalyzer already installed"
		return 0
	fi
	_info "installing PSScriptAnalyzer"
	_run "${_PWSH_BIN}" -NoProfile -Command \
		"Install-Module PSScriptAnalyzer -Scope CurrentUser -Force"
}

step_pwsh() {
	_head "pwsh — PowerShell and PSScriptAnalyzer"
	_pwsh_uname_init

	# Before the PATH check, so a pwsh an earlier run left unable to start
	# gets its runtime too. A failure here is reported by _pwsh_starts below,
	# which is the check that matters.
	if [[ ${_UNAME_S} == Linux ]]; then
		_pwsh_icu || _warn "the ICU install failed — pwsh may not start"
	fi

	local rc=0
	if _have "${_PWSH_BIN}"; then
		if ! _pwsh_starts; then
			_warn "pwsh is installed but does not start — run it to see why"
			_result "pwsh:    failed (does not start)"
			return 0
		fi
		_info "pwsh already installed ($("${_PWSH_BIN}" --version))"
	else
		case "${_UNAME_S}" in
		Linux) _pwsh_install_linux || rc=$? ;;
		Darwin) _pwsh_install_darwin || rc=$? ;;
		*)
			# Not wired to install-deps' winget section yet (#59), so
			# there is nothing honest to do here but say so.
			_warn "no PowerShell recipe for ${_UNAME_S} — provision it with that system's own package manager"
			_PWSH_SKIP="${_UNAME_S}"
			rc=2
			;;
		esac
		case ${rc} in
		0) ;;
		2)
			_result "pwsh:    skipped (${_PWSH_SKIP})"
			return 0
			;;
		*)
			_result "pwsh:    failed"
			return 0
			;;
		esac
	fi

	if _pwsh_analyzer; then
		_result "pwsh:    ok"
	else
		_warn "PSScriptAnalyzer was not installed"
		_result "pwsh:    failed (PSScriptAnalyzer)"
	fi
}

# claude — Anthropic's own installer; it puts the binary in ~/.local/bin,
# which the shell step has already put on PATH.
step_claude() {
	_head "claude — Claude Code"

	if _have claude; then
		_info "claude already installed"
		_result "claude:  ok (already installed)"
		return 0
	fi
	if ! _have curl; then
		_warn "curl not installed — cannot install Claude Code"
		_result "claude:  skipped (no curl)"
		return 0
	fi

	_info "installing Claude Code"
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would run: curl -fsSL https://claude.ai/install.sh | bash"
		_result "claude:  ok (dry run)"
		return 0
	fi
	if curl -fsSL https://claude.ai/install.sh | bash; then
		_info "run 'claude' to sign in"
		_result "claude:  ok (installed)"
	else
		_warn "the Claude Code installer failed"
		_result "claude:  failed"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ -n ${TEMPLATE} ]]; then
	_src="$(_asset "${TEMPLATE}")"
	if [[ ${TEMPLATE_PATH} == "-" ]]; then
		cat "${_src}"
	else
		cat "${_src}" >"${TEMPLATE_PATH}"
		echo "wrote ${TEMPLATE_PATH}" >&2
	fi
	exit 0
fi

# Resolve the step list: explicit -s > [tools.setup-system].steps > all.
if [[ ${STEPS_EXPLICIT} -eq 0 ]]; then
	_toml_steps=""
	_steps_toml="$(_find_bootstrap_toml || true)"
	if [[ -n ${_steps_toml} ]]; then
		while IFS= read -r _s; do
			[[ -z ${_s} ]] && continue
			_toml_steps="${_toml_steps:+${_toml_steps},}${_s}"
		done < <(toml_get_array "tools" "setup-system" "steps" <"${_steps_toml}")
	fi
	if [[ -n ${_toml_steps} ]]; then
		STEPS_STR="${_toml_steps}"
	else
		STEPS_STR=""
		for _s in "${_STEPS_ALL[@]}"; do
			case " ${_STEPS_OPT_IN_STR} " in
			*" ${_s} "*) continue ;;
			esac
			STEPS_STR="${STEPS_STR:+${STEPS_STR},}${_s}"
		done
	fi
fi

# Validate before doing anything: a typo should not leave a machine half
# configured.
for _step in $(tr ',' '\n' <<<"${STEPS_STR},${SKIP_STR}"); do
	[[ -z ${_step} ]] && continue
	case " ${_STEPS_ALL_STR} " in
	*" ${_step} "*) ;;
	*)
		echo "error: unknown step '${_step}'" >&2
		echo "       known steps: ${_STEPS_ALL_STR}" >&2
		exit 1
		;;
	esac
done

_say "just-bashit setup-system"
[[ ${DRY_RUN} -eq 1 ]] && _say "dry run — nothing will be changed"
_log "steps:  ${STEPS_STR}"
_log "skip:   ${SKIP_STR:-none}"
_log "prefix: ${PREFIX}"

# Run in canonical order rather than the order given, so dependencies
# between steps hold however the list was written.
_ran=0
for _step in "${_STEPS_ALL[@]}"; do
	case ",${STEPS_STR}," in
	*",${_step},"*) ;;
	*) continue ;;
	esac
	case ",${SKIP_STR}," in
	*",${_step},"*)
		_log "skipping ${_step} (--skip)"
		continue
		;;
	esac
	_ran=1
	"step_${_step}"
done

if [[ ${_ran} -eq 0 ]]; then
	echo "error: no steps selected" >&2
	exit 1
fi

_say ""
_say "summary"
for _r in "${_RESULTS[@]+"${_RESULTS[@]}"}"; do
	_say "    ${_r}"
done
_say ""
_say "open a new shell, or run: exec bash -l"
