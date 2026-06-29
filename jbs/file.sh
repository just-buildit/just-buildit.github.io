#!/bin/bash
# ############################################################################
# LIBRARY: file.sh                                                           #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

add-line() {

	# Initialize all referenced variables
	local HELP
	local BLANK=1
	local OPTARG=""
	local OPTIND=0

	# Create the help
	read -r -d '' HELP <<-'EOF' || true
		Usage: add-line [OPTIONS] [ENTRY] FILEPATH ...

		  Write ENTRY to FILEPATH only if not already present or if
		          one argument is given, in which case the argument is taken as
		          FILEPATH and a blank line is written.

		Options:
		  -h        Show this message and exit.
		          -x        Don't write blank lines.

		Arguments:
		  ENTRY     Line to write verbatim.
		  FILEPATH  Path to file for writing.

		Note that this function WILL NOT write the same line repeatedly. Except
		        for the blankline case, if the line already exists, no write is performed.
	EOF

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hx" option; do

		# Parse options.
		case $option in

		# h for help.
		h)
			echo "${HELP}"
			return 0
			;;

		# Dont write blank lines.
		x)
			local BLANK=0
			;;

		# Unrecognized options set $option to '?'.
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 0
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"
	local ENTRY=${1:-}
	local FILEPATH=${2:-}

	# For two inputs assume standard operation; if one, treat it as FILEPATH.
	if [ -z "${FILEPATH}" ] && [ -n "${ENTRY}" ]; then
		FILEPATH="${ENTRY}"
		ENTRY=""

	# Print some help if they didn't provide anything.
	else
		echo "Not enough arguments."
		echo "${HELP}"

	fi

	# Check permissions and create if necessary.
	touch "${FILEPATH}"

	if ((BLANK)) && [[ -z ${ENTRY} ]]; then
		echo "" >>"${FILEPATH}"
	else
		# Add entry if not already present using grep options
		# ---------------------------------------------------
		# -q: Quiet; do not write anything to standard output. Exit immediately
		#     with 0 status if any match is found, even if an error was detected.
		# -x: Select only those matches that exactly match the whole line.
		# -F: Interpret patterns as fixed strings, not regular expressions.
		grep -qxF "${ENTRY}" "${FILEPATH}" || echo "${ENTRY}" >>"${FILEPATH}"

		# Ensure the file ends with a trailing newline as it should. Get the last
		# character in the file with 'tail', pipe it to 'read' which produces an
		# error if a file doesn't end with a newline, and if so, trigger an echo
		# which produces a newline appending it to the file.
		tail -c1 "${FILEPATH}" | read -r _ || echo "" >>"${FILEPATH}"
	fi
}

remove-line() {

	# Initialize all referenced variables
	local HELP
	local BLANK=1
	local OPTARG=""
	local OPTIND=0

	read -r -d '' HELP <<-'EOF' || true
		Usage: remove-line [OPTIONS] [ENTRY] FILEPATH ...

		  Remove ENTRY from FILEPATH if present.

		Options:
		  -h        Show this message and exit.
		          -x        Don't remove blank lines.

		Arguments:
		  ENTRY     Line to remove verbatim.
		  FILEPATH  Path to file for line removal.

		Note that this function is a no-op if the given line is not found.
	EOF

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hx" option; do

		# Parse options.
		case $option in

		# h for help.
		h)
			echo "${HELP}"
			return 0
			;;

		# Dont remove blank lines.
		x)
			local BLANK=0
			;;

		# Unrecognized options set $option to '?'.
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 0
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"
	local ENTRY=${1:-}
	local FILEPATH=${2:-}

	# For two inputs assume standard operation; if one, treat it as FILEPATH.
	if [ -z "${FILEPATH}" ]; then
		if [ -n "${ENTRY}" ]; then
			if ((BLANK)); then
				FILEPATH="${ENTRY}"
				ENTRY=""
			else
				return 0
			fi
		else
			echo "Not enough arguments."
			echo "${HELP}"
		fi
	fi

	# Check permissions and create if necessary.
	touch "${FILEPATH}"

	# Remove entry if present using built in editor
	# ---------------------------------------------
	# Delete the exact line in-place; -i'' works on both GNU and BSD sed.
	# shellcheck disable=SC2016
	sed -i'' "/^$(printf '%s' "${ENTRY}" | sed 's/[[\.*^$()+?{}|]/\\&/g')$/d" "${FILEPATH}"

}

add-contents() {

	# Initialize all referenced variables
	local HELP
	local BLANK=1
	local OPTARG=""
	local OPTIND=0

	# Create the help
	read -r -d '' HELP <<-'EOF' || true
		Usage: add-contents [OPTIONS] FROMPATH TOPATH ...

		  Write each line of FROMPATH to TOPATH only if not 
		  already present in TOPATH.

		Options:
		  -h        Show this message and exit.
		          -x        Don't write blank lines.

		Arguments:
		  FROMPATH  Path to file for reading lines.
		  TOPATH    Path to file for writing lines.

	EOF

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hx" option; do

		# Parse options.
		case $option in

		# h for help.
		h)
			echo "${HELP}"
			return 0
			;;

		# Dont write blank lines.
		x)
			local BLANK=0
			;;

		# Unrecognized options set $option to '?'.
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 0
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"
	local FROMPATH=${1:-}
	local TOPATH=${2:-}

	# Read FROMPATH file line by line
	while IFS= read -r line; do
		# Write to TOPATH
		if ((BLANK)); then
			add-line "${line}" "${TOPATH}"
		else
			add-line -x "${line}" "${TOPATH}"
		fi
	done <"$FROMPATH"

}
