#!/usr/bin/env bash
# ############################################################################
# SCRIPT: get-just-runit.sh                                                  #
# PACKAGE: just-bashit version 0.1.4                                         #
# ############################################################################
# Installs just-runit (just-buildit / jb / jbx) to ~/.local/bin.            #
#                                                                             #
# Must be sourced so PATH exports reach the calling shell:                   #
#   . <(curl -sSL https://just-buildit.github.io/get-just-runit.sh)         #
#                                                                             #
# To force reinstall even when already current:                              #
#   JB_REINSTALL=1 . <(curl -sSL https://just-buildit.github.io/get-just-runit.sh)
# ############################################################################

# Wrapped in a function so locals don't leak and we can clean up afterward.
_jbs_install() {

	local INSTALL_DIR="${HOME}/.local/bin"
	local RAW_BASE
	RAW_BASE="https://raw.githubusercontent.com/just-buildit/just-bashit/main/src"
	local RUNIT_URL="${RAW_BASE}/just-runit"
	local BASHRC="${HOME}/.bashrc"

	local BOLD="\033[1m"
	local GREEN="\033[1;32m"
	local CYAN="\033[1;36m"
	local YELLOW="\033[1;33m"
	local RESET="\033[0m"

	_jbs_say() { printf "${CYAN}  ->  ${RESET}${BOLD}%s${RESET}\n" "$*"; }
	_jbs_ok() { printf "${GREEN}  ok  ${RESET}%s\n" "$*"; }
	_jbs_warn() { printf "${YELLOW}  !!  ${RESET}%s\n" "$*"; }

	# -- disclaimer ------------------------------------------------------------

	printf '%b' "${YELLOW}${BOLD}"
	printf '  +----------------------------------------------------------+\n'
	printf '  |  This script is provided AS IS, without warranty of any  |\n'
	printf '  |  kind. Review the source before running:                 |\n'
	printf '  |  https://just-buildit.github.io/get-just-runit.sh       |\n'
	printf '  |                                                          |\n'
	printf '  |  The tool it installs fetches and executes arbitrary     |\n'
	printf '  |  code from URLs you provide. It performs no review,      |\n'
	printf '  |  scanning, or sandboxing. You are solely responsible     |\n'
	printf '  |  for what you choose to run.                             |\n'
	printf '  |                                                          |\n'
	printf '  |  Use at your own risk.                                   |\n'
	printf '  +----------------------------------------------------------+\n'
	printf '%b\n' "${RESET}"

	# -- install dir -----------------------------------------------------------

	_jbs_say "install dir: ${INSTALL_DIR}"
	mkdir -p "${INSTALL_DIR}"

	# -- version-aware download -----------------------------------------------

	local tmp_runit
	tmp_runit=$(mktemp /tmp/just-runit.XXXXXX)
	# shellcheck disable=SC2064
	trap "rm -f '${tmp_runit}'" RETURN

	_jbs_say "fetching just-runit from ${RUNIT_URL}"
	if ! curl -sSL --proto '=https' --tlsv1.2 -o "${tmp_runit}" "${RUNIT_URL}"; then
		printf "\033[1;31m  !!  \033[0mfailed to download just-runit\n" >&2
		return 1
	fi

	local new_ver
	new_ver=$(grep '^_VERSION=' "${tmp_runit}" | cut -d'"' -f2)
	new_ver="${new_ver:-unknown}"

	local installed="${INSTALL_DIR}/just-runit"
	if [[ -x ${installed} ]]; then
		local cur_ver
		cur_ver=$(grep '^_VERSION=' "${installed}" | cut -d'"' -f2)
		cur_ver="${cur_ver:-unknown}"

		if [[ ${cur_ver} == "${new_ver}" && ${JB_REINSTALL:-0} != "1" ]]; then
			_jbs_ok "already at v${cur_ver} — set JB_REINSTALL=1 to force reinstall"
		else
			if [[ ${cur_ver} != "${new_ver}" ]]; then
				_jbs_say "upgrading v${cur_ver} -> v${new_ver}"
			else
				_jbs_say "reinstalling v${new_ver}"
			fi
			cp "${tmp_runit}" "${installed}"
			chmod +x "${installed}"
			_jbs_ok "just-runit v${new_ver} installed"
		fi
	else
		_jbs_say "installing v${new_ver}"
		cp "${tmp_runit}" "${installed}"
		chmod +x "${installed}"
		_jbs_ok "just-runit v${new_ver} installed"
	fi

	# -- remove stale aliases from prior naming schemes -----------------------

	local stale
	for stale in jr jx; do
		local stale_path="${INSTALL_DIR}/${stale}"
		if [[ -L ${stale_path} && "$(readlink -f "${stale_path}")" == "$(readlink -f "${INSTALL_DIR}/just-runit")" ]]; then
			rm -f "${stale_path}"
			_jbs_warn "removed stale alias: ${stale}"
		fi
	done

	# -- just-buildit symlink (always created — canonical long name) -----------

	ln -sf just-runit "${INSTALL_DIR}/just-buildit"
	_jbs_ok "just-buildit -> just-runit"

	# -- jb symlink (short alias — skipped if jb is already someone else's) ---

	local _jb_cmd
	_jb_cmd="$(command -v jb 2>/dev/null || true)"
	local _JB_NAME="jb"
	if [[ -n ${_jb_cmd} && "$(readlink -f "${_jb_cmd}")" != "$(readlink -f "${INSTALL_DIR}/just-runit")" ]]; then
		_jbs_warn "'jb' is already in use (${_jb_cmd}) — skipping short alias"
		_jbs_warn "use 'just-buildit' instead (always available)"
		_JB_NAME="just-buildit"
	else
		ln -sf just-runit "${INSTALL_DIR}/jb"
		_jbs_ok "jb -> just-runit"
	fi

	# -- jbx symlink (runner shorthand, always created) -----------------------

	ln -sf just-runit "${INSTALL_DIR}/jbx"
	_jbs_ok "jbx -> just-runit"

	# -- PATH ------------------------------------------------------------------

	if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
		_jbs_say "adding ${INSTALL_DIR} to PATH (current shell)"
		export PATH="${INSTALL_DIR}:${PATH}"

		# shellcheck disable=SC2016
		local entry='export PATH="${HOME}/.local/bin:${PATH}"'
		if ! grep -qF '.local/bin' "${BASHRC}" 2>/dev/null; then
			_jbs_say "persisting PATH to ${BASHRC}"
			printf '\n%s\n' "${entry}" >>"${BASHRC}"
			_jbs_ok "added to ${BASHRC}"
		else
			_jbs_warn "${BASHRC} already references .local/bin — skipped"
		fi
	else
		_jbs_ok "${INSTALL_DIR} already in PATH"
	fi

	# -- uv (enables Python PEP 723 dep resolution) ---------------------------

	if command -v uv >/dev/null 2>&1; then
		_jbs_ok "uv found — Python PEP 723 support ready"
	else
		_jbs_say "installing uv (Python PEP 723 support)"
		"${INSTALL_DIR}/just-runit" https://astral.sh/uv/install.sh
		if command -v uv >/dev/null 2>&1; then
			_jbs_ok "uv installed"
		else
			_jbs_warn "uv installed — open a new shell if 'uv' isn't found"
		fi
	fi

	# -- confirm ---------------------------------------------------------------

	printf '\n%b\n\n' "${GREEN}${BOLD}  just-buildit is ready.${RESET}"
	printf '  %b%s -h%b                           show help\n' \
		"${BOLD}" "${_JB_NAME}" "${RESET}"
	printf '  %b%s run just-bashit:datetime iso-8601-basic%b  quick test\n\n' \
		"${BOLD}" "${_JB_NAME}" "${RESET}"

}

_jbs_install "$@"
unset -f _jbs_install _jbs_say _jbs_ok _jbs_warn
