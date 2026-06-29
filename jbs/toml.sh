#!/bin/bash
# ############################################################################
# LIBRARY: toml.sh                                                           #
# PACKAGE: just-bashit version 0.2.0                                        #
# ############################################################################
# Pure-bash parser for the TOML subset used by just-bashit dependency files:#
#   [group.pm] sections with packages = [...] and cmd = [...] arrays.       #
# All parse functions read from stdin.                                       #
# ############################################################################

(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

# ---------------------------------------------------------------------------
# toml_strings
# ---------------------------------------------------------------------------
toml_strings() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: toml_strings TEXT

		  Extract each double-quoted string value from TEXT, one per line.
		  Strips surrounding whitespace and skips empty quoted strings.

		Options:
		  -h  Show this message and exit.

		Arguments:
		  TEXT  Raw TOML fragment containing one or more double-quoted strings.

		Examples:
		  toml_strings '"curl", "wget"'   # prints: curl\nwget
		  toml_strings '"a", "", "b"'     # prints: a\nb  (empty string skipped)
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	local s="${1:-}" val
	while [[ "$s" == *'"'* ]]; do
		s="${s#*\"}"
		val="${s%%\"*}"
		[[ -n "$val" ]] && printf '%s\n' "$val"
		s="${s#*\"}"
	done

}

# ---------------------------------------------------------------------------
# toml_get_array
# ---------------------------------------------------------------------------
toml_get_array() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: toml_get_array GROUP SECTION KEY   (stdin: TOML content)

		  Print each value in KEY = [...] under [GROUP.SECTION], one per line.
		  Handles both inline ( key = ["a","b"] ) and multiline array syntax.
		  Reads TOML content from stdin.

		Options:
		  -h  Show this message and exit.

		Arguments:
		  GROUP    The top-level group name (e.g. "runtime", "dev").
		  SECTION  The package manager or sub-section (e.g. "apt", "pacman").
		  KEY      The array key to extract (e.g. "packages", "cmd").

		Examples:
		  printf '[runtime.apt]\npackages = ["curl"]\n' | toml_get_array runtime apt packages
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	local group="${1:-}" section="${2:-}" key="${3:-}"
	local target="[${group}.${section}]"
	local in_section=0 in_array=0 line rest
	while IFS= read -r line; do
		if [[ "$line" =~ ^\[.*\] ]]; then
			[[ "$line" == "$target" ]] && in_section=1 || in_section=0
			in_array=0
			continue
		fi
		[[ $in_section -eq 0 ]] && continue
		if [[ $in_array -eq 0 ]] && [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
			[[ "$line" != *\[* ]] && continue
			rest="${line#*\[}"
			if [[ "$rest" == *\]* ]]; then
				toml_strings "${rest%%\]*}"
			else
				in_array=1
				toml_strings "$rest"
			fi
		elif [[ $in_array -eq 1 ]]; then
			if [[ "$line" == *\]* ]]; then
				toml_strings "${line%%\]*}"
				in_array=0
			else
				toml_strings "$line"
			fi
		fi
	done

}

# ---------------------------------------------------------------------------
# toml_get_packages
# ---------------------------------------------------------------------------
toml_get_packages() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: toml_get_packages GROUP SECTION   (stdin: TOML content)

		  Print packages = [...] values from [GROUP.SECTION], one per line.
		  Reads TOML content from stdin.

		Options:
		  -h  Show this message and exit.

		Arguments:
		  GROUP    The top-level group name (e.g. "runtime", "dev").
		  SECTION  The package manager name (e.g. "apt", "pacman").

		Examples:
		  cat deps.toml | toml_get_packages runtime apt
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	toml_get_array "${1:-}" "${2:-}" "packages"

}

# ---------------------------------------------------------------------------
# toml_get_cmd
# ---------------------------------------------------------------------------
toml_get_cmd() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: toml_get_cmd GROUP SECTION   (stdin: TOML content)

		  Print cmd = [...] values from [GROUP.SECTION], one per line.
		  Reads TOML content from stdin.

		Options:
		  -h  Show this message and exit.

		Arguments:
		  GROUP    The top-level group name (e.g. "runtime", "dev").
		  SECTION  The package manager name (e.g. "apt", "pacman").

		Examples:
		  cat deps.toml | toml_get_cmd runtime apt
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	toml_get_array "${1:-}" "${2:-}" "cmd"

}

# ---------------------------------------------------------------------------
# toml_get_tool_groups
# ---------------------------------------------------------------------------
toml_get_tool_groups() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: toml_get_tool_groups TOOL   (stdin: TOML content)

		  Print comma-separated group names from [tools.TOOL].groups = [...].
		  Prints nothing if the key is absent. Reads TOML content from stdin.

		Options:
		  -h  Show this message and exit.

		Arguments:
		  TOOL  The tool name as it appears in [tools.TOOL] (e.g. "install-deps").

		Examples:
		  cat jb.toml | toml_get_tool_groups install-deps
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	local tool="${1:-}" g out=""
	while IFS= read -r g; do
		[[ -z "$g" ]] && continue
		out="${out:+${out},}${g}"
	done < <(toml_get_array "tools" "$tool" "groups")
	printf '%s' "$out"

}

# ---------------------------------------------------------------------------
# toml_discover_groups
# ---------------------------------------------------------------------------
toml_discover_groups() {

	local HELP
	IFS= read -r -d '' HELP <<-'EOF' || true
		Usage: toml_discover_groups [PM ...]   (stdin: TOML content)

		  Scan for [group.pm] headers where pm is a known package manager.
		  Print comma-separated group names in file order, deduplicated.
		  Pass custom PM names as arguments to override the built-in list.
		  Reads TOML content from stdin.

		Options:
		  -h  Show this message and exit.

		Arguments:
		  PM ...  Optional list of package manager names to recognise.
		          Defaults to: apt pacman brew dnf zypper apk msys2.

		Examples:
		  cat deps.toml | toml_discover_groups
		  cat deps.toml | toml_discover_groups apt pacman
	EOF

	local OPTARG="" OPTIND=0
	while getopts ":h" option; do
		case $option in
		h)
			echo "${HELP}"
			return 0
			;;
		\?)
			echo "Invalid option: -${OPTARG}"
			echo "${HELP}"
			return 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	local -a known
	if [[ $# -gt 0 ]]; then
		known=("$@")
	else
		known=(apt pacman brew dnf zypper apk msys2)
	fi
	local line inner group pm seen="" out="" k found
	while IFS= read -r line; do
		[[ "$line" =~ ^\[.*\..*\]$ ]] || continue
		inner="${line:1:${#line}-2}"
		group="${inner%%.*}"
		pm="${inner#*.}"
		[[ "$pm" == *.* ]] && continue
		found=0
		for k in "${known[@]}"; do [[ "$pm" == "$k" ]] && found=1 && break; done
		[[ $found -eq 0 ]] && continue
		[[ ",${seen}," == *",${group},"* ]] && continue
		seen="${seen:+${seen},}${group}"
		out="${out:+${out},}${group}"
	done
	printf '%s' "$out"

}
