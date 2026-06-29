#!/bin/bash
# ############################################################################
# LIBRARY: datetime.sh                                                       #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

iso-8601-basic() {

	# Initialize all referenced variables
	local HELP
	local DATE='now'
	local OPTARG=""
	local OPTIND=0
	local DIGITS=0
	local FRACTION=""
	local TIMESTAMP=""
	local MSEC_DIGITS=3
	local USEC_DIGITS=6
	local NANO_DIGITS=9

	# Create the help
	read -r -d '' HELP <<-'EOF' || true
		Usage: iso-8601-basic [-d DATE] [-m|u|n]

		  Basic-Format ISO 8601 Timestamp.

		Options:
		  -h       Show this message and exit.
		  -d DATE  UTC date and time to use instead of the default 'now'.
		  -m       Show milliseconds (default is seconds).
		  -u       Show microseconds (default is seconds).
		  -n       Show nanoseconds (default is seconds).

		Path and file-name-friendly characters only are generated:

		  YYYYMMDDThhmmss[.fff[fff]]Z

		Where

		  - YYYY is the 4 digit year.
		  - MM is the two digit month.
		  - DD is the two digit day.
		  - hh is the two digit hour.
		  - mm is the two digit minute.
		  - ss is the two digit second.
		  - .fff is the 3 digit millisecond.
		  - .ffffff is the 6 digit microsecond.
		  - .fffffffff is the 9 digit nanosecond.
	EOF

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hd:mun" option; do

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
		d)
			DATE="${OPTARG}"
			;;

		# Option processed immediately
		m)
			DIGITS="${MSEC_DIGITS}"
			;;

		# Option processed immediately
		u)
			DIGITS="${USEC_DIGITS}"
			;;

		# Option processed immediately
		n)
			DIGITS="${NANO_DIGITS}"
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"

	# Compute the full precision timestamp
	# Use gdate (GNU date) on macOS where system date is BSD date.
	local _date_cmd
	_date_cmd=$(command -v gdate 2>/dev/null || command -v date)
	TIMESTAMP=$("${_date_cmd}" --utc --date="${DATE}" +"%Y%m%dT%H%M%S.%N")

	# Separate and truncate the seconds if needed
	FRACTION="${TIMESTAMP##*.}"
	if ((DIGITS)); then
		echo "${TIMESTAMP%%.*}.${FRACTION:0:DIGITS}Z"
	else
		echo "${TIMESTAMP%%.*}Z"
	fi

}
