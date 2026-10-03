# shellcheck shell=sh
# ############################################################################
# LIBRARY: jbx-shell.sh                                                      #
# PACKAGE: just-bashit                                                       #
# ############################################################################
# A `jbx` shell FUNCTION that applies what setup-system changed to the shell #
# that ran it, instead of telling you to open a new one.                     #
#                                                                            #
# Why a function: jbx runs setup-system as a child process, and no child can #
# change its parent's environment -- that is Unix, not a choice. A function  #
# runs IN the caller's shell, so it can source what the child wrote.         #
#                                                                            #
# The handshake. The function exports JB_CALLER_APPLIES=1 for the child;     #
# setup-system, seeing it, writes the marker below listing what the shell    #
# now lacks, one directive per line:                                         #
#                                                                            #
#   profile FILE   source FILE (POSIX: every shell)                          #
#   bashrc FILE    source FILE when this shell is bash (it is bash-only)     #
#   path DIR       put DIR first on PATH, once                               #
#                                                                            #
# Only just-bashit's own files are ever named: they are written to be        #
# sourced again (PATH entries are added once; a live ssh-agent is adopted,   #
# never a second one started). The user's own ~/.profile is not -- Debian's #
# stock one prepends ~/bin unconditionally -- so it is never re-run.         #
#                                                                            #
# A run started any other way (bash setup-system.sh, a script) exports no    #
# JB_CALLER_APPLIES, writes no marker, and prints the "open a new shell"     #
# hint instead, so a stale marker cannot be applied to some later shell.     #
#                                                                            #
# POSIX sh on purpose -- no `local`, no [[ ]], no arrays -- so it works the  #
# same in bash, zsh, dash and busybox ash, on every distro. Installed by     #
# get-jb.sh (which sources it at once) and by setup-system's shell step;     #
# bashrc.sh sources it in every later shell.                                 #
#                                                                            #
# Example:                                                                   #
#   . ~/.local/share/just-bashit/jbx-shell.sh                                #
#   jbx setup-system          # "jbx: applied to this shell: ..."            #
# ############################################################################

# Where setup-system leaves the marker. One derivation, read by both sides:
# setup-system calls jb_reload_marker too (it sources this file).
jb_reload_marker() {
	printf '%s\n' "${XDG_STATE_HOME:-${HOME}/.local/state}/just-bashit/reload"
}

jbx() {
	JB_CALLER_APPLIES=1 command jbx "$@"
	_jbx_rc=$?
	_jbx_mark=$(jb_reload_marker)
	if [ -f "${_jbx_mark}" ]; then
		_jbx_done=""
		while IFS=' ' read -r _jbx_kind _jbx_arg; do
			case "${_jbx_kind}" in
			profile)
				# shellcheck disable=SC1090  # the path is the marker's
				[ -r "${_jbx_arg}" ] && . "${_jbx_arg}" &&
					_jbx_done="${_jbx_done} ${_jbx_arg##*/}"
				;;
			bashrc)
				if [ -n "${BASH_VERSION:-}" ] && [ -r "${_jbx_arg}" ]; then
					# shellcheck disable=SC1090
					. "${_jbx_arg}" && _jbx_done="${_jbx_done} ${_jbx_arg##*/}"
				fi
				;;
			path)
				case ":${PATH}:" in
				*":${_jbx_arg}:"*) ;;
				*)
					PATH="${_jbx_arg}${PATH:+:${PATH}}"
					export PATH
					_jbx_done="${_jbx_done} PATH+=${_jbx_arg}"
					;;
				esac
				;;
			esac
		done <"${_jbx_mark}"
		rm -f "${_jbx_mark}"
		# Commands found before the run may now resolve elsewhere.
		hash -r 2>/dev/null || true
		if [ -n "${_jbx_done}" ]; then
			printf 'jbx: applied to this shell:%s\n' "${_jbx_done}" >&2
		fi
	fi
	unset _jbx_mark _jbx_done _jbx_kind _jbx_arg
	return "${_jbx_rc}"
}
