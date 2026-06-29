#!/bin/bash
# ############################################################################
# LIBRARY: network.sh                                                        #
# PACKAGE: just-bashit version 0.2.0                                         #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

# Source the environment lib
[[ ${BASH_SOURCE[0]} == */* ]] && NETWORK_SCRIPTPATH=${BASH_SOURCE%/*} || NETWORK_SCRIPTPATH='.'

# shellcheck source=/dev/null
source "${NETWORK_SCRIPTPATH}/format.sh"
# shellcheck source=/dev/null
source "${NETWORK_SCRIPTPATH}/environment.sh"

test-internet-access() {

	# Assume we are running under -u so initialize any referenced variables
	local ARGS=(https://example.com https://pypi.org https://google.com)
	local HELP=""
	local OPTARG=""
	local -i OPTIND=0
	local -i VERBOSE=0
	local -i TIMEOUT=20
	local COMMANDS=(curl wget ping)
	local PING_OPTIONS=(-q -c 1)
	local WGET_OPTIONS=(--quiet --spider --inet4-only)
	local CURL_OPTIONS=(--silent --output /dev/null --head --show-error --fail-early --ipv4)
	local PING_VERBOSE_OPTIONS=(-v -c 1)
	local WGET_VERBOSE_OPTIONS=(--verbose --spider --show-progress --inet4-only)
	local CURL_VERBOSE_OPTIONS=(--verbose --head --show-error --fail --ipv4)

	read -r -d '' HELP <<-'EOF' || true
		Usage: test-internet-access [-hv] [-t TIMEOUT] [URL] ...

		  Test internet connection and return PASS(0)/FAIL(1).

		Options:
		  -h          Show this message and exit.
		  -v          Verbose mode. Prints status messages.
		  -t TIMEOUT  Total test timeout in seconds (default 20). Disable with 'false'.

		Arguments:
		  URL         URLs (e.g. google.com) and or IPs (e.g. 1.1.1.1) to test.

		Example Usage:
		  test-internet-access # Silently test mutliple sites.
		  test-internet-access -vt 10 # Timeout 10s, print status.
		  test-internet-access -t 1 bing.com 1.1.1.1 # Timeout 1s, test 2 websites.

		The default tests 1.1.1.1, 8.8.8.8, example.com, pypi.org, and google.com
		using ping, wget, and curl (if available), exiting on the first success or
		waiting until all fail.
	EOF

	# Specify options. Add ':' to start and after options that take arguments.
	while getopts ":hvt:" option; do

		# Parse options.
		case $option in

		h)
			echo "${HELP}"
			return 0
			;;

		v)

			VERBOSE=1
			;;

		t)

			if [[ $OPTARG =~ (^[0-9]+$|^false$) ]]; then
				TIMEOUT="${OPTARG}"
			else
				echo "Invalid Value for TIMEOUT: must be integer or false."
				echo "${HELP}"
				return 0
			fi
			;;

		\?)

			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 0
			;;

		esac

	done

	# Remove options from the input list $@ so the first remaining argument is $1.
	shift "$((OPTIND - 1))"
	local -a URL=("$@")
	[[ ${#URL[@]} -eq 0 ]] && URL=("${ARGS[@]}")

	# Print status if verbose
	if ((VERBOSE == 1)); then
		echo "URL:" "${URL[@]}"
		echo "Timeout: ${TIMEOUT} seconds"
	fi

	# Update available commands
	local AVAILABLE_COMMANDS=()
	for COMMAND in "${COMMANDS[@]}"; do

		if check-command-exists "${COMMAND}"; then

			AVAILABLE_COMMANDS+=("${COMMAND}")
			((VERBOSE == 1)) && echo "${COMMAND} command found!"

		elif ((VERBOSE == 1)); then
			echo "${COMMAND} command not found!"
		fi

	done

	[[ ${#AVAILABLE_COMMANDS[@]} -eq 0 ]] && return 1

	# Select arguments
	local ARGS=()
	local -i TIME_REMAINING="${TIMEOUT}"
	local PING_ARGS=("${PING_OPTIONS[@]}")
	local WGET_ARGS=("${WGET_OPTIONS[@]}")
	local CURL_ARGS=("${CURL_OPTIONS[@]}")
	if ((VERBOSE == 1)); then
		PING_ARGS=("${PING_VERBOSE_OPTIONS[@]}")
		WGET_ARGS=("${WGET_VERBOSE_OPTIONS[@]}")
		CURL_ARGS=("${CURL_VERBOSE_OPTIONS[@]}")
	fi

	# Start the timeout counter and begin testing
	local BEGIN
	BEGIN=$(date +%s)
	for SITE in "${URL[@]}"; do

		for COMMAND in "${AVAILABLE_COMMANDS[@]}"; do

			local REM="${TIME_REMAINING}"
			ARGS=("${REM}s")
			case "${COMMAND}" in
			ping) ARGS+=(ping -W "${REM}" "${PING_ARGS[@]}") ;;
			wget) ARGS+=(wget --timeout "${REM}" "${WGET_ARGS[@]}") ;;
			curl) ARGS+=(curl --max-time "${REM}" "${CURL_ARGS[@]}") ;;
			esac

			# Get outta here if we establish connectivity
			if timeout "${ARGS[@]}" "${SITE}"; then
				((VERBOSE == 1)) && color-echo -bc green "\n\u2713 CONNECTION SUCCESS!\n"
				return 0
			fi

			# Update time remaining
			local ELAPSED=$(($(date +%s) - BEGIN))
			((TIME_REMAINING -= ELAPSED))
			((VERBOSE == 1)) && echo "Time remaining: ${TIME_REMAINING}"
			if ((TIME_REMAINING <= 0)); then
				return 124
			fi

		done

	done

	return 1

}
