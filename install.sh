#!/usr/bin/env bash
# ############################################################################
# SCRIPT: install.sh                                                         #
# PACKAGE: just-bashit version 0.1.4                                         #
# ############################################################################
# Installs just-runit (alias: jr) to ~/.local/bin and updates PATH.         #
#                                                                             #
# Must be sourced so PATH exports reach the calling shell:                   #
#   . <(curl -sSL https://raw.githubusercontent.com/just-buildit/just-bashit/main/src/install.sh)
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

    _jbs_say()  { printf "${CYAN}  ->  ${RESET}${BOLD}%s${RESET}\n" "$*"; }
    _jbs_ok()   { printf "${GREEN}  ok  ${RESET}%s\n" "$*"; }
    _jbs_warn() { printf "${YELLOW}  !!  ${RESET}%s\n" "$*"; }

    # -- install dir -----------------------------------------------------------

    _jbs_say "install dir: ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"

    # -- download just-runit ---------------------------------------------------

    _jbs_say "downloading just-runit from ${RUNIT_URL}"
    if ! curl -sSL --proto '=https' --tlsv1.2 \
            -o "${INSTALL_DIR}/just-runit" "${RUNIT_URL}"; then
        printf "\033[1;31m  !!  \033[0mfailed to download just-runit\n" >&2
        return 1
    fi
    chmod +x "${INSTALL_DIR}/just-runit"
    _jbs_ok "just-runit installed"

    # -- jr symlink ------------------------------------------------------------

    _jbs_say "creating jr symlink"
    ln -sf just-runit "${INSTALL_DIR}/jr"
    _jbs_ok "jr -> just-runit"

    # -- PATH ------------------------------------------------------------------

    if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
        _jbs_say "adding ${INSTALL_DIR} to PATH (current shell)"
        export PATH="${INSTALL_DIR}:${PATH}"

        local entry="export PATH=\"\${HOME}/.local/bin:\${PATH}\""
        if ! grep -qF '.local/bin' "${BASHRC}" 2>/dev/null; then
            _jbs_say "persisting PATH to ${BASHRC}"
            printf '\n%s\n' "${entry}" >> "${BASHRC}"
            _jbs_ok "added to ${BASHRC}"
        else
            _jbs_warn "${BASHRC} already references .local/bin — skipped"
        fi
    else
        _jbs_ok "${INSTALL_DIR} already in PATH"
    fi

    # -- confirm ---------------------------------------------------------------

    printf '\n%b\n\n' "${GREEN}${BOLD}  just-runit and jr are ready.${RESET}"
    printf '  %bjr -h%b              show help\n' "${BOLD}" "${RESET}"
    printf '  %bjr jbs:datetime iso-8601-basic%b   quick test\n\n' \
        "${BOLD}" "${RESET}"

}

_jbs_install "$@"
unset -f _jbs_install _jbs_say _jbs_ok _jbs_warn
