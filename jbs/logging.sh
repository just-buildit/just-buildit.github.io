#!/bin/bash
# ############################################################################
# LIBRARY: logging.sh                                                        #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

# Source the environment lib
[[ ${BASH_SOURCE[0]} == */* ]] && LOGGING_SCRIPTPATH=${BASH_SOURCE%/*} || LOGGING_SCRIPTPATH='.'

# shellcheck source=/dev/null
source "${LOGGING_SCRIPTPATH}/format.sh"
# shellcheck source=/dev/null
source "${LOGGING_SCRIPTPATH}/match.sh"
# shellcheck source=/dev/null
source "${LOGGING_SCRIPTPATH}/datetime.sh"

# Define a wait function
log-wait() {

	# Assume we are running under -u so initialize any referenced variables
	local ARG1=${1:-}
	local DURATION=1

	# Forget getopts, manually parse for handful of inputs
	case "${ARG1}" in
	-h | -[a-zA-Z])
		[ "${ARG1}" != "-h" ] && echo "Invalid option: ${ARG1}"
		# Prefer help to commenst since it's user-oriented and runtime-available.
		echo 'Usage: log-wait [-h] DURATION'
		echo
		echo '  Sleep for given duration (default 1 second).'
		echo
		echo 'Options:'
		echo '  -h        Show this message and exit.'
		echo
		echo 'Arguments:'
		echo '  DURATION  Duration to sleep in seconds. Default is 1 second.'
		return 0
		;;

	*)
		if is-number "${ARG1}"; then
			DURATION="${ARG1}"
			sleep "${DURATION}"
		else
			echo "DURATION must be >= 0."
			return 1
		fi
		;;

	esac

}

log() {

	read -r -d '' HELP <<-'EOF' || true
		Usage: log [-hmn] [-t TYPE] [MESSAGE]

		  Log to stdout with format: {TIMESTAMP}::{TYPE} {MESSAGE}.

		Options:
		  -h               Show this message and exit.
		  -m               Increase time resolution from seconds to milliseconds.
		  -u               Increase time resolution from seconds to microseconds.
		  -n               Increase time resolution from seconds to nanoseconds.
		  -t TYPE          One of [INFO|WARNING|DEBUG|ERROR|SUCCESS], default is INFO.
		  -c COLORS        One of [AUTO|ON|OFF]. Default is AUTO.
		  -s 'TYPE COLOR'  User specified TYPE and COLOR where TYPE is an arbitrary word and
		                   color is one of [black|red|green|yellow|blue|magenta|cyan|white].
						   Be sure to enclose the words in quotes.

		Arguments:
		  MESSAGE  Optional message. Arguments are concatenated and logged.

		Examples:
		  log
	EOF

	# Define a mapping of log entry type to color
	local -A LOGFORMAT=([INFO]=white [WARNING]=yellow [DEBUG]=yellow [ERROR]=red [SUCCESS]=green)

	# Initialize all referenced variables
	local OPTARG=""
	local OPTIND=0
	local DEBUG=0
	local -i COLORS=0
	[ -t 1 ] && COLORS=1
	local LOGTYPE='INFO'
	local LOGCOLOR="${LOGFORMAT[${LOGTYPE}]}"
	local RESOLUTION=""

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hmundt:c:s:" option; do

		# Parse options.
		case $option in

		# h for help.
		h)
			echo "${HELP}"
			return 0
			;;

		# Unrecognized options sets $option to '?'.
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 0
			;;

		m)
			RESOLUTION='-m'
			;;

		u)
			RESOLUTION='-u'
			;;

		n)
			RESOLUTION='-n'
			;;

		d)
			DEBUG=1
			;;

		t)
			LOGTYPE="${OPTARG}"
			if [ -n "${LOGFORMAT[${LOGTYPE}]}" ]; then
				LOGCOLOR="${LOGFORMAT[${LOGTYPE}]}"
			else
				echo "Invalid TYPE: ${LOGTYPE}"
				echo "${HELP}"
				return 1
			fi
			;;

		c)
			case "${OPTARG}" in

			ON) COLORS=1 ;;
			OFF) COLORS=0 ;;

			esac
			;;

		s)
			IFS=' ' read -r -a TYPEANDCOLOR <<<"${OPTARG}"
			LOGTYPE="${TYPEANDCOLOR[0]}"
			LOGCOLOR="${TYPEANDCOLOR[1]}"
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"
	if ((COLORS)); then
		if ((DEBUG)); then
			color-echo -dbc "${LOGCOLOR}" "[$(iso-8601-basic "${RESOLUTION}")::${LOGTYPE}]::${*}"
		else
			color-echo -bc "${LOGCOLOR}" "[$(iso-8601-basic "${RESOLUTION}")::${LOGTYPE}]::${*}"
		fi
	else
		echo "[$(iso-8601-basic "${RESOLUTION}")::${LOGTYPE}]::${*}"
	fi

}
