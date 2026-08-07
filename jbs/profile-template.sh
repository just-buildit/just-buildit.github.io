#!/bin/sh
# shellcheck shell=sh
# ############################################################################
# TEMPLATE: profile-template.sh                                              #
# PACKAGE: just-bashit version 0.4.0                                         #
# ############################################################################
# Environment for EVERY shell — login, non-login, interactive and NOT.       #
#                                                                            #
# Installed by setup-system to ~/.config/just-bashit/profile.sh and sourced  #
# from ~/.profile (and ~/.bash_profile when that file exists).               #
#                                                                            #
# Why this file exists separately from bashrc.sh:                            #
#   Every distro's stock ~/.bashrc opens with an interactive-only guard,     #
#                                                                            #
#       case $- in *i*) ;; *) return;; esac                                  #
#                                                                            #
#   so anything exported there reaches interactive terminals and nothing     #
#   else. ~/.profile runs once per LOGIN session instead, and everything     #
#   descended from that session inherits its exports — scripts, language     #
#   servers, agents, GUI apps — whether or not a terminal was involved.      #
#   Exports therefore live HERE, and bashrc.sh sources this file when a      #
#   login shell has not already done so, because terminal emulators start    #
#   non-login shells. Interactive-only settings (readline binds, aliases,    #
#   prompt) live in bashrc.sh and must not be added here.                    #
#                                                                            #
#   Not covered by either file: `ssh host CMD`, which runs a non-login,      #
#   non-interactive shell that reads no rc file at all. That needs           #
#   `ssh host -t bash -lc '...'` or ~/.ssh/environment.                      #
#                                                                            #
# Written in POSIX sh, not bash: ~/.profile is also read by dash and by      #
# desktop session managers. No arrays, no [[ ]], no local-only builtins.     #
#                                                                            #
# Opt-outs — set these before the source line in ~/.profile:                 #
#   JB_SSH_AGENT=0    do not start or adopt an ssh-agent                     #
#   JB_PATH=0         do not touch PATH                                      #
# ############################################################################

# Sourced once per shell. bashrc.sh checks this marker before re-sourcing.
if [ -n "${JB_PROFILE:-}" ]; then
	return 0
fi
JB_PROFILE=1

# ---------------------------------------------------------------------------
# _jb_path_prepend DIR — put DIR first on PATH, once, if it exists.
#
# The ":${PATH}:" wrapping makes the case pattern match whole entries only,
# so /opt/bin never matches an existing /opt/bin-extra.
# ---------------------------------------------------------------------------
_jb_path_prepend() {
	[ -d "$1" ] || return 0
	case ":${PATH}:" in
	*":$1:"*) ;;
	*) PATH="$1${PATH:+:${PATH}}" ;;
	esac
}

# ---------------------------------------------------------------------------
# XDG base directories.
#
# Exported rather than assumed: plenty of tools read them, few default them,
# and the rest of this file uses them for cache and state paths.
# ---------------------------------------------------------------------------
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
: "${XDG_DATA_HOME:=${HOME}/.local/share}"
: "${XDG_STATE_HOME:=${HOME}/.local/state}"
: "${XDG_CACHE_HOME:=${HOME}/.cache}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

# ---------------------------------------------------------------------------
# PATH.
#
# ~/.local/bin is where pip --user, uv tool, pipx and the Claude Code
# installer land binaries; it is on PATH by default on almost nothing.
# ---------------------------------------------------------------------------
if [ "${JB_PATH:-1}" = 1 ]; then
	_jb_path_prepend "${HOME}/bin"
	_jb_path_prepend "${HOME}/.local/bin"
	_jb_path_prepend "${HOME}/.cargo/bin"
	_jb_path_prepend "${HOME}/go/bin"
	export PATH
fi

# ---------------------------------------------------------------------------
# Editor and pager.
#
# First editor actually installed wins; vi is guaranteed, nano is the kinder
# fallback where it exists.
# ---------------------------------------------------------------------------
if [ -z "${EDITOR:-}" ]; then
	for _jb_ed in nvim vim vi nano; do
		if command -v "${_jb_ed}" >/dev/null 2>&1; then
			EDITOR="${_jb_ed}"
			break
		fi
	done
	unset _jb_ed
	[ -n "${EDITOR:-}" ] && export EDITOR
fi
: "${VISUAL:=${EDITOR:-vi}}"
export VISUAL

if command -v less >/dev/null 2>&1; then
	export PAGER=less
	# -R real colours, -i smart-case search, -M verbose status line,
	# -F quit if it fits on one screen, -X would break the alternate
	# screen so it is deliberately absent.
	: "${LESS:=-R -i -M -F}"
	export LESS
	export LESSHISTFILE="${XDG_STATE_HOME}/less_history"
fi

# ---------------------------------------------------------------------------
# GPG needs to know which terminal to prompt on; only meaningful with a tty.
# ---------------------------------------------------------------------------
if [ -t 0 ] && command -v gpg >/dev/null 2>&1; then
	GPG_TTY=$(tty 2>/dev/null) && export GPG_TTY
fi

# ---------------------------------------------------------------------------
# _jb_agent_live — true when SSH_AUTH_SOCK points at a reachable agent.
#
# ssh-add -l exits 0 with keys loaded, 1 when the agent is up but empty, and
# 2 when it cannot connect at all. Only 2 means "no agent".
# ---------------------------------------------------------------------------
_jb_agent_live() {
	[ -n "${SSH_AUTH_SOCK:-}" ] || return 1
	[ -S "${SSH_AUTH_SOCK}" ] || return 1
	ssh-add -l >/dev/null 2>&1
	[ "$?" -ne 2 ]
}

# ---------------------------------------------------------------------------
# _jb_ssh_agent — guarantee exactly one agent per user, per machine.
#
# Order matters. An inherited SSH_AUTH_SOCK always wins: that is a forwarded
# agent, systemd's socket-activated ssh-agent.service, gnome-keyring, or
# 1Password, and hijacking any of them would lose the user's keys. Only when
# nothing is listening do we start one on a fixed socket path, so the next
# login reuses it instead of leaking a new agent process per shell.
# ---------------------------------------------------------------------------
_jb_ssh_agent() {
	[ "${JB_SSH_AGENT:-1}" = 1 ] || return 0
	command -v ssh-agent >/dev/null 2>&1 || return 0
	command -v ssh-add >/dev/null 2>&1 || return 0

	_jb_agent_live && return 0

	# XDG_RUNTIME_DIR is tmpfs cleaned at logout on systemd; macOS and
	# containers have no such thing, so fall back to a private 0700 dir.
	_jb_rt="${XDG_RUNTIME_DIR:-}"
	if [ -z "${_jb_rt}" ] || [ ! -d "${_jb_rt}" ]; then
		_jb_rt="${TMPDIR:-/tmp}/ssh-$(id -u)"
		mkdir -p "${_jb_rt}" 2>/dev/null || return 0
		chmod 700 "${_jb_rt}" 2>/dev/null || true
	fi

	SSH_AUTH_SOCK="${_jb_rt}/just-bashit-agent.sock"
	export SSH_AUTH_SOCK
	_jb_env="${_jb_rt}/just-bashit-agent.env"
	unset _jb_rt

	# A socket left by an earlier login may still have a live agent behind
	# it — adopt it. Otherwise it is stale and must go before binding.
	_jb_agent_live && return 0
	rm -f "${SSH_AUTH_SOCK}" 2>/dev/null || true

	# The agent's stdio must be detached from whatever this shell inherited,
	# and that rules out `eval "$(ssh-agent ...)"`. Command substitution
	# hands the daemon the write end of a pipe, which it keeps open for its
	# whole life — and anything reading that pipe then never sees EOF. A CI
	# job or a script that sources this file hangs until something kills it:
	# six hours, in the case that found this.
	#
	# Writing the exports to a file instead gives the daemon stdin, stdout
	# and stderr that hold nothing open: /dev/null, a regular file, and
	# /dev/null.
	if ! ssh-agent -s -a "${SSH_AUTH_SOCK}" >"${_jb_env}" 2>/dev/null \
		</dev/null; then
		rm -f "${_jb_env}" 2>/dev/null
		unset _jb_env
		return 0
	fi
	# shellcheck source=/dev/null
	. "${_jb_env}" >/dev/null 2>&1
	rm -f "${_jb_env}" 2>/dev/null
	unset _jb_env
}

_jb_ssh_agent

# Keys are added by bashrc.sh, not here: unlocking a passphrase-protected key
# needs a terminal, and this file is sourced by shells that have none.

return 0
