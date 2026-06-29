#!/bin/bash
# ############################################################################
# LIBRARY: environment.sh                                                    #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

set-bashrc() {

	# Initialize all referenced variables
	local HELP
	local OPTARG=""
	local OPTIND=0
	local BASHRC="${HOME}/.bashrc"

	# Create the help
	read -r -d '' HELP <<-'EOF' || true
		Usage: set-bashrc [OPTIONS] KEY_OR_ENTRY [VALUE] ...

		  Write a line to ~/.bashrc ONLY if not already present.

		Options:
		  -h        Show this message and exit.

		Arguments:
		  KEY_OR_ENTRY  Line to write verbatim if given alone, otherwise interpreted
		                as a KEY given VALUE is provided to complete the pair. In the
		                latter case the line written is "export KEY=VALUE".
		  VALUE         The value associated with the provided KEY.

		Note that this function WILL NOT write the same line repeatedly. If the line
		already exists, no write is performed.
	EOF

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":h" option; do

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

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"
	local BASHRC_KEY_OR_ENTRY=${1:-}
	local BASHRC_VALUE=${2:-}

	# For two inputs assume key-value pair.
	if [ -n "${BASHRC_VALUE}" ]; then
		local BASHRC_ENTRY="export ${BASHRC_KEY_OR_ENTRY}=${BASHRC_VALUE}"

	# If only one input, use as is.
	elif [ -n "${BASHRC_KEY_OR_ENTRY}" ]; then
		local BASHRC_ENTRY="${BASHRC_KEY_OR_ENTRY}"

	# Print some help if they didn't provide anything.
	else
		echo "Not enough arguments."
		echo "${HELP}"

	fi

	# Check permissions and create if necessary.
	touch "${BASHRC}"

	# Ensure the file ends with a trailing newline as it should. Get the last
	# character in the file with 'tail', pipe it to 'read' which produces an
	# error if a file doesn't end with a newline, and if so, trigger an echo
	# which produces a newline appending it to the file.
	tail -c1 "${BASHRC}" | read -r _ || echo "" >>"${BASHRC}"

	# Add entry if not already present using grep options
	# ---------------------------------------------------
	# -q: Quiet; do not write anything to standard output. Exit immediately
	#     with 0 status if any match is found, even if an error was detected.
	# -x: Select only those matches that exactly match the whole line.
	# -F: Interpret patterns as fixed strings, not regular expressions.
	grep -qxF "${BASHRC_ENTRY}" "${BASHRC}" || echo "${BASHRC_ENTRY}" >>"${BASHRC}"

}

unset-bashrc() {

	# Initialize all referenced variables
	local HELP
	local OPTARG=""
	local OPTIND=0
	local BASHRC="${HOME}/.bashrc"

	read -r -d '' HELP <<-'EOF' || true
		Usage: unset-bashrc [OPTIONS] KEY_OR_ENTRY [VALUE] ...

		  Remove requested line from ~/.bashrc if present.

		Options:
		  -h        Show this message and exit.

		Arguments:
		  KEY_OR_ENTRY  Line to remove verbatim if given alone, otherwise interpreted
		                as a KEY, given VALUE is provided to complete the pair. In the
		                latter case the line searched for is "export KEY=VALUE".
		  VALUE         The value associated with the provided KEY.

		Note that this function is a no-op if the given line is not found.
	EOF

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":h" option; do

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

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"

	# For two inputs assume key-value pair.
	local BASHRC_VALUE=${2:-}
	local BASHRC_KEY_OR_ENTRY=${1:-}
	if [ -n "${BASHRC_VALUE}" ]; then
		local BASHRC_ENTRY="export ${BASHRC_KEY_OR_ENTRY}=${BASHRC_VALUE}"

	# If only one input, use as is.
	elif [ -n "${BASHRC_KEY_OR_ENTRY}" ]; then
		local BASHRC_ENTRY="${BASHRC_KEY_OR_ENTRY}"

	# Print some help if they didn't provide anything.
	else
		echo "Not enough arguments."
		echo "${HELP}"

	fi

	# Check permissions and create if necessary.
	touch "${BASHRC}"

	# Remove entry if present using built in editor
	# ---------------------------------------------
	# Delete the exact line in-place; -i'' works on both GNU and BSD sed.
	# shellcheck disable=SC2016
	sed -i'' "/^$(printf '%s' "${BASHRC_ENTRY}" | sed 's/[[\.*^$()+?{}|]/\\&/g')$/d" "${BASHRC}"

}

check-command-exists() {

	# Assume we are running under -u so initialize any referenced variables
	local ARG1=${1:-}

	# Forget getopts, manually parse for handful of inputs
	case "${ARG1}" in
	-h)

		# Prefer help to commenst since it's user-oriented and runtime-available.
		echo 'Usage: check-command-exists [-h]'
		echo
		echo '  Does just that. Exits with 0 if true 1 if false.'
		echo
		echo 'Options:'
		echo '  -h     Show this message and exit.'
		return 0
		;;

	*)
		command -v "${ARG1}" >/dev/null 2>&1
		;;

	esac

}
