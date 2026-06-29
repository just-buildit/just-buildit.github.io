#!/bin/bash
# ############################################################################
# LIBRARY: match.sh                                                          #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

PATTERN_BGN='^'
PATTERN_END='$'
IS_SIGNED='([-+])'
IS_NUMBER='([0-9]+(\.)?|(\.)?[0-9]+)([0-9]*)'
IS_SIGNED_NUMBER="${IS_SIGNED}${IS_NUMBER}"
IS_ONLY_NUMBER="${PATTERN_BGN}${IS_NUMBER}${PATTERN_END}"
IS_ONLY_SIGNED_NUMBER="${PATTERN_BGN}${IS_SIGNED_NUMBER}${PATTERN_END}"

is-number() {

	local HELP
	local ARG1=${1:-}
	local ARG2=${2:-}
	IFS= read -r -d '' HELP <<-'EOF'
		Usage: is-number [-hs] [STRING]

		  PASS (return 0) if STRING is a number otherwise FAIL (return 1).

		Options:
		  -h      Show this message and exit.
		  -s      Allow signed numbers.

		Arguments:
		  STRING  String to test.

		Examples:
		  is-number five   # FAIL
		  is-number -5     # FAIL
		  is-number +5     # FAIL
		  is-number -s -5  # PASS
		  is-number -s +5  # PASS
		  is-number 5      # PASS
		  is-number 5.     # PASS
		  is-number .5     # PASS
		  is-number 22.5   # PASS
	EOF

	case "${ARG1}" in

	-h)
		echo "${HELP}"
		return 0
		;;

	-s)
		[[ 
			${ARG2} =~ $IS_ONLY_NUMBER ||
			${ARG2} =~ $IS_ONLY_SIGNED_NUMBER ]] &&
			return 0 || return 1
		;;

	*)
		[[ ${ARG1} =~ $IS_ONLY_NUMBER ]] && return 0 || return 1
		;;

	esac

}
