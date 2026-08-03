#!/bin/bash
# ############################################################################
# EXECUTABLE: setup-system.sh                                                #
# PACKAGE: just-bashit version 0.3.2                                         #
# ############################################################################
# One command to take a freshly installed machine to a working one: system   #
# packages, shell configuration, ssh, git defaults, and dev tooling. Every   #
# step is idempotent — re-running it is how you upgrade, not a mistake.      #
# ############################################################################
set -euo pipefail
IFS=$'\n\t'

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_SCRIPT_DIR}/toml.sh"
# shellcheck source=/dev/null
source "${_SCRIPT_DIR}/file.sh"

# Pages CDN mirror of src/just_bashit/ — used only when a sibling asset is
# missing, i.e. when this script was fetched standalone by jbx.
_JBS_BASE="${JB_JBS_BASE:-https://just-buildit.github.io/jbs}"

# Order matters: packages first (later steps want git, curl and ssh), shell
# before ssh (the agent lives in the shell config), tools before claude.
# Kept as an array as well as a string because IFS is newline+tab here, so
# a space-separated string does not word-split.
_STEPS_ALL=(deps shell ssh git tools claude)
_STEPS_ALL_STR="deps shell ssh git tools claude"

DRY_RUN=0
VERBOSE=0
ASSUME_YES=0
STEPS_STR=""
STEPS_EXPLICIT=0
SKIP_STR=""
PREFIX="${JB_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/just-bashit}"
KEY_NAME=""
TEMPLATE=""
TEMPLATE_PATH="-"

read -r -d '' HELP <<-'EOF' || true
	Usage: setup-system.sh [OPTIONS]

	  Configure a fresh machine. Runs every step below unless told otherwise,
	  and every step is safe to re-run — nothing is duplicated or clobbered.

	Steps:
	  deps    Install system packages from jb.toml / jb-deps.toml in the
	          current directory (delegates to install-deps). Skipped when no
	          deps file is present.
	  shell   Install the opinionated bash configuration to
	          ~/.config/just-bashit/{bashrc,profile}.sh and add one source
	          line to ~/.bashrc and ~/.profile. Your files stay yours.
	  ssh     Ensure ~/.ssh permissions and an ed25519 key named after this
	          host; print the public key to register with GitHub.
	  git     Set global git defaults that are not already set. Never touches
	          user.name or user.email — those are per-repo identity.
	  tools   Install uv if missing; install pre-commit hooks when the
	          current directory is a repo with .pre-commit-config.yaml.
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
	       --template [PATH]     Write the bashrc template to PATH (or stdout).
	       --template-profile [PATH]
	                             Write the profile template to PATH (or stdout).

	Default steps: all of them. To restrict the default set, declare
	steps = [...] under [tools.setup-system] in jb.toml.

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
step_deps() {
	_head "deps — system packages"

	local deps_file=""
	if [[ -f jb-deps.toml ]]; then
		deps_file="jb-deps.toml"
	elif [[ -f jb.toml ]]; then
		deps_file="jb.toml"
	fi
	if [[ -z ${deps_file} ]]; then
		_info "no jb.toml or jb-deps.toml in $(pwd) — nothing to install"
		_result "deps:    skipped (no deps file)"
		return 0
	fi

	local installer
	installer="$(_asset install-deps.sh)" || {
		_warn "install-deps.sh unavailable"
		_result "deps:    failed (install-deps.sh unavailable)"
		return 0
	}

	_info "installing packages from ${deps_file}"
	local args=()
	[[ ${DRY_RUN} -eq 1 ]] && args+=("--dry-run")
	[[ ${VERBOSE} -eq 1 ]] && args+=("--verbose")
	if bash "${installer}" "${args[@]+"${args[@]}"}" "${deps_file}"; then
		_result "deps:    ok (${deps_file})"
	else
		_warn "install-deps reported a failure"
		_result "deps:    failed"
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

# ssh — directory permissions, then a key if the user has none.
step_ssh() {
	_head "ssh — agent keys"

	# Permissions and the existing-key check come first because neither needs
	# ssh-keygen: a machine with openssh-client absent but keys already synced
	# into place still wants its 0700, and still must not be told it is being
	# skipped. Only generation requires the binary.
	local dir="${HOME}/.ssh"
	_run mkdir -p "${dir}"
	_run chmod 700 "${dir}"

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
		_run chmod 600 "${key}"
		_say ""
		_info "public key — add it to GitHub:"
		_say ""
		cat "${key}.pub"
		_say ""
		_info "gh ssh-key add ${key}.pub --title '${name}'"
	fi
	_result "ssh:     ok (created ${key})"
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

	_info "user.name / user.email deliberately untouched — set them per repo"
	_result "git:     ok (${set_count} default(s) set)"
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
	if [[ -f jb.toml ]]; then
		while IFS= read -r _s; do
			[[ -z ${_s} ]] && continue
			_toml_steps="${_toml_steps:+${_toml_steps},}${_s}"
		done < <(toml_get_array "tools" "setup-system" "steps" <jb.toml)
	fi
	if [[ -n ${_toml_steps} ]]; then
		STEPS_STR="${_toml_steps}"
	else
		STEPS_STR="${_STEPS_ALL_STR// /,}"
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
