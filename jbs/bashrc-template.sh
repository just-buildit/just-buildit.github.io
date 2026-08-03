#!/bin/bash
# ############################################################################
# TEMPLATE: bashrc-template.sh                                               #
# PACKAGE: just-bashit version 0.3.1                                         #
# ############################################################################
# Opinionated, cross-distro interactive bash configuration.                  #
#                                                                            #
# Installed by setup-system to ~/.config/just-bashit/bashrc.sh and sourced   #
# from ~/.bashrc by a single line, so your own ~/.bashrc stays yours.        #
#                                                                            #
# Everything here is interactive-only: readline binds, history, shell        #
# options, aliases, prompt, completion. Exports belong in profile.sh, which  #
# this file sources when a login shell has not already done so.              #
#                                                                            #
# Extend, don't edit: drop *.sh files in ~/.config/just-bashit/bashrc.d/ —   #
# they are sourced last and survive re-running setup-system.                 #
#                                                                            #
# Opt-outs — set these before the source line in ~/.bashrc:                  #
#   JB_SSH_AUTOADD=0     do not add ~/.ssh keys to the agent                 #
#   JB_PROMPT=0          leave PS1 alone                                     #
#   JB_PROMPT_GIT=0      prompt without the git branch (fast in huge repos)  #
#   JB_PROMPT_COLOR=0    prompt without colour                               #
#   JB_ALIASES=0         no aliases at all                                   #
#   JB_SAFE_ALIASES=0    aliases, but no interactive rm/cp/mv guards         #
#   JB_COMPLETION=0      do not load bash-completion                         #
# ############################################################################

# Interactive shells only — sourcing this from a script is a no-op.
case $- in
*i*) ;;
*) return 0 ;;
esac

# Where this file lives; bashrc.d/ and profile.sh are found relative to it.
if [[ ${BASH_SOURCE[0]} == */* ]]; then
	JB_DIR="${BASH_SOURCE[0]%/*}"
else
	JB_DIR="."
fi

# Pick up the environment half when no login shell has run ~/.profile —
# the common case for terminal emulators, which start non-login shells.
# Falls back to the repo filename so the template works uninstalled.
if [[ -z ${JB_PROFILE:-} ]]; then
	if [[ -r ${JB_DIR}/profile.sh ]]; then
		# shellcheck source=/dev/null
		source "${JB_DIR}/profile.sh"
	elif [[ -r ${JB_DIR}/profile-template.sh ]]; then
		# shellcheck source=/dev/null
		source "${JB_DIR}/profile-template.sh"
	fi
fi

# ---------------------------------------------------------------------------
# History
#
# Big, deduplicated, timestamped, and appended rather than overwritten so
# that closing one terminal never discards what another one recorded.
# ---------------------------------------------------------------------------
HISTSIZE=100000
HISTFILESIZE=200000
# ignoreboth = ignoredups + ignorespace; erasedups prunes older duplicates.
HISTCONTROL=ignoreboth:erasedups
# Noise that is never worth recalling — and never worth searching past.
HISTIGNORE='ls:ll:la:cd:cd -:pwd:exit:clear:history:bg:fg:jobs'
HISTTIMEFORMAT='%F %T  '

shopt -s histappend # append on exit instead of clobbering
shopt -s cmdhist    # multi-line command becomes one history entry
shopt -s lithist    # ...keeping its newlines rather than semicolons
shopt -s histverify # !! and !$ expand onto the line for review first

# ---------------------------------------------------------------------------
# Shell options
#
# The bash 4 entries are guarded: macOS still ships bash 3.2 as /bin/bash,
# and an unknown shopt name is a hard error, not a warning.
# ---------------------------------------------------------------------------
shopt -s checkwinsize # keep LINES/COLUMNS right after a resize
shopt -s cdspell      # fix small typos in cd arguments
shopt -s extglob      # !(foo) @(a|b) and friends
shopt -s no_empty_cmd_completion

if ((BASH_VERSINFO[0] >= 4)); then
	shopt -s autocd   # `cd` is implied by a bare directory name
	shopt -s dirspell # typo correction during completion too
	shopt -s globstar # ** matches across directories
	shopt -s checkjobs
fi
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))); then
	shopt -s direxpand # complete $VAR/ and ~/ into real paths
fi

# ---------------------------------------------------------------------------
# Readline
#
# The headline binding: Up/Down search history for what you have already
# typed instead of walking blindly backwards. `ssh <Up>` offers your last
# ssh commands, not your last command.
#
# Each key is bound twice because terminals send cursor keys in two modes —
# normal (\e[A, "cursor key mode" off) and application (\eOA, what tmux,
# screen and vi-mode editors switch to). Binding only one form leaves the
# arrows dead in half of your terminals.
# ---------------------------------------------------------------------------
if [[ ${JB_READLINE:-1} == 1 ]]; then
	bind '"\e[A": history-search-backward' 2>/dev/null
	bind '"\e[B": history-search-forward' 2>/dev/null
	bind '"\eOA": history-search-backward' 2>/dev/null
	bind '"\eOB": history-search-forward' 2>/dev/null

	# Ctrl+arrow word motion, Home/End, and Delete — the codes vary by
	# terminfo, so bind the common variants rather than trusting one.
	bind '"\e[1;5C": forward-word' 2>/dev/null
	bind '"\e[1;5D": backward-word' 2>/dev/null
	bind '"\e[5C": forward-word' 2>/dev/null
	bind '"\e[5D": backward-word' 2>/dev/null
	bind '"\e[H": beginning-of-line' 2>/dev/null
	bind '"\e[F": end-of-line' 2>/dev/null
	bind '"\e[1~": beginning-of-line' 2>/dev/null
	bind '"\e[4~": end-of-line' 2>/dev/null
	bind '"\e[3~": delete-char' 2>/dev/null

	bind 'set completion-ignore-case on' 2>/dev/null
	bind 'set completion-map-case on' 2>/dev/null   # - and _ interchange
	bind 'set show-all-if-ambiguous on' 2>/dev/null # one Tab, not two
	bind 'set mark-symlinked-directories on' 2>/dev/null
	bind 'set colored-stats on' 2>/dev/null # readline >= 6.3
	bind 'set colored-completion-prefix on' 2>/dev/null
	bind 'set skip-completed-text on' 2>/dev/null
	bind 'set enable-bracketed-paste on' 2>/dev/null # paste is not typing
	bind 'set bell-style none' 2>/dev/null
fi

# ---------------------------------------------------------------------------
# ssh keys
#
# profile.sh guarantees an agent; this adds the keys, because unlocking a
# passphrase needs a terminal. Only keys the agent does not already hold are
# offered, so exactly one prompt per key per agent lifetime — not one per
# terminal you open.
#
# Any ~/.ssh/NAME with a matching NAME.pub qualifies, so host-named keys work
# as well as the id_* defaults.
# ---------------------------------------------------------------------------
_jb_ssh_add_keys() {
	[[ ${JB_SSH_AUTOADD:-1} == 1 ]] || return 0
	[[ -t 0 ]] || return 0 # no terminal, no passphrase prompt
	command -v ssh-add >/dev/null 2>&1 || return 0
	command -v ssh-keygen >/dev/null 2>&1 || return 0

	local loaded pub key fp
	# Exit 2 means no agent to talk to; there is nothing to add keys to.
	loaded=$(ssh-add -l 2>/dev/null)
	[[ $? -eq 2 ]] && return 0

	for pub in "${HOME}"/.ssh/*.pub; do
		[[ -r ${pub} ]] || continue
		key="${pub%.pub}"
		[[ -r ${key} ]] || continue
		# Field 2 of both outputs is the SHA256: fingerprint.
		fp=$(ssh-keygen -lf "${pub}" 2>/dev/null | awk '{print $2}')
		[[ -z ${fp} ]] && continue
		[[ ${loaded} == *"${fp}"* ]] && continue
		ssh-add "${key}" >/dev/null 2>&1 || ssh-add "${key}" || true
	done
}
_jb_ssh_add_keys

# ---------------------------------------------------------------------------
# Aliases
#
# Colour support is probed, never assumed: GNU/BusyBox take --color=auto,
# BSD (macOS) takes -G and errors on the former.
# ---------------------------------------------------------------------------
if [[ ${JB_ALIASES:-1} == 1 ]]; then

	# Probe before aliasing, never after: once `ls` is an alias, testing it
	# no longer tells you anything about the real binary.
	_jb_ls_color=''
	if ls --color=auto . >/dev/null 2>&1; then
		_jb_ls_color='--color=auto'
		# Teach ls the terminal's palette when dircolors is available.
		if command -v dircolors >/dev/null 2>&1; then
			if [[ -r ${HOME}/.dircolors ]]; then
				eval "$(dircolors -b "${HOME}/.dircolors")"
			else
				eval "$(dircolors -b)"
			fi
		fi
	elif ls -G . >/dev/null 2>&1; then
		_jb_ls_color='-G'
	fi
	if [[ -n ${_jb_ls_color} ]]; then
		# shellcheck disable=SC2139  # expand now: the probe result is fixed
		alias ls="ls ${_jb_ls_color}"
	fi
	unset _jb_ls_color

	alias ll='ls -lh'
	alias la='ls -lAh'
	alias l='ls -CF'
	alias ..='cd ..'
	alias ...='cd ../..'
	alias ....='cd ../../..'

	if echo | grep --color=auto '' >/dev/null 2>&1; then
		alias grep='grep --color=auto'
		alias egrep='grep -E --color=auto'
		alias fgrep='grep -F --color=auto'
	fi
	if diff --color=auto /dev/null /dev/null >/dev/null 2>&1; then
		alias diff='diff --color=auto'
	fi

	alias df='df -h'
	alias du='du -h'
	# BusyBox ships cut-down versions of both; probe before aliasing.
	if free -h >/dev/null 2>&1; then
		alias free='free -h'
	fi
	if ip -color=auto -V >/dev/null 2>&1; then
		alias ip='ip -color=auto'
	fi

	# Guard rails on the three commands that lose data. Bypass any alias
	# for a single run with a leading backslash: \rm -rf build
	if [[ ${JB_SAFE_ALIASES:-1} == 1 ]]; then
		# GNU rm -I asks once for a bulk delete instead of once per file;
		# BSD rm has no such flag, so fall back to -i there.
		if rm --version >/dev/null 2>&1; then
			alias rm='rm -I'
		else
			alias rm='rm -i'
		fi
		alias cp='cp -i'
		alias mv='mv -i'
	fi
fi

# ---------------------------------------------------------------------------
# mkcd DIR — make a directory and step into it.
# ---------------------------------------------------------------------------
mkcd() {
	[[ -n ${1:-} ]] || {
		echo 'usage: mkcd DIR' >&2
		return 2
	}
	mkdir -p -- "$1" && cd -- "$1" || return 1
}

# ---------------------------------------------------------------------------
# Prompt
#
# Reads: [✗2] user@host ~/code/project (main*) $
#
# The exit-status block appears only after a failure, user@host only when the
# session is remote or containerised — noise you can act on, nothing else.
# Colour codes are wrapped in \[ \] so readline knows they occupy no columns;
# without that, long command lines wrap in the wrong place.
# ---------------------------------------------------------------------------
_jb_c_rst='' _jb_c_dir='' _jb_c_git='' _jb_c_err='' _jb_c_at=''
if [[ ${JB_PROMPT_COLOR:-1} == 1 ]] &&
	command -v tput >/dev/null 2>&1 &&
	[[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
	_jb_c_rst='\[\e[0m\]'
	_jb_c_dir='\[\e[1;34m\]'
	_jb_c_git='\[\e[0;33m\]'
	_jb_c_err='\[\e[1;31m\]'
	_jb_c_at='\[\e[0;32m\]'
fi

# ✗ is only safe to print in a UTF-8 locale; elsewhere it becomes mojibake.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
*[Uu][Tt][Ff]*) _jb_fail_mark='✗' ;;
*) _jb_fail_mark='x' ;;
esac

# user@host is worth screen space only when "here" is somewhere else.
_jb_where=''
if [[ -n ${SSH_CONNECTION:-} || -n ${SSH_TTY:-} ]] ||
	[[ -f /.dockerenv || -f /run/.containerenv ]]; then
	_jb_where="${_jb_c_at}\\u@\\h${_jb_c_rst} "
fi

# Terminals that understand OSC 0 get the cwd in their titlebar/tab.
_jb_title=''
case "${TERM:-dumb}" in
xterm* | rxvt* | screen* | tmux* | alacritty* | foot* | wezterm* | konsole*)
	_jb_title='\[\e]0;\u@\h: \w\a\]'
	;;
esac

# ---------------------------------------------------------------------------
# _jb_git_ps1 — " (branch*)" for the current repo, or nothing.
#
# Deliberately cheap: symbolic-ref and a tracked-file diff, no `git status`,
# which walks the whole worktree and stalls the prompt in large repos.
# The * therefore means "tracked changes", untracked files excluded.
# ---------------------------------------------------------------------------
_jb_git_ps1() {
	command -v git >/dev/null 2>&1 || return 0
	local branch dirty=''
	branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) ||
		branch=$(git rev-parse --short HEAD 2>/dev/null) ||
		return 0
	git diff --quiet --ignore-submodules HEAD >/dev/null 2>&1 || dirty='*'
	printf ' (%s%s)' "${branch}" "${dirty}"
}

# ---------------------------------------------------------------------------
# _jb_prompt — PROMPT_COMMAND hook: flush history, then rebuild PS1.
#
# $? must be captured on the very first line, before anything else runs.
# ---------------------------------------------------------------------------
_jb_prompt() {
	local status=$?

	# Write this shell's new history now, so a crashed or killed terminal
	# does not take the session's commands with it.
	history -a

	local fail=''
	((status != 0)) &&
		fail="${_jb_c_err}[${_jb_fail_mark}${status}]${_jb_c_rst} "

	local git=''
	[[ ${JB_PROMPT_GIT:-1} == 1 ]] && git=$(_jb_git_ps1)

	PS1="${_jb_title}${fail}${_jb_where}${_jb_c_dir}\\w${_jb_c_rst}"
	PS1+="${_jb_c_git}${git}${_jb_c_rst}\\$ "
}

if [[ ${JB_PROMPT:-1} == 1 ]]; then
	# Prepend, keeping anything already installed, and only once — this
	# file may be re-sourced by hand without stacking duplicate hooks.
	case "${PROMPT_COMMAND:-}" in
	*_jb_prompt*) ;;
	*) PROMPT_COMMAND="_jb_prompt${PROMPT_COMMAND:+;${PROMPT_COMMAND}}" ;;
	esac
fi

# ---------------------------------------------------------------------------
# bash-completion
#
# One package, five install locations across distros and Homebrew prefixes.
# Skipped when the shell already has it (some distros load it from
# /etc/profile.d) — loading twice is slow, not harmful.
# ---------------------------------------------------------------------------
if [[ ${JB_COMPLETION:-1} == 1 ]] &&
	! shopt -oq posix &&
	[[ -z ${BASH_COMPLETION_VERSINFO:-} ]]; then
	for _jb_bc in \
		/usr/share/bash-completion/bash_completion \
		/etc/bash_completion \
		/usr/local/share/bash-completion/bash_completion \
		/opt/homebrew/etc/profile.d/bash_completion.sh \
		/usr/local/etc/profile.d/bash_completion.sh; do
		if [[ -r ${_jb_bc} ]]; then
			# shellcheck source=/dev/null
			source "${_jb_bc}"
			break
		fi
	done
	unset _jb_bc
fi

# ---------------------------------------------------------------------------
# Local extensions — yours, loaded last, never overwritten by setup-system.
# ---------------------------------------------------------------------------
for _jb_rc in "${JB_DIR}/bashrc.d/"*.sh; do
	if [[ -r ${_jb_rc} ]]; then
		# shellcheck source=/dev/null
		source "${_jb_rc}"
	fi
done
unset _jb_rc

# Marker for anything that needs to know this file has been applied.
# shellcheck disable=SC2034
JB_BASHRC=1
return 0
