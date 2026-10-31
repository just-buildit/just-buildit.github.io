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
_STEPS_ALL=(deps certs shell ssh sshd git tools pwsh claude)
_STEPS_ALL_STR="deps certs shell ssh sshd git tools pwsh claude"

# Steps that run only when named with -s or in bootstrap.toml. sshd opens a
# listening port on the machine, and certs widens what the machine trusts,
# with sudo: neither is something a default run gets to decide on the
# user's behalf. Except sshd on native Windows (#190), where reachability
# from boot is the reason the box is being set up: there it is a default
# step (key-only, the firewall scoped by --sshd-allow). The step list is
# resolved under Main, which drops it from this list there.
_STEPS_OPT_IN_STR="certs sshd"

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
	  certs   WSL only, and only when asked for (-s certs): install
	          Windows' trusted root certificates into the distro trust
	          store beside its Mozilla bundle, one file per root, and
	          remove any Windows no longer trusts.
	  shell   Install the opinionated bash configuration to
	          ~/.config/just-bashit/{bashrc,profile}.sh and add one source
	          line to ~/.bashrc and ~/.profile. Your files stay yours.
	  ssh     Ensure ~/.ssh permissions and an ed25519 key named after this
	          host; print the public key to register with GitHub.
	  sshd    Windows only (WSL or native MSYS2 / Git Bash): run Windows'
	          OpenSSH server as a boot-time service -- key-only, keys
	          from github.com/<user>.keys, pwsh.exe as the login shell --
	          so the machine is reachable over ssh even when WSL is not
	          running. Raises one UAC prompt on the Windows desktop. On
	          native Windows it is a default step, and also starts the
	          ssh-agent service at boot and adds the box key to it; from
	          WSL only when asked for (-s sshd).
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
	                             EMPTY passphrase — see the docs first. On
	                             Windows, never raises a UAC prompt: a step
	                             that needs admin runs in an admin shell or
	                             over the admin ssh channel, else is skipped.
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

	Default steps: all of them except certs and sshd; on native Windows,
	all but certs. To restrict the default set, declare steps = [...]
	under [tools.setup-system] in bootstrap.toml.

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
# _sudo_init — the privilege prefix, derived the same way install-deps
# derives its own: nothing when already root, sudo when it exists, and bare
# otherwise so the failure comes from the command that actually needed root.
#
# An ARRAY, because IFS is newline+tab here: an empty string variable would
# expand to one empty argument rather than to nothing.
# ---------------------------------------------------------------------------
_SUDO=()
_sudo_init() {
	if [[ $(id -u) -ne 0 ]] && _have sudo; then
		_SUDO=(sudo)
	fi
}

# _priv CMD... — _run with that prefix in front, so --dry-run prints
# exactly the command a real run would execute, sudo included.
_priv() {
	_run "${_SUDO[@]+"${_SUDO[@]}"}" "$@"
}

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
	# With MSYS path conversion on, whatever the caller turned off: the sshd
	# step sets MSYS2_ARG_CONV_EXCL='*' for its Windows programs, and Git for
	# Windows' curl is one too -- handed `-o /tmp/...` unconverted, it could
	# not write it (curl: (23)) and the step failed on a jbx run with
	# "windows-sshd.ps1 unavailable" (measured 2026-10-31, #190).
	if ! env -u MSYS2_ARG_CONV_EXCL -u MSYS_NO_PATHCONV \
		curl -sSL --fail "${_CURL_RETRY_OPTS[@]}" --connect-timeout 30 \
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
for _lib in toml.sh file.sh windows.sh jbx-shell.sh pkg.sh; do
	_lib_path="$(_asset "${_lib}")" || exit 1
	# shellcheck source=/dev/null
	source "${_lib_path}"
done
unset _lib _lib_path

# ---------------------------------------------------------------------------
# _RELOAD — why the shell that ran this is out of date, if it is. The closing
# "open a new shell" hint is printed only with a reason: it used to be
# printed after every run, `-s ssh` included, which changes nothing a running
# shell reads. Set by the two helpers below when they change (or, dry run,
# would change) a file the shell sources at startup, and at the end when a
# tool landed in ~/.local/bin while that is not on the caller's PATH.
# ---------------------------------------------------------------------------
_RELOAD=()
_reload_because() {
	local why="$1" r
	for r in "${_RELOAD[@]+"${_RELOAD[@]}"}"; do
		[[ ${r} == "${why}" ]] && return 0
	done
	_RELOAD+=("${why}")
}

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
	_reload_because "${dest##*/} changed"
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
	_reload_because "${file##*/} now sources just-bashit"
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
# Manifest discovery: prints `bootstrap.toml` when the current directory has
# one, and nothing when it does not.
#
# The legacy names `jb-deps.toml` and `jb.toml` are no longer read (#30), but
# one found without a bootstrap.toml is REFUSED rather than ignored: ignoring
# it would quietly install or report nothing for a project that plainly
# declares its packages. The refusal returns 1, so the caller writes
# `_found=$(_find_bootstrap_toml) || exit 1` to stop on it.
_find_bootstrap_toml() {
	local _n
	if [ -f bootstrap.toml ]; then
		printf '%s\n' bootstrap.toml
		return 0
	fi
	for _n in jb-deps.toml jb.toml; do
		if [ -f "${_n}" ]; then
			printf 'error: %s is no longer read, rename it: git mv %s bootstrap.toml\n' \
				"${_n}" "${_n}" >&2
			return 1
		fi
	done
	return 0
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
# awk is in it because a minimal Debian 13 WSL image ships none
# (2026-10-03), and the steps after this one need it: uv's installer, the
# bashrc template, windows.sh. jbx and install-deps themselves are awk-free,
# so this list installs on a box without one. mawk on apt (Debian's own
# default awk), gawk elsewhere; apk's busybox and macOS already have one.
#
# Deliberately a toolchain and nothing more. Language runtimes and project
# libraries (python3-dev, numpy, rust) are a project's to declare, in its
# own bootstrap.toml, which this step still installs afterwards.
#
# It is also what the installed report at the end of a run lists (#180), so
# the two are one declaration read both ways: a package reports as the
# command of its own name (cmake, git, curl), as the commands its own table
# names in `provides`, or -- a package with `vs_requires` -- as each Visual
# Studio id, by the same vswhere probe install-deps decides by. A package
# whose table names neither (ca-certificates) has no row. install-deps
# reads none of `provides`; it is the report's alone.
read -r -d '' _BASELINE_TOML <<-'EOF' || true
	[baseline.apt]
	packages = ["build-essential", "cmake", "pkg-config", "git", "curl", "ca-certificates", "openssh-client", "tar", "mawk"]

	[baseline.apt."build-essential"]
	provides = ["cc", "make"]

	[baseline.apt."ca-certificates"]

	[baseline.apt."openssh-client"]
	provides = ["ssh"]

	[baseline.apt."mawk"]
	provides = ["awk"]

	[baseline.pacman]
	packages = ["base-devel", "cmake", "pkgconf", "git", "curl", "openssh", "tar", "gawk"]

	[baseline.pacman."base-devel"]
	provides = ["cc", "make"]

	[baseline.pacman."pkgconf"]
	provides = ["pkg-config"]

	[baseline.pacman."openssh"]
	provides = ["ssh"]

	[baseline.pacman."gawk"]
	provides = ["awk"]

	[baseline.dnf]
	packages = ["gcc", "make", "cmake", "pkgconf-pkg-config", "diffutils", "git", "curl", "openssh-clients", "tar", "gawk"]

	[baseline.dnf."gcc"]
	provides = ["cc"]

	[baseline.dnf."pkgconf-pkg-config"]
	provides = ["pkg-config"]

	[baseline.dnf."diffutils"]
	provides = ["diff"]

	[baseline.dnf."openssh-clients"]
	provides = ["ssh"]

	[baseline.dnf."gawk"]
	provides = ["awk"]

	[baseline.zypper]
	packages = ["gcc", "make", "cmake", "pkg-config", "diffutils", "git", "curl", "openssh", "tar", "gawk"]

	[baseline.zypper."gcc"]
	provides = ["cc"]

	[baseline.zypper."diffutils"]
	provides = ["diff"]

	[baseline.zypper."openssh"]
	provides = ["ssh"]

	[baseline.zypper."gawk"]
	provides = ["awk"]

	[baseline.apk]
	packages = ["build-base", "cmake", "pkgconf", "bash", "git", "curl", "openssh-keygen", "tar"]

	[baseline.apk."build-base"]
	provides = ["cc", "make"]

	[baseline.apk."pkgconf"]
	provides = ["pkg-config"]

	[baseline.apk."openssh-keygen"]
	provides = ["ssh-keygen"]

	# The compiler on macOS is the Xcode Command Line Tools, which brew itself
	# requires, so brew has only the build tools to add.
	[baseline.brew]
	packages = ["cmake", "pkg-config"]

	# Native Windows: clang-cl, the toolchain just-makeit and doppler build
	# Windows with, plus CMake, Git (Git Bash, the bash host), PowerShell 7
	# (pwsh: the .ps1 gates, and the shell a Windows user works in) and gh
	# (GitHub CLI: the sshd step takes the keys of the account it is signed
	# in to, and the ssh step checks the key against it, #190). clang-cl
	# links against the MSVC libraries and the Windows SDK, which are the
	# Build Tools' C++ workload, and clang-cl itself is the Build Tools'
	# "C++ Clang Compiler for Windows" component: the id alone installs only
	# the installer shell, so its table names both, and install-deps probes
	# for them with vswhere and adds them to a shell that lacks them (#67).
	# The component ships x64 and ARM64 clang-cl plus a Developer shell hook
	# (vsdevcmd\ext\clang_cl.bat) that puts the host's on PATH; LLVM.LLVM
	# put it on no PATH at all (#181). Its MSBuild toolset companion
	# (VC.Llvm.ClangToolset) is for .vcxproj builds, which nothing here uses.
	# Windows 10+ ships tar.exe and curl.exe itself. Installed from Git Bash
	# directly, and from MSYS2 too: step_deps runs this section there as
	# well, since msys2's own section no longer carries a compiler.
	[baseline.winget]
	packages = ["Kitware.CMake", "Git.Git", "Microsoft.PowerShell", "GitHub.cli", "Microsoft.VisualStudio.BuildTools"]

	[baseline.winget."Microsoft.VisualStudio.BuildTools"]
	vs_requires = ["Microsoft.VisualStudio.Workload.VCTools", "Microsoft.VisualStudio.Component.VC.Llvm.Clang"]

	[baseline.winget."Kitware.CMake"]
	provides = ["cmake"]

	[baseline.winget."Git.Git"]
	provides = ["git"]

	[baseline.winget."Microsoft.PowerShell"]
	provides = ["pwsh"]

	[baseline.winget."GitHub.cli"]
	provides = ["gh"]

	# MSYS2 as the BASH HOST only. Its MinGW gcc toolchain is gone
	# (2026-10-03): just-makeit and doppler build native Windows with
	# clang-cl, and a second compiler that nothing builds with is one more
	# thing to keep working. These are the tools the scripts themselves use.
	[baseline.msys2]
	packages = ["make", "pkg-config", "git", "curl", "openssh"]

	[baseline.msys2."openssh"]
	provides = ["ssh"]
EOF

# _install_manifest INSTALLER FILE LABEL [ARGS...] — one install-deps run
# over FILE, reported under LABEL; ARGS go to install-deps (e.g. -s winget).
# Returns install-deps' own status.
_install_manifest() {
	local installer="$1" file="$2" label="$3"
	shift 3
	local args=("$@")
	[[ ${DRY_RUN} -eq 1 ]] && args+=("--dry-run")
	[[ ${VERBOSE} -eq 1 ]] && args+=("--verbose")
	# --yes reaches install-deps: its Visual Studio modify then never
	# raises a UAC prompt either (#184).
	[[ ${ASSUME_YES} -eq 1 ]] && args+=("--yes")
	_info "installing packages from ${label}"
	if bash "${installer}" "${args[@]+"${args[@]}"}" "${file}"; then
		return 0
	fi
	_warn "install-deps reported a failure for ${label}"
	return 1
}

# _baseline_adds_winget -- true on an MSYS2 host (Windows uname, pacman
# present) with winget: its msys2 section is bash-host tools only, so the
# native toolchain comes from the winget section as well.
_baseline_adds_winget() {
	_pwsh_uname_init
	case "${_UNAME_S}" in
	MINGW* | MSYS* | CYGWIN*)
		_have pacman && { _have winget || _have winget.exe; }
		;;
	*) return 1 ;;
	esac
}

# _baseline_sections -- the [baseline.*] sections the deps step installs on
# this machine, one per line: the detected manager's, then winget's where
# _baseline_adds_winget says so. The installed report lists these.
_baseline_sections() {
	local pm
	pm="$(get-pkg-mgr 2>/dev/null)" || pm=""
	[[ -n ${pm} ]] && printf '%s\n' "${pm}"
	if [[ ${pm} != winget ]] && _baseline_adds_winget; then
		printf 'winget\n'
	fi
	return 0
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
	# MSYS2 (Windows uname, pacman present) gets the msys2 section above --
	# bash-host tools, no compiler -- so the native toolchain comes from the
	# winget section as well, when winget is there to install it.
	if _baseline_adds_winget; then
		_install_manifest "${installer}" "${baseline}" \
			"the native Windows toolchain (winget)" -s winget || ok=0
		done_list="${done_list} + native Windows toolchain"
	fi
	rm -f "${baseline}"

	local deps_file=""
	deps_file="$(_find_bootstrap_toml)" || exit 1
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

# ---------------------------------------------------------------------------
# Overridable so the suite can run WSL-only steps on a Linux runner (as
# ssh-to-windows does): a WSL-only step tested only by hand is eventually not
# tested.
# ---------------------------------------------------------------------------
_PROC_VERSION="${JB_PROC_VERSION:-/proc/version}"

# _on_wsl -- true inside a WSL distro. The certs step (Windows roots), the
# ssh step (box key adoption) and the sshd step (path translator) ask it.
_on_wsl() {
	[[ -r ${_PROC_VERSION} ]] && grep -qi microsoft "${_PROC_VERSION}"
}

# _on_native_windows -- true under MSYS2 / Git Bash on Windows itself (WSL
# reports Linux). The one predicate for "native Windows" (#190): the sshd step
# (which path translator), the default step set (sshd is in it there), the
# Windows ssh-agent and the git step's core.sshCommand all ask it.
_on_native_windows() {
	_pwsh_uname_init
	case "${_UNAME_S}" in
	MINGW* | MSYS* | CYGWIN*) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# certs — WSL only, opt-in: export Windows Trusted Root certificates via
# PowerShell and install them, one anchor file per root, in the distro trust
# store, whose updater merges them with the Mozilla CA bundle.
# ---------------------------------------------------------------------------

# Prefixed onto every trust-store path, so the suite can install into a
# throwaway tree instead of the runner's real /etc.
_CERTS_ROOT="${JB_CERTS_ROOT:-}"

# Each distro family's anchor directory and the updater that reads it, one
# row each. The directory is what the distro's ca-certificates package
# creates, so its presence is the signal -- not the updater alone: openSUSE
# has update-ca-certificates but reads /etc/pki/trust/anchors, and Arch has
# update-ca-trust but reads /etc/ca-certificates/trust-source/anchors, so
# choosing by updater wrote an anchor neither would ever read.
_CERTS_STORES=(
	"/usr/local/share/ca-certificates update-ca-certificates"           # Debian, Ubuntu, Alpine
	"/etc/pki/ca-trust/source/anchors update-ca-trust extract"          # Fedora, RHEL
	"/etc/ca-certificates/trust-source/anchors update-ca-trust extract" # Arch
	"/etc/pki/trust/anchors update-ca-certificates"                     # openSUSE
)

# _certs_have_updater NAME -- is NAME runnable as root? sbin is checked by
# path because a non-root PATH on Debian does not include it, while sudo's
# secure_path does.
_certs_have_updater() {
	_have "$1" || [[ -x /usr/sbin/$1 || -x /sbin/$1 ]]
}

# _certs_store -- print the first row whose directory exists and whose
# updater is installed, or return 1.
_certs_store() {
	local row dir updater
	for row in "${_CERTS_STORES[@]}"; do
		dir="${row%% *}"
		updater="${row#* }"
		updater="${updater%% *}"
		if [[ -d ${_CERTS_ROOT}${dir} ]] && _certs_have_updater "${updater}"; then
			printf '%s\n' "${row}"
			return 0
		fi
	done
	return 1
}

# The PowerShell that prints every Windows trusted root as PEM, once each,
# each preceded by a "# <thumbprint>" line that names its file:
# CurrentUser\Root shows the machine's roots as well, so without the
# thumbprint dedupe most certificates would appear twice. PowerShell's own
# strings are single-quoted: a double quote is what the WSL interop layer
# has to re-escape on the way into a Windows command line.
_CERTS_PS="Get-ChildItem -Path Cert:\\LocalMachine\\Root, Cert:\\CurrentUser\\Root -ErrorAction SilentlyContinue | Where-Object { \$_.RawData } | Sort-Object -Property Thumbprint -Unique | ForEach-Object { '# ' + \$_.Thumbprint; '-----BEGIN CERTIFICATE-----'; [System.Convert]::ToBase64String(\$_.RawData, 'InsertLineBreaks'); '-----END CERTIFICATE-----' }"

# Every file this step owns in the anchor directory starts with this, so a
# root Windows no longer exports can be found and removed, and nothing else
# in the directory is ever touched. One file per certificate, directly in the
# anchor directory and not in a subdirectory: Debian's openssl rehash skips a
# file holding more than one certificate, and p11-kit (Fedora, Arch,
# openSUSE) and Alpine's updater do not descend into subdirectories.
_CERTS_PREFIX="jb-windows-root-"

# _certs_split EXPORT DIR -- write each certificate of EXPORT (the output of
# _CERTS_PS) to DIR/<prefix><thumbprint>.crt and print how many. A thumbprint
# that is not 40 hex digits names no file, so its certificate is dropped.
_certs_split() {
	local dump="$1" dir="$2" line out="" n=0
	while IFS= read -r line; do
		if [[ ${line} =~ ^#\ ([0-9A-Fa-f]{40})$ ]]; then
			out="${dir}/${_CERTS_PREFIX}$(tr 'A-F' 'a-f' <<<"${BASH_REMATCH[1]}").crt"
			: >"${out}"
			n=$((n + 1))
		elif [[ ${line} == "#"* ]]; then
			out=""
		elif [[ -n ${out} ]]; then
			printf '%s\n' "${line}" >>"${out}"
		fi
	done <"${dump}"
	printf '%s\n' "${n}"
}

# _certs_owned DIR -- the files this step owns in DIR, one per line.
_certs_owned() {
	local f
	for f in "$1/${_CERTS_PREFIX}"*.crt; do
		[[ -e ${f} ]] && printf '%s\n' "${f}"
	done
	return 0
}

# _certs_put SRC_DIR DEST_DIR -- make DEST_DIR's owned files exactly
# SRC_DIR's: install each, then remove any owned file SRC_DIR lacks.
_certs_put() {
	local src="$1" dest="$2" f
	for f in "${src}/${_CERTS_PREFIX}"*.crt; do
		[[ -e ${f} ]] || continue
		_priv install -m 0644 "${f}" "${dest}/${f##*/}" || return 1
	done
	for f in $(_certs_owned "${dest}"); do
		[[ -e "${src}/${f##*/}" ]] || _priv rm -f "${f}" || return 1
	done
}

# _certs_same A B -- do directories A and B hold the same owned files, with
# the same contents?
_certs_same() {
	local f
	[[ "$(_certs_owned "$1" | sed 's|.*/||')" == "$(_certs_owned "$2" | sed 's|.*/||')" ]] ||
		return 1
	for f in $(_certs_owned "$1"); do
		cmp -s "${f}" "$2/${f##*/}" || return 1
	done
}

step_certs() {
	_head "certs — Windows trusted root certificates"

	if ! _on_wsl; then
		_info "not WSL — no Windows root certificates to import"
		_result "certs:   skipped (not WSL)"
		return 0
	fi

	local row cert_dir updater=()
	if ! row="$(_certs_store)"; then
		_warn "no trust store this step knows (with its updater installed)"
		_result "certs:   skipped (no known trust store)"
		return 0
	fi
	cert_dir="${_CERTS_ROOT}${row%% *}"
	IFS=' ' read -r -a updater <<<"${row#* }"

	local ps_exe
	if ! ps_exe="$(win-exe powershell.exe)"; then
		_warn "powershell.exe not found — cannot export Windows certificates"
		_result "certs:   skipped (no powershell.exe)"
		return 0
	fi

	_sudo_init
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would export Windows trusted roots via ${ps_exe}"
		_priv install -m 0644 "<each exported root>" \
			"${cert_dir}/${_CERTS_PREFIX}<thumbprint>.crt"
		_priv rm -f "<each ${_CERTS_PREFIX}*.crt no longer exported>"
		_priv "${updater[@]}"
		_result "certs:   ok (dry run)"
		return 0
	fi

	# new: this export, one file per root. old: what is installed now, kept
	# so a failed update can put it back.
	local tmp new old dump count
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/jb-windows-roots.XXXXXX")"
	new="${tmp}/new"
	old="${tmp}/old"
	dump="${tmp}/export.pem"
	mkdir -p "${new}" "${old}"

	_info "exporting Windows trusted root certificates"
	if ! "${ps_exe}" -NoProfile -NonInteractive -Command "${_CERTS_PS}" |
		tr -d '\r' >"${dump}"; then
		rm -rf "${tmp}"
		_warn "PowerShell could not export the Windows root store"
		_result "certs:   failed (export)"
		return 0
	fi
	count="$(_certs_split "${dump}" "${new}")"
	if [[ ${count} -eq 0 ]]; then
		rm -rf "${tmp}"
		_warn "the Windows root store exported no certificates"
		_result "certs:   failed (empty export)"
		return 0
	fi

	# Re-running is how a new or removed Windows root reaches WSL, and an
	# unchanged export needs neither root nor the updater. That shortcut is
	# only sound because a failed update below puts the old set back: a set
	# left behind by one would otherwise read as "unchanged" forever.
	if _certs_same "${new}" "${cert_dir}"; then
		rm -rf "${tmp}"
		_result "certs:   ok (${count} Windows roots, unchanged)"
		return 0
	fi

	local f
	for f in $(_certs_owned "${cert_dir}"); do
		cp "${f}" "${old}/"
	done

	_info "updating the trust store (${updater[*]})"
	if ! _certs_put "${new}" "${cert_dir}" || ! _priv "${updater[@]}"; then
		_certs_put "${old}" "${cert_dir}" || true
		rm -rf "${tmp}"
		_warn "${updater[*]} failed — the previous Windows roots are back"
		_result "certs:   failed (${updater[0]})"
		return 0
	fi
	rm -rf "${tmp}"
	_result "certs:   ok (${count} Windows roots in ${cert_dir})"
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

	# The `jbx` function that applies a run's changes to the calling shell;
	# bashrc.sh sources it from beside itself (jbx-shell.sh says why).
	local src_jbxsh
	if src_jbxsh="$(_asset jbx-shell.sh)"; then
		_install_file "${src_jbxsh}" "${PREFIX}/jbx-shell.sh"
	else
		_warn "jbx-shell.sh unavailable — runs will ask for a new shell"
	fi

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

# ---------------------------------------------------------------------------
# The installed report -- what the baseline installs on this machine, plus
# the tools the other steps install (uv, pwsh, claude) and gh, which no step
# installs but every next step needs; each with the version and path it
# answers with once the steps have run. "ok" in the summary says a step
# finished; this says what is actually on the machine, which is what a
# person comparing two boxes, or reading a bug report, needs.
#
# The baseline rows come from _BASELINE_TOML itself, for the sections
# _baseline_sections names (#180): one declaration, read by the install and
# by the report, so a Windows box is asked about cmake, clang-cl and the
# VCTools workload its winget section installs, not about the make, cc and
# pkg-config a Unix list named on every platform.
#
# Asked of each tool itself (`--version`), not of the package manager: the
# copy on PATH is the one that runs, and uv, claude and pwsh do not come from
# the package manager at all. ~/.local/bin is searched too, because the run
# that installed uv and claude into it has not got it on PATH yet.
# ---------------------------------------------------------------------------
_REPORT_EXTRA=(gh uv pwsh claude)

# _baseline_report_rows -- one row spec per line, in table order, for the
# sections this machine installs: `cmd NAME` for a command, `vs ID` for a
# Visual Studio id. Duplicates (git in two sections) are dropped.
_baseline_report_rows() {
	# while-read, not mapfile: setup-system runs on macOS's bash 3.2.
	local section pkg v row seen=" "
	local -a rows
	while IFS= read -r section; do
		while IFS= read -r pkg; do
			rows=()
			while IFS= read -r v; do rows+=("vs ${v}"); done < <(
				printf '%s\n' "${_BASELINE_TOML}" |
					toml_get_array baseline "${section}.\"${pkg}\"" vs_requires
			)
			while IFS= read -r v; do rows+=("cmd ${v}"); done < <(
				printf '%s\n' "${_BASELINE_TOML}" |
					toml_get_array baseline "${section}.\"${pkg}\"" provides
			)
			# No table of its own: the package is its own command. A table
			# naming nothing (ca-certificates) is a package with no row.
			if [[ ${#rows[@]} -eq 0 && ${_BASELINE_TOML} != *"[baseline.${section}.\"${pkg}\"]"* ]]; then
				rows=("cmd ${pkg}")
			fi
			for row in "${rows[@]+"${rows[@]}"}"; do
				[[ ${seen} == *" ${row} "* ]] && continue
				seen="${seen}${row} "
				printf '%s\n' "${row}"
			done
		done < <(printf '%s\n' "${_BASELINE_TOML}" | toml_get_packages baseline "${section}")
	done < <(_baseline_sections)
}

# _tool_path NAME -- where NAME runs from, or nothing.
_tool_path() {
	command -v "$1" 2>/dev/null && return 0
	if [[ -x "${HOME}/.local/bin/$1" ]]; then
		printf '%s\n' "${HOME}/.local/bin/$1"
	fi
}

# _tool_version NAME PATH -- the first dotted version in what the tool says
# about itself: `cc (Debian 14.2.0-19) 14.2.0` -> 14.2.0, `OpenSSH_10.0p2`
# -> 10.0p2. A tool that runs but names no version prints "?"; one that dies
# trying (pwsh without ICU) prints "does not run".
_tool_version() {
	local name="$1" path="$2" out
	# `env` when there is no timeout (stock macOS has none): bash 3.2 under
	# set -u refuses an empty "${to[@]}", and every row read "does not run".
	local -a to=(env)
	_have timeout && to=(timeout 20)
	case "${name}" in
	ssh) out="$("${to[@]}" "${path}" -V 2>&1)" || out="" ;;
	awk) out="$("${to[@]}" "${path}" -W version 2>&1 ||
		"${to[@]}" "${path}" --version 2>&1)" || out="" ;;
	*) out="$("${to[@]}" "${path}" --version 2>&1)" || out="" ;;
	esac
	out="${out%%$'\n'*}"
	local re='[0-9]+(\.[0-9]+)+[a-z0-9]*'
	if [[ ${out} =~ ${re} ]]; then
		printf '%s\n' "${BASH_REMATCH[0]}"
	elif [[ -n ${out} ]]; then
		printf '?\n'
	else
		printf 'does not run\n'
	fi
}

# ---------------------------------------------------------------------------
# The Windows PATH as the registry holds it, for the report (#180).
#
# winget's installers write the Machine or User PATH in the registry, which
# every NEW process reads and no running one does: CMake installed by this
# very run is on the Machine PATH and not on ours, and the report used to
# call it "missing". So on native Windows the report probes with the
# registry's directories appended to PATH -- appended, so the copy this
# shell already runs still wins -- and a tool found only there is reported
# where it is, with the closing advice naming the directory: it is
# installed, and a new window is what reaches it. Reporting "installed, new
# window needed" per row instead was the alternative; it says the same thing
# once per tool, and the closing advice has to say it anyway.
#
# Read through Windows PowerShell's [Environment], which expands the
# %SystemRoot%-style entries; cygpath -u turns each into a path this shell
# can open. JB_REGISTRY_PATH overrides with a ready colon-separated list,
# for a test.
# ---------------------------------------------------------------------------
_REGISTRY_PATH_ONLY=()

# _WINDOW_PATH -- the registry directories a reported tool was found in and
# this shell's PATH lacks: what a new window would add. The closing advice
# names each.
_WINDOW_PATH=()
_window_because() {
	local d
	for d in "${_WINDOW_PATH[@]+"${_WINDOW_PATH[@]}"}"; do
		[[ ${d} == "$1" ]] && return 0
	done
	_WINDOW_PATH+=("$1")
}

# _registry_path_dirs -- the Machine then User PATH directories, as local
# paths, one per line; nothing off native Windows or without PowerShell.
_registry_path_dirs() {
	local ps raw d
	if [[ -n ${JB_REGISTRY_PATH+x} ]]; then
		tr ':' '\n' <<<"${JB_REGISTRY_PATH}"
		return 0
	fi
	_pwsh_uname_init
	case "${_UNAME_S}" in
	MINGW* | MSYS* | CYGWIN*) ;;
	*) return 0 ;;
	esac
	ps="$(_powershell_bin)" || return 0
	_have cygpath || return 0
	raw="$("${ps}" -NoProfile -NonInteractive -Command \
		"[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')" \
		2>/dev/null | tr -d '\r')" || return 0
	while IFS= read -r -d ';' d; do
		[[ -n ${d} ]] && cygpath -u "${d}" 2>/dev/null
	done <<<"${raw};"
}

# _registry_path_init -- fill _REGISTRY_PATH_ONLY with the registry's
# directories this shell's PATH lacks, existing ones only.
_registry_path_init() {
	local d
	_REGISTRY_PATH_ONLY=()
	while IFS= read -r d; do
		d="${d%/}"
		[[ -n ${d} && -d ${d} ]] || continue
		case ":${PATH}:" in
		*":${d}:"* | *":${d}/:"*) continue ;;
		esac
		_REGISTRY_PATH_ONLY+=("${d}")
	done < <(_registry_path_dirs)
}

# _report_cmd NAME -- one row for a command, probed with the registry's
# directories after this shell's PATH. A command found only in one of them
# records that directory for the closing advice (_WINDOW_PATH).
_report_cmd() {
	local name="$1" path ver search="${PATH}" d
	for d in "${_REGISTRY_PATH_ONLY[@]+"${_REGISTRY_PATH_ONLY[@]}"}"; do
		search="${search}:${d}"
	done
	path="$(PATH="${search}" _tool_path "${name}")"
	if [[ -z ${path} ]]; then
		printf '    %-18s %s\n' "${name}" "missing"
		return 0
	fi
	for d in "${_REGISTRY_PATH_ONLY[@]+"${_REGISTRY_PATH_ONLY[@]}"}"; do
		if [[ ${path%/*} == "${d}" ]]; then
			_window_because "${d}"
		fi
	done
	ver="$(_tool_version "${name}" "${path}")"
	printf '    %-18s %-12s %s\n' "${name}" "${ver}" "${path}"
	# The lint gate's module, which the pwsh step installs with it.
	if [[ ${name} == pwsh && ${ver} != "does not run" ]]; then
		# shellcheck disable=SC2016  # $m is PowerShell's, not bash's
		ver="$("${path}" -NoProfile -NonInteractive -Command \
			'$m = Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1; if ($m) { $m.Version.ToString() }' \
			2>/dev/null || true)"
		printf '    %-18s %s\n' "  PSScriptAnalyzer" "${ver:-missing}"
	fi
}

# _report_vs ID -- one row for a Visual Studio id: the instance that has it,
# by the vswhere probe install-deps decides an install by (pkg.sh).
_report_vs() {
	local id="$1" dir="" where=""
	dir="$(_vs_installer_dir 2>/dev/null)" || dir=""
	[[ -n ${dir} ]] && where="$(_vswhere "${dir}" -requires "${id}")"
	if [[ -z ${where} ]]; then
		printf '    %-18s %s\n' "${id}" "missing"
		return 0
	fi
	printf '    %-18s %-12s %s\n' "${id}" "installed" "${where}"
}

_installed_report() {
	local row name seen=" "
	# Off in the test suite: it runs every tool's --version, and a test whose
	# stub ssh records its calls would record `-V` instead.
	[[ ${JB_INSTALLED_REPORT:-1} == 0 ]] && return 0
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_say "installed (as of now: this dry run changed nothing)"
	else
		_say "installed"
	fi
	_registry_path_init
	while IFS= read -r row; do
		name="${row#* }"
		case "${row}" in
		vs\ *) _report_vs "${name}" ;;
		*) _report_cmd "${name}" ;;
		esac
		seen="${seen}${name} "
	done < <(_baseline_report_rows)
	for name in "${_REPORT_EXTRA[@]}"; do
		[[ ${seen} == *" ${name} "* ]] && continue
		_report_cmd "${name}"
	done
}

# _ssh_github_check KEY -- ask GitHub whether it accepts KEY, and put the
# answer in the summary. A key that exists is not a key that works: until it
# is on the account every clone over ssh fails, and that failure used to be
# the first sign. `ssh -T git@github.com` answers "Hi <user>! You've
# successfully authenticated" for a registered key (exit 1: no shell) and
# "Permission denied (publickey)" for one that is not.
#
# -i with IdentitiesOnly, so the answer is about THIS key and not whatever
# the agent holds; BatchMode, so a passphrase prompt cannot hang the run. A
# passphrase-protected key that is not in the agent cannot be tested that
# way, and is reported as exactly that, never as "not registered".
# JB_SSH_GITHUB_CHECK=0 turns the check off (the test suite, offline boxes).
_ssh_github_check() {
	local key="$1" out user
	[[ ${JB_SSH_GITHUB_CHECK:-1} == 0 ]] && return 0
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would test ${key} against git@github.com"
		return 0
	fi
	if ! _have ssh; then
		_result "github:  not tested (no ssh client)"
		return 0
	fi
	out="$(ssh -T -i "${key}" -o IdentitiesOnly=yes -o BatchMode=yes \
		-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
		git@github.com 2>&1 || true)"
	local hi_re="Hi ([^!]+)! You.ve successfully authenticated"
	if [[ ${out} =~ ${hi_re} ]]; then
		user="${BASH_REMATCH[1]}"
		_info "GitHub accepts ${key} (account ${user})"
		_result "github:  ok (${key##*/} authenticates as ${user})"
	elif [[ ${out} == *"Permission denied"* ]]; then
		if _have ssh-keygen && ! ssh-keygen -y -P '' -f "${key}" >/dev/null 2>&1 &&
			! { ssh-add -L 2>/dev/null | grep -qF -- "$(cut -d' ' -f2 "${key}.pub")"; }; then
			_info "${key} has a passphrase and is not in ssh-agent, so it cannot be tested unattended"
			_info "test it by hand: ssh -T -i ${key} git@github.com"
			_result "github:  not tested (passphrase: ssh-add ${key}, then ssh -T git@github.com)"
		else
			_warn "GitHub does not accept ${key} — add it: gh ssh-key add ${key}.pub --title '${key##*/}'"
			_result "github:  NOT registered (gh ssh-key add ${key}.pub --title '${key##*/}')"
		fi
	else
		_warn "could not ask GitHub about ${key}: ${out##*$'\n'}"
		_result "github:  not tested (github.com unreachable over ssh)"
	fi
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

	local name="${KEY_NAME}"
	if [[ -z ${name} ]]; then
		name="$(ssh-key-name)"
	fi
	local key="${dir}/${name}"

	# Any private key with a matching .pub counts; a machine that already
	# has an identity does not need another one. The one GitHub is asked
	# about is the box key when it is among them, else the last one found.
	local pub found=""
	for pub in "${dir}"/*.pub; do
		[[ -r ${pub} ]] || continue
		[[ -r ${pub%.pub} ]] || continue
		found="${pub%.pub}"
		_log "found key ${found}"
	done

	if [[ -n ${found} ]]; then
		[[ -r ${key} && -r ${key}.pub ]] && found="${key}"
		_info "existing key(s) found in ${dir} — not generating another"
		_result "ssh:     ok (existing key)"
		_ssh_github_check "${found}"
		return 0
	fi

	# On WSL, one key per BOX, not per distro. Distros do not share a
	# filesystem, so each one used to generate its own key under the same
	# name and comment -- three different `matt@swiftgo-ultra7` keys on one
	# machine, indistinguishable on GitHub (2026-10-03). The Windows profile
	# is the one place every distro on the box can read, and where the box
	# key already lives once ssh-to-windows has published it, so it is
	# adopted from there before anything is generated. Needs no ssh-keygen.
	local win_home=""
	if _on_wsl && win_home="$(win-home)" &&
		[[ -r "${win_home}/.ssh/${name}" && -r "${win_home}/.ssh/${name}.pub" ]]; then
		_info "adopting this box's key from ${win_home}/.ssh/${name}"
		_run cp -- "${win_home}/.ssh/${name}" "${key}"
		_run cp -- "${win_home}/.ssh/${name}.pub" "${key}.pub"
		_run chmod 0600 "${key}"
		_run chmod 0644 "${key}.pub"
		_result "ssh:     ok (box key from Windows: ${key})"
		_ssh_github_check "${key}"
		return 0
	fi

	if ! _have ssh-keygen; then
		_info "ssh-keygen not installed — skipping key generation"
		_result "ssh:     skipped (no ssh-keygen)"
		return 0
	fi

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

	# A new box key on WSL goes to the Windows profile at once, so the next
	# distro adopts it (above) instead of minting another. ssh-to-windows
	# owns the copy and the NTFS ACL Windows OpenSSH insists on.
	if [[ -n ${win_home} ]]; then
		local publisher
		if publisher="$(_asset ssh-to-windows.sh)"; then
			local pub_args=(--key "${name}")
			[[ ${DRY_RUN} -eq 1 ]] && pub_args+=(--dry-run)
			_info "publishing ${name} to ${win_home}/.ssh for this box's other distros"
			bash "${publisher}" "${pub_args[@]}" ||
				_warn "could not publish ${name} to Windows — run ssh-to-windows.sh --key ${name}"
		else
			_warn "ssh-to-windows.sh unavailable — ${name} stays in this distro only"
		fi
	fi
	_result "ssh:     ok (created ${key})"
	_ssh_github_check "${key}"
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
# to read \\wsl.localhost paths) and runs it by windows.sh's
# win-admin-route (#184): directly when this shell is already elevated,
# over the admin ssh channel when there is one, else through a UAC prompt
# (Start-Process -Verb RunAs) -- except under --yes, which never prompts and
# skips the step instead. It waits, and relays the script's log -- the
# elevated window is hidden, so without the log a failure would be
# invisible.
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

# _win_openssh NAME -- native Windows: Windows' own OpenSSH client program
# NAME (ssh.exe, ssh-add.exe, ssh-keygen.exe) as a path this shell can run,
# or return 1 when it is absent. By full path, never a PATH lookup: Git for
# Windows puts its own MSYS ssh first on PATH, and that ssh neither reaches
# the Windows agent service nor is what pwsh and VS Code run.
# JB_WIN_OPENSSH names the directory instead, for a test.
_win_openssh() {
	local dir="${JB_WIN_OPENSSH:-}"
	if [[ -z ${dir} ]]; then
		dir="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}" 2>/dev/null)/System32/OpenSSH" ||
			return 1
	fi
	[[ -x "${dir}/$1" ]] || return 1
	printf '%s\n' "${dir}/$1"
}

# _win_agent_key -- native Windows: put the box key into Windows' ssh-agent
# service (#190), as the user, with Windows' own ssh-add.exe. The service
# keeps it across reboots, so this is a once-per-box add; a later run finds
# it listed and changes nothing. The service itself -- Automatic, started --
# is windows-sshd.ps1's -SshAgent, inside the sshd step's one elevated run.
#
# A key with a passphrase is added only where ssh-add can ask for it: at a
# terminal, without --yes. Otherwise it is reported with the command to run,
# never prompted for behind an unattended run.
_win_agent_key() {
	local add keygen
	if ! add="$(_win_openssh ssh-add.exe)" ||
		! keygen="$(_win_openssh ssh-keygen.exe)"; then
		_warn "Windows' OpenSSH client (System32\\OpenSSH) not found"
		_result "agent:   skipped (no Windows OpenSSH client)"
		return 0
	fi
	local name="${KEY_NAME}"
	[[ -n ${name} ]] || name="$(ssh-key-name)"
	local key="${HOME}/.ssh/${name}"
	if [[ ! -r ${key} || ! -r ${key}.pub ]]; then
		_info "no box key at ${key} -- the ssh step makes one"
		_result "agent:   skipped (no key ${key})"
		return 0
	fi
	# ssh-add.exe is a Windows program: it gets the Windows spelling.
	local wkey
	wkey="$(cygpath -w "${key}")"
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would add ${wkey} to the Windows ssh-agent service (${add})"
		_result "agent:   ok (dry run)"
		return 0
	fi

	# ssh-add -l: 0 lists keys, 1 the agent holds none, 2 no agent to ask.
	local listed rc=0 fp
	listed="$("${add}" -l 2>/dev/null | tr -d '\r')" || rc=$?
	if [[ ${rc} -ge 2 ]]; then
		_warn "the Windows ssh-agent service is not running -- the sshd step's elevated run starts it"
		_result "agent:   skipped (ssh-agent service not running)"
		return 0
	fi
	fp="$("${keygen}" -lf "${wkey}.pub" 2>/dev/null | tr -d '\r' | awk '{ print $2 }')" || fp=""
	if [[ -n ${fp} && $'\n'"${listed}"$'\n' == *" ${fp} "* ]]; then
		_info "${name} is already in the Windows agent"
		_result "agent:   ok (${name} already in the Windows agent)"
		return 0
	fi
	# An empty passphrase opens an unprotected key and fails on any other.
	if ! "${keygen}" -y -P "" -f "${wkey}" >/dev/null 2>&1; then
		if [[ ${ASSUME_YES} -eq 1 || ! -t 0 ]]; then
			_warn "${name} has a passphrase -- add it once, from PowerShell: ssh-add '${wkey}'"
			_result "agent:   skipped (passphrase key: run ssh-add '${wkey}')"
			return 0
		fi
		_info "${name} has a passphrase: ssh-add asks for it once, and the agent keeps it"
	fi
	if "${add}" "${wkey}"; then
		_result "agent:   ok (${name} added to the Windows agent)"
	else
		_result "agent:   failed (ssh-add '${wkey}')"
	fi
}

# _sshd_failed LOG DEFAULT — the summary line for a failed run: the reason
# windows-sshd.ps1 stopped on when it names one in LOG, else DEFAULT. The
# script starts that refusal "reboot pending:" (Install-SshdCapability).
_sshd_failed() {
	local why="$2"
	if grep -q 'reboot pending:' "$1" 2>/dev/null; then
		why="Windows reboot pending: reboot, then re-run setup-system -s sshd"
	fi
	_result "sshd:    failed (${why})"
}

step_sshd() {
	_head "sshd — Windows OpenSSH server, started at boot"
	_sshd_server
	# Whatever became of the server: the agent service may already be
	# running from an earlier run, and the key belongs in it either way.
	if _on_native_windows; then
		_win_agent_key
	fi
}

_sshd_server() {
	# WSL, or native Windows under MSYS2 / Git Bash: the same Windows
	# service either way, reached through a different path translator.
	local topath
	if _on_wsl; then
		topath=wslpath
	elif _on_native_windows; then
		topath=cygpath
	else
		_info "not Windows — on Linux enable the distro's own sshd unit"
		_result "sshd:    skipped (not Windows)"
		return 0
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
	# Native Windows: the same elevated run also turns on the OpenSSH
	# Authentication Agent service, so the box key has an agent pwsh,
	# Windows' ssh.exe and VS Code all reach -- still one elevation (#190).
	if [[ ${topath} == cygpath ]]; then
		ps_args="${ps_args} -SshAgent"
	fi

	# How it elevates, first match wins: this shell already is; an elevated
	# ssh session to this machine's own sshd (every run after a box's first,
	# output streamed back live -- windows.sh says why); under --yes, not at
	# all (skipped: an unattended run must not sit on a hidden prompt); else
	# one UAC prompt.
	local how chan=""
	IFS=' ' read -r how chan <<<"$(win-admin-route "${ASSUME_YES}")"

	if [[ ${DRY_RUN} -eq 1 ]]; then
		case "${how}" in
		elevated) _info "would copy windows-sshd.ps1 to ${wdir} and run it here, already elevated, no prompt:" ;;
		ssh) _info "would copy windows-sshd.ps1 to ${wdir} and run it over the admin ssh channel (${chan}), no UAC prompt:" ;;
		skip)
			# shellcheck disable=SC2154  # assigned in windows.sh, sourced above
			_info "would skip it under --yes: ${WIN_NEEDS_ADMIN}"
			_result "sshd:    skipped (${WIN_NEEDS_ADMIN}) (dry run)"
			return 0
			;;
		*) _info "would copy windows-sshd.ps1 to ${wdir}, raise a UAC prompt and run, elevated:" ;;
		esac
		_info "  windows-sshd.ps1 ${ps_args}"
		_result "sshd:    ok (dry run)"
		return 0
	fi
	if [[ ${how} == skip ]]; then
		_warn "--yes never raises a UAC prompt, and this shell is not elevated"
		_result "sshd:    skipped (${WIN_NEEDS_ADMIN})"
		return 0
	fi

	mkdir -p "${dir}"
	cp "${ps1}" "${dir}/windows-sshd.ps1"
	rm -f "${dir}/log.txt"

	if [[ ${how} == ssh ]]; then
		_info "running over the admin ssh channel (${chan}) -- no UAC prompt"
		# The script is named by the far end's own $env:TEMP -- the same
		# user, so the same directory -- rather than a Windows path spliced
		# into the command. The session survives the sshd restart the script
		# ends with (measured on yoga-x2p).
		local rc=0
		# WIN_SSH_OPTS comes from windows.sh; ps_args expands HERE on purpose
		# (it was checked above to hold no quote). Teed to log.txt, errors
		# included, so the summary can name the reason the script stopped.
		# shellcheck disable=SC2154,SC2029
		ssh "${WIN_SSH_OPTS[@]}" "${chan}" \
			"& (Join-Path \$env:TEMP 'jb-windows-sshd\\windows-sshd.ps1') ${ps_args}" 2>&1 |
			tr -d '\r' | tee "${dir}/log.txt" || rc=$?
		if [[ ${rc} -eq 0 ]]; then
			_result "sshd:    ok (keys from github.com/${user}.keys, over ssh)"
		else
			_sshd_failed "${dir}/log.txt" "see above"
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

	# Already elevated: run.ps1 itself, which this process's token runs
	# elevated; launch.ps1 is only the UAC hop.
	local entry=launch.ps1
	if [[ ${how} == elevated ]]; then
		entry=run.ps1
		_info "already elevated -- running it here, no UAC prompt"
	else
		_info "approve the UAC prompt on the Windows desktop to continue"
	fi
	local rc=0
	(
		cd /mnt/c 2>/dev/null || true
		"${ps_exe}" -NoProfile -ExecutionPolicy Bypass -File "${wdir}\\${entry}"
	) || rc=$?

	if [[ -r "${dir}/log.txt" ]]; then
		# Out-File's utf8 in Windows PowerShell writes a BOM; drop it and the
		# CRs so the relayed lines read like the rest of this output.
		sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "${dir}/log.txt"
	fi
	if [[ ${rc} -eq 0 ]]; then
		_result "sshd:    ok (keys from github.com/${user}.keys)"
	elif [[ ! -r "${dir}/log.txt" && ${how} == elevated ]]; then
		_warn "run.ps1 did not start (exit ${rc})"
		_result "sshd:    failed (see above)"
	elif [[ ! -r "${dir}/log.txt" ]]; then
		_warn "the elevated run did not start — was the UAC prompt declined?"
		_result "sshd:    failed (not elevated)"
	else
		_sshd_failed "${dir}/log.txt" "see the log above"
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
	_GIT_SSH_NOTE=""
	_on_native_windows && _git_ssh_command
	_result "git:     ok (${set_count} default(s) set, ${who_count} identity value(s) set${_GIT_SSH_NOTE:+; ${_GIT_SSH_NOTE}})"
}

# The value _git_ssh_command sets: Windows' own OpenSSH client, spelled with
# forward slashes because git hands core.sshCommand to a shell, which would
# eat backslashes.
_GIT_WIN_SSH="C:/Windows/System32/OpenSSH/ssh.exe"

# _git_ssh_command -- native Windows: point git at Windows' own ssh.exe, the
# client that talks to the Windows ssh-agent service the sshd step puts the
# box key in (#190), so Git for Windows, pwsh and VS Code share one agent.
# Git for Windows' bundled MSYS ssh reaches no agent there at all.
#
# Only where the GLOBAL value is unset: --global is read, never the effective
# value, because the Git for Windows installer may set core.sshCommand (or
# ssh.variant) in the SYSTEM gitconfig (C:\Program Files\Git\etc\gitconfig),
# and that must not stop the user's own setting. A global value that is
# already there is kept and reported. ssh.exe is checked to exist first.
# The outcome goes in _GIT_SSH_NOTE, for the git step's summary line.
_git_ssh_command() {
	local current
	current="$(git config --global --get core.sshCommand 2>/dev/null || true)"
	if [[ -n ${current} ]]; then
		_GIT_SSH_NOTE="core.sshCommand kept: ${current}"
		_info "${_GIT_SSH_NOTE}"
		return 0
	fi
	if ! _win_openssh ssh.exe >/dev/null; then
		_warn "Windows' OpenSSH client (${_GIT_WIN_SSH}) not found -- core.sshCommand left unset"
		_GIT_SSH_NOTE="core.sshCommand not set: no ${_GIT_WIN_SSH}"
		return 0
	fi
	_info "git config --global core.sshCommand ${_GIT_WIN_SSH}"
	_run git config --global core.sshCommand "${_GIT_WIN_SSH}"
	_GIT_SSH_NOTE="core.sshCommand set: ${_GIT_WIN_SSH}"
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

# Directories a step put on THIS run's PATH that the calling shell lacks:
# the end of the run asks for a reload over them, and the jbx shell function
# puts each on the caller's PATH (its marker's `path` line).
_PATH_ADDED=()

# _path_add DIR -- put DIR first on this run's PATH, and record it in
# _PATH_ADDED, unless PATH already has it. For a directory an installer
# just wrote a tool into (uv, claude).
_path_add() {
	case ":${PATH}:" in
	*":$1:"*) ;;
	*)
		PATH="$1:${PATH}"
		_PATH_ADDED+=("$1")
		;;
	esac
	hash -r
}

# tools — uv, then this repo's pre-commit hooks if that applies here.
#
# uv comes from pkg.sh's install-uv, which get-jb.sh and jbx share: winget
# on Windows, so ARM64 gets the native build from an emulated x64 shell
# (#171), astral's install.sh elsewhere. The directory it prints goes first
# on this run's PATH, so the hooks below and the installed report find uv.
step_tools() {
	_head "tools — dev bootstrap"

	local uv_dir
	if _have uv; then
		_info "uv already installed ($(uv --version 2>/dev/null || echo ok))"
	elif [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would run: $(install-uv -n)"
	else
		_info "installing uv"
		if uv_dir="$(install-uv)"; then
			_path_add "${uv_dir}"
			_info "uv installed in ${uv_dir}"
		else
			_warn "uv was not installed"
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

	_sudo_init
	# -f on the symlink, not a bare ln: re-running this step is how an
	# upgrade lands, and a second ln over an existing link is an error
	# rather than a no-op.
	if _priv mkdir -p "${_PWSH_DIR}" &&
		_priv tar zxf "${tarball}" -C "${_PWSH_DIR}" &&
		_priv chmod +x "${_PWSH_DIR}/pwsh" &&
		_priv ln -sf "${_PWSH_DIR}/pwsh" "${_PWSH_LINK}"; then
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

# ---------------------------------------------------------------------------
# claude — Claude Code, by one of the installers Anthropic's setup page
# recommends (https://code.claude.com/docs/en/setup).
#
# Off Windows: install.sh, which puts the binary in ~/.local/bin, which the
# shell step has already put on PATH.
#
# On native Windows (a MINGW/MSYS/CYGWIN uname) install.sh is no use: it
# refuses those unames outright ("Windows is not supported by this script",
# measured 2026-10-31, #189). There, winget (Anthropic.ClaudeCode) first,
# the same shape as install-uv (#171): winget resolves the machine's native
# build by itself (win32-arm64 on an ARM64 box, from an emulated x64 shell
# too) and links the portable exe into winget's Links directory, which goes
# on this run's PATH and into the closing advice as uv's does. A WinGet
# install does not update itself; Anthropic documents
# `winget upgrade Anthropic.ClaudeCode`, or CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE=1
# to have Claude Code run that upgrade for you.
#
# When winget is absent or fails, install.ps1 through Windows PowerShell. It
# chooses its build from $env:PROCESSOR_ARCHITECTURE alone, and a PowerShell
# started from an emulated x64 shell on ARM64 Windows reads AMD64 there. So
# the child PowerShell dot-sources windows-sshd.ps1 for Get-MachineArch --
# the ONE machine-architecture check, a registry read the emulation does not
# virtualise -- and sets PROCESSOR_ARCHITECTURE to the machine's value for
# itself before running the installer. Only that child process sees it.
# ---------------------------------------------------------------------------
_CLAUDE_WINGET_ID="Anthropic.ClaudeCode"
_CLAUDE_INSTALL_SH="https://claude.ai/install.sh"
_CLAUDE_INSTALL_PS1="https://claude.ai/install.ps1"

# _claude_ps1_command SSHD_PS1 -- the PowerShell command that runs
# install.ps1 for this machine's architecture. SSHD_PS1 is the Windows path
# of a file named windows-sshd.ps1: a dot-sourced script must end in .ps1.
_claude_ps1_command() {
	printf '%s' ". $(_ps_literal "$1"); \$env:PROCESSOR_ARCHITECTURE = @{ arm64 = 'ARM64'; x64 = 'AMD64' }[(Get-MachineArch)]; irm $(_ps_literal "${_CLAUDE_INSTALL_PS1}") | iex"
}

# _claude_windows — step_claude's native-Windows half. Reports into the
# summary itself.
_claude_windows() {
	local w dir
	if w="$(winget-bin)"; then
		_info "installing Claude Code"
		if [[ ${DRY_RUN} -eq 1 ]]; then
			_info "would run: $(_winget_install_line "${w}" "${_CLAUDE_WINGET_ID}")"
			_result "claude:  ok (dry run)"
			return 0
		fi
		if dir="$(_winget_portable "${w}" "${_CLAUDE_WINGET_ID}" claude)"; then
			_path_add "${dir}"
			_info "claude installed in ${dir}; run 'claude' to sign in"
			_result "claude:  ok (installed)"
			return 0
		fi
		_warn "winget did not install ${_CLAUDE_WINGET_ID}; falling back to ${_CLAUDE_INSTALL_PS1}"
	fi
	_claude_ps1
}

# _claude_ps1 — install.ps1 through Windows PowerShell, the fallback.
_claude_ps1() {
	local ps src dir wpath cmd rc=0
	if ! ps="$(_powershell_bin)"; then
		_warn "neither winget nor Windows PowerShell found — cannot install Claude Code"
		_result "claude:  skipped (no winget, no PowerShell)"
		return 0
	fi
	if ! src="$(_asset windows-sshd.ps1)"; then
		_result "claude:  failed (windows-sshd.ps1 unavailable)"
		return 0
	fi
	# MSYS rewrites any argument that looks like a POSIX path before a
	# Windows program sees it; the command below carries a URL.
	local -x MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1

	_info "installing Claude Code (install.ps1: no winget)"
	if [[ ${DRY_RUN} -eq 1 ]]; then
		wpath="$(_win_path "${src}")" || wpath="${src}"
		_info "would run: ${ps} -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$(_claude_ps1_command "${wpath}")\""
		_result "claude:  ok (dry run)"
		return 0
	fi
	# _asset may hand back a temp copy with no .ps1 suffix, which
	# PowerShell will not dot-source; a copy under the real name always is.
	dir="$(mktemp -d "${TMPDIR:-/tmp}/jb-claude.XXXXXX")" || {
		_result "claude:  failed"
		return 0
	}
	cp "${src}" "${dir}/windows-sshd.ps1"
	if wpath="$(_win_path "${dir}/windows-sshd.ps1")"; then
		cmd="$(_claude_ps1_command "${wpath}")"
		# -ExecutionPolicy Bypass: a Windows client's default policy,
		# Restricted, refuses to dot-source any script file.
		"${ps}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
			-Command "${cmd}" || rc=$?
	else
		rc=1
	fi
	rm -rf "${dir}"
	if [[ ${rc} -eq 0 ]]; then
		_info "run 'claude' to sign in"
		_result "claude:  ok (installed)"
	else
		_warn "the Claude Code installer failed (install.ps1, exit ${rc})"
		_result "claude:  failed"
	fi
}

step_claude() {
	_head "claude — Claude Code"

	if _have claude; then
		_info "claude already installed"
		_result "claude:  ok (already installed)"
		return 0
	fi
	case "${JB_UNAME_S:-$(uname -s 2>/dev/null || echo unknown)}" in
	MINGW* | MSYS* | CYGWIN*)
		_claude_windows
		return 0
		;;
	esac
	if ! _have curl; then
		_warn "curl not installed — cannot install Claude Code"
		_result "claude:  skipped (no curl)"
		return 0
	fi

	_info "installing Claude Code"
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_info "would run: curl -fsSL ${_CLAUDE_INSTALL_SH} | bash"
		_result "claude:  ok (dry run)"
		return 0
	fi
	if curl -fsSL "${_CLAUDE_INSTALL_SH}" | bash; then
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
	_steps_toml="$(_find_bootstrap_toml)" || exit 1
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
		_on_native_windows && _STEPS_OPT_IN_STR="${_STEPS_OPT_IN_STR/sshd/}"
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
_installed_report
_say ""
# Run from PowerShell, through get-jb.ps1's jbx function (JB_CALLER=pwsh,
# #179): every jbx call there starts a fresh `bash -l`, which reads the rc
# files and ~/.local/bin on its own, so none of the bash reasons below apply
# and `exec bash -l` means nothing to PowerShell. What a PowerShell window
# does lack is a directory an install put on the Windows PATH -- CMake's,
# winget's Links -- and only a new window reads that. Said only when there
# is one.
if [[ ${JB_CALLER:-} == pwsh ]]; then
	for _d in "${_PATH_ADDED[@]+"${_PATH_ADDED[@]}"}"; do
		_window_because "${_d}"
	done
	if [[ ${#_WINDOW_PATH[@]} -gt 0 ]]; then
		_say "open a new PowerShell window: this one predates these PATH changes"
		for _d in "${_WINDOW_PATH[@]}"; do
			_say "    (${_d} is on the Windows PATH, not this window's)"
		done
	fi
	exit 0
fi
# A tool in ~/.local/bin that the calling shell cannot find yet: uv and
# claude install there, and on a fresh box the PATH line that names it is
# exactly what this run just wrote.
case ":${PATH}:" in
*":${HOME}/.local/bin:"*) ;;
*)
	for _t in uv claude; do
		if [[ -x "${HOME}/.local/bin/${_t}" ]]; then
			_reload_because "${HOME}/.local/bin is not on this shell's PATH"
		fi
	done
	;;
esac
# And a directory a step put on this run's PATH: winget's Links, where it
# installed uv on Windows, reaches the USER PATH and so only new shells.
for _d in "${_PATH_ADDED[@]+"${_PATH_ADDED[@]}"}"; do
	_reload_because "${_d} is not on this shell's PATH"
done
# And a tool the report found only on the Windows PATH in the registry: a
# winget install wrote it there, where only new shells look. The jbx
# function's marker puts it on the caller's PATH like the others.
for _d in "${_WINDOW_PATH[@]+"${_WINDOW_PATH[@]}"}"; do
	_reload_because "${_d} is on the Windows PATH, not this shell's"
	_PATH_ADDED+=("${_d}")
done
if [[ ${#_RELOAD[@]} -gt 0 ]]; then
	# Run through the `jbx` shell function (jbx-shell.sh), which exported
	# JB_CALLER_APPLIES: tell it what to apply, in its marker, and it sources
	# that into the very shell that ran us. Only just-bashit's own files,
	# which are written to be sourced again. Anything else -- a direct run, a
	# script, a dry run -- gets the hint.
	if [[ ${JB_CALLER_APPLIES:-0} == 1 && ${DRY_RUN} -eq 0 ]]; then
		_mark="$(jb_reload_marker)"
		mkdir -p "${_mark%/*}"
		{
			[[ -r "${PREFIX}/profile.sh" ]] && printf 'profile %s\n' "${PREFIX}/profile.sh"
			[[ -r "${PREFIX}/bashrc.sh" ]] && printf 'bashrc %s\n' "${PREFIX}/bashrc.sh"
			printf 'path %s\n' "${HOME}/.local/bin"
			for _d in "${_PATH_ADDED[@]+"${_PATH_ADDED[@]}"}"; do
				printf 'path %s\n' "${_d}"
			done
		} >"${_mark}"
		_say "jbx applies this to your shell when setup-system exits:"
	else
		_say "open a new shell, or run: exec bash -l"
	fi
	for _r in "${_RELOAD[@]}"; do
		_say "    (${_r})"
	done
fi
