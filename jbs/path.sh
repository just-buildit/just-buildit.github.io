#!/bin/bash
# ############################################################################
# LIBRARY: path.sh                                                           #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

# shellcheck disable=SC2120
get-scriptpath() {

	# Assume we are running under -u so initialize any referenced variables
	local ARG1=${1:-}

	# Forget getopts, maually parse for handful of inputs
	case $ARG1 in
	-h)

		# Prefer help to commenst since it's user-oriented and runtime-available.
		echo 'Usage: get-scriptpath [-h] ...'
		echo
		echo '  Print path to calling script location. Copy this function'
		echo '  wholecloth into your script to use.'
		echo
		echo 'Options:'
		echo '  -h     Show this message and exit.'
		echo 'Works whether the script is executed or sourced.'
		return 0
		;;

	*)

		# Output path to the calling script's location
		echo "$(
			cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 || exit
			pwd -P
		)"
		;;

	esac

}

set-scriptpath() {

	# Assume we are running under -u so initialize any referenced variables
	local ARG1=${1:-}

	# Forget getopts, maually parse for handful of inputs
	case $ARG1 in
	-h)

		# Prefer help to commenst since it's user-oriented and runtime-available.
		# shellcheck disable=SC2016
		echo 'Usage: eval $(set-scriptpath) | set-scriptpath [-h]'
		echo
		echo '  Set SCRIPTPATH to path to calling script location. Copy this function'
		echo '  wholecloth into your script to use.'
		echo
		echo 'Options:'
		echo '  -h     Show this message and exit.'
		# shellcheck disable=SC2016
		echo 'You must use: eval $(set-scriptpath)'
		echo 'to update the calling environment.'
		return 0
		;;

	*)

		# Set SCRIPTPATH to the caller's location requires get-scriptpath()
		# shellcheck disable=SC2119
		echo "export SCRIPTPATH=$(get-scriptpath)"
		;;

	esac

}
