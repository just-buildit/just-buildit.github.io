#!/bin/bash
# ############################################################################
# LIBRARY: format.sh                                                         #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

trim-from() {

	read -r -d '' HELP <<-'EOF' || true
		Usage: trim-from [-hrfe] [m MARKER] STRING

		  Trim STRING from MARKER (first occurence, inclusive) to end.

		Options:
		  -h         Show this message and exit.
		  -m MARKER  Character(s) to trim from. Default is '.'.
		  -r         Reverse trim. Trim from MARKER to beginning.
		  -g         Greedy. Trim from last occurence of marker.
		  -k         Keep MARKER instead of including in trim.

		Arguments:
		  STRING     The text to trim.

		Examples:
		  trim-from 12.45            # gives 12
		  trim-from -r 12.45         # gives 45
		  trim-from 12.4.45          # gives 12.4
		  trim-from -g 12.4.45       # gives 12
		  trim-from -kg 12.4.45      # gives 12.
		  trim-from -m MA "HEYMA!"   # gives HEY
		  trim-from -rm MA "HEYMA!"  # gives !
	EOF

	# Initialize all referenced variables
	local OPTARG=""
	local OPTIND=0
	local -i GREEDY=0
	local -i REVERSE=0
	local -i KEEP=0
	local MARKER='.'
	local RESULT=""

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hrgkm:" option; do

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

		r)
			REVERSE=1
			;;

		g)
			GREEDY=1
			;;

		k)
			KEEP=1
			;;

		m)
			MARKER="${OPTARG}"
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"

	# Build the string operator
	local STRING=${1:-}
	if ((REVERSE)); then

		if ((GREEDY)); then
			RESULT="${STRING##*"${MARKER}"}"
		else
			RESULT="${STRING#*"${MARKER}"}"
		fi

		((KEEP)) && RESULT="${MARKER}${RESULT}"

	else

		if ((GREEDY)); then
			RESULT="${STRING%%"${MARKER}"*}"
		else
			RESULT="${STRING%"${MARKER}"*}"
		fi

		((KEEP)) && RESULT+="${MARKER}"

	fi

	printf %s "${RESULT}"

}

color-echo() {

	read -r -d '' HELP <<-'EOF' || true
		Usage: color-echo [OPTIONS] STRING

		  Colorize text (default white) and "echo" (printf + trailing newline).

		Options:
		  -h        Show this message and exit.
		  -c COLOR  One of [black|red|green|yellow|blue|magenta|cyan|white].
		  -b        Bright or bold version of the requested color.

		Arguments:
		  STRING    The text to colorize and print.
	EOF

	# Initialize all referenced variables
	local BOLD=1
	local OPTARG=""
	local OPTIND=0
	local BEGIN="\033["
	local RESET="\033[0m"
	local DEBUG=0
	local ATTRIBUTE=0
	local FOREGROUND=37

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hbdc:" option; do

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

		b)
			ATTRIBUTE="${BOLD}"
			;;

		d)
			DEBUG=1
			;;

		c)
			# ${var,,} requires bash 4+; tr works on bash 3.2 (macOS default).
			local _color_lc
			_color_lc="$(printf '%s' "${OPTARG}" | tr '[:upper:]' '[:lower:]')"
			case "${_color_lc}" in

			black)
				FOREGROUND=30
				;;
			red)
				FOREGROUND=31
				;;
			green)
				FOREGROUND=32
				;;
			yellow)
				FOREGROUND=33
				;;
			blue)
				FOREGROUND=34
				;;
			magenta)
				FOREGROUND=35
				;;
			cyan)
				FOREGROUND=36
				;;
			white)
				FOREGROUND=37
				;;
			*)
				echo "Error: invalid color ${OPTARG}" 1>&2
				return 1
				;;

			esac
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"

	# Print the formatted result
	local TEXTFIELD=${*:-""}
	local FORMATTED_TEXT="${BEGIN}${ATTRIBUTE};${FOREGROUND}m${TEXTFIELD}${RESET}"
	if ((DEBUG)); then
		printf %q "${FORMATTED_TEXT}\\n"
	else
		printf %b "${FORMATTED_TEXT}\\n"
	fi
}
