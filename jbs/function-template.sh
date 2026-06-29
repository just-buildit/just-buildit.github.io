#!/bin/bash
# ############################################################################
# LIBRARY: function-template.sh                                              #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

full-on-template() {

	##########################################################################
	# This is a 'full-on' template. Take only what you need. A lot of useful #
	# functions don't need this complexity. Take a look at the minimalist    #
	# template that immediately follows this one.                            #
	##########################################################################

	# Use 'heredoc' for help to make formatting easier: WYSIWYG
	# Use two spaces for indent of section content as well as minimum space
	# between option/argument names and descriptions, lining them all up.
	local HELP
	IFS= read -r -d '' HELP <<-'EOF'
		Usage: full-on-template [OPTIONS] [-p PARAM] [ARGS] ...

		  Function Title and Short Summary.

		Options:
		  -h        Show this message and exit.
		  -p PARAM  Option that accepts an argument stored in $OPTARG.
		  -v        Show the version and exit.

		Arguments:
		  MYCMD     Some command or other stored in $1
		  MYVAR     Some variable or other stored in $2
	EOF

	# Initialize all referenced variables
	local PARAM=""
	local OPTARG=""
	local OPTIND=0 # Particularly important when sourcing

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hp:v" option; do

		# Parse options.
		case $option in

		# h for help.
		h)
			echo "${HELP}"
			return 0
			;;

		# Unrecognized options set $option to '?'.
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 0
			;;

		# Option taking a parameter stored for later processing.
		p)
			PARAM="${OPTARG}"
			;;

		# Option processed immediately
		v)
			echo "X.Y.Z"
			return 0
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"

	# Make sure all referenced arguments are initialized AFTER getopts processing
	local MYCMD=${1:-} # Conditional assignment to $1 if exists or empty string

	# Process option -p where PARAM could be a command, filename, etc...
	if [ -n "${PARAM}" ]; then
		echo "Option -p specified with argument: ${PARAM}"
		# Do something with PARAM ...
		return 0
	fi

	# Process arguments individually
	# Some command
	somecmd() { echo "Executing cmd()"; }
	if [ "${MYCMD}" == 'SOMECMD' ]; then
		somecmd
		return 0
	fi

	# Process all arguments in a loop
	for arg in "${@}"; do
		echo "Processing argument: ${arg} from \$@ in a loop"
		# Do something with the argument
	done

}

minimalist-template() {

	# Assume we are running under -u so initialize any referenced variables
	ARG1=${1:-}

	# Define a sub-command or action to use
	something-cool() { echo "Doing something cool with ${ARG1}"; }

	# Forget getopts, manually parse for handful of inputs
	case "${ARG1}" in
	-h | "")

		# Prefer help to commenst since it's user-oriented and runtime-available.
		echo 'Usage: minimalist-template [OPTIONS] [-p PARAM] [ARGS] ...'
		echo
		echo '  Summarize what cool thing this function does.'
		echo
		echo 'Options:'
		echo '  -h     Show this message and exit.'
		echo
		echo 'Arguments:'
		# shellcheck disable=SC2016
		echo '  MYVAR  Some variable or other stored in $1'
		return 0
		;;

	*)

		something-cool "${ARG1}"
		;;

	esac

}
