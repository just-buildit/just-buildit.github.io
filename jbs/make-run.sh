#!/bin/bash
# ############################################################################
# LIBRARY: make-run.sh                                                       #
# PACKAGE: just-bashit version 0.3.2                                         #
# ############################################################################
# Resolve and run a repository's make targets and command variables from     #
# that repository's OWN Makefile, so callers never carry a second copy of a  #
# command. A repo bases its Makefile on standard.mk, which defines the       #
# sanctioned defaults with `?=`; the repo then overrides what it must. This  #
# library reads the result of that layering rather than re-deriving it, so   #
# there is nothing to vendor and nothing to keep in sync.                    #
#                                                                            #
# The load-bearing rule: a variable that is UNDEFINED is an error, never an  #
# empty string. `DOCS_CHECK_CMD ?=` is legitimately empty; a typo'd name is  #
# not. Collapsing the two is how a wrong command reads as a blank one.       #
# ############################################################################

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

# Sentinel target name. Prefixed to avoid colliding with any real target. Its
# recipe is expanded by make at RUN time, which is what lets `$(info ...)` see
# fully-layered values — evaluating the same expression while makefiles are
# still being read yields nothing, because the variables do not exist yet.
_MK_SENTINEL="__jb_make_run"

# ---------------------------------------------------------------------------
# _mk-db — capture make's variable/target database for a directory.
#
# `make -pRrq` prints the database but exits 1 whenever the default goal is
# out of date, which is the normal case. Piping it directly means a caller
# running under `set -o pipefail` — bats and most CI do — sees every query
# fail even though the database was read fine. Capturing here, and swallowing
# that status deliberately, keeps these functions independent of whatever
# shell options the caller happens to have set.
# ---------------------------------------------------------------------------
_mk-db() {
	local out rc
	out="$(make -C "${1}" -pRrq 2>/dev/null)" && rc=0 || rc=$?
	# Exit 1 is question mode reporting the default goal is out of date — the
	# normal case, and not a failure to read anything. Exit 2 means make could
	# not parse the makefiles at all. Those must not look alike: swallowing
	# exit 2 hands the caller an empty database, and an empty answer then
	# reads as a real one. That is the same failure this library exists to
	# prevent, one level up.
	if ((rc >= 2)); then
		echo "make-run: make could not read the makefiles in ${1}" >&2
		echo "make-run: run 'make -C ${1} -pRrq' to see why" >&2
		return 1
	fi
	printf '%s\n' "${out}"
}

# ---------------------------------------------------------------------------
# _mk-file — name of the makefile a directory would use, in make's own order.
#
# Needed because the query below passes `-f` explicitly, and `-f` turns OFF
# make's automatic search: naming only the sentinel would hide the repo's
# actual makefile and every variable in it.
# ---------------------------------------------------------------------------
_mk-file() {
	local f
	for f in GNUmakefile makefile Makefile; do
		if [[ -f ${1}/${f} ]]; then
			printf '%s\n' "${f}"
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# _mk-eval — expand a make EXPRESSION against a repo, printing what it emits.
#
# The expression is placed in a sentinel target's recipe inside a throwaway
# makefile, which is handed to make ALONGSIDE the repo's own via `-f`. The
# obvious alternative, `--eval`, is not portable: it arrived in GNU make 3.82
# (28 Jul 2010), and macOS still ships 3.81 as /usr/bin/make — so a library
# built on it works everywhere except the one platform most likely to be
# running an old make. `-f` has always been there. `$(info ...)` is fine: it
# landed in 3.81.
#
# Nothing is built. The sentinel is .PHONY with a no-op command, so make
# neither reports it up to date nor runs any real recipe.
# ---------------------------------------------------------------------------
_mk-eval() {
	local dir="${1}" expr="${2}" mkfile sentinel out
	mkfile="$(_mk-file "${dir}")" || return 1
	sentinel="$(mktemp)" || return 1
	{
		printf '.PHONY: %s\n' "${_MK_SENTINEL}"
		printf '%s:\n' "${_MK_SENTINEL}"
		printf '\t@%s\n' "${expr}"
		printf '\t@:\n'
	} >"${sentinel}"
	out="$(make -C "${dir}" --no-print-directory \
		-f "${mkfile}" -f "${sentinel}" "${_MK_SENTINEL}" 2>/dev/null || true)"
	rm -f "${sentinel}"
	printf '%s\n' "${out}"
}

# ---------------------------------------------------------------------------
# _mk-dir — resolve and validate the repo directory for the calling function.
#
# Echoes the directory on success. Exits non-zero with a message on stderr if
# the directory has no makefile, since every other function is meaningless
# there and a clear error beats make's "No targets specified".
# ---------------------------------------------------------------------------
_mk-dir() {
	local dir="${1:-.}"
	if [[ ! -d ${dir} ]]; then
		echo "make-run: not a directory: ${dir}" >&2
		return 1
	fi
	local f found=0
	for f in GNUmakefile makefile Makefile; do
		[[ -f ${dir}/${f} ]] && found=1 && break
	done
	if ((found == 0)); then
		echo "make-run: no makefile in ${dir}" >&2
		return 1
	fi
	printf '%s\n' "${dir}"
}

# ---------------------------------------------------------------------------
# mk-origin — print where make got a variable's value.
#
# Thin wrapper over make's own $(origin), which is the only reliable way to
# tell "defined as empty" from "never defined". Prints one of make's origin
# words: undefined, default, environment, file, command line, override,
# automatic.
# ---------------------------------------------------------------------------
mk-origin() {
	local HELP
	IFS= read -r -d '' HELP <<-'EOF'
		Usage: mk-origin [-C DIR] NAME

		  Print where make got NAME's value, using make's own $(origin).
		  Prints "undefined" when NAME was never set.

		Options:
		  -h        Show this message and exit.
		  -C DIR    Repository directory (default: current directory).
	EOF

	local dir="."
	local OPTIND=0
	while getopts ":hC:" option; do
		case ${option} in
		h)
			printf '%s\n' "${HELP}"
			return 0
			;;
		C) dir="${OPTARG}" ;;
		\?)
			echo "make-run: invalid option -${OPTARG}" >&2
			return 1
			;;
		esac
	done
	shift $((OPTIND - 1))

	local name="${1:-}"
	if [[ -z ${name} ]]; then
		printf '%s\n' "${HELP}" >&2
		return 1
	fi
	dir="$(_mk-dir "${dir}")" || return 1

	local out
	out="$(_mk-eval "${dir}" "\$(info \$(origin ${name}))")" || return 1
	head -n 1 <<<"${out}"
}

# ---------------------------------------------------------------------------
# mk-var — print one variable's fully expanded value from a repo's makefile.
#
# This is the function that exists so nobody transcribes a command by hand.
# `make docs` in doppler is NOT the standard.mk default; asking the repo is
# the only way to be right about it.
#
# Fails (exit 1) when NAME is undefined. Succeeds printing an empty line when
# NAME is defined-but-empty, which is a real and meaningful state.
#
# Example
# -------
#   $ mk-var -C ~/doppler DOCS_BUILD_CMD
#   uv run --group docs zensical build --clean --strict
# ---------------------------------------------------------------------------
mk-var() {
	local HELP
	IFS= read -r -d '' HELP <<-'EOF'
		Usage: mk-var [-C DIR] NAME

		  Print NAME's fully expanded value as the repository's makefile
		  defines it, after standard.mk defaults and repo overrides are
		  layered. Nothing is built and no recipe is run.

		  Exits 1 if NAME is undefined. A defined-but-empty variable is
		  NOT an error — it prints an empty line and exits 0.

		Options:
		  -h        Show this message and exit.
		  -C DIR    Repository directory (default: current directory).
	EOF

	local dir="."
	local OPTIND=0
	while getopts ":hC:" option; do
		case ${option} in
		h)
			printf '%s\n' "${HELP}"
			return 0
			;;
		C) dir="${OPTARG}" ;;
		\?)
			echo "make-run: invalid option -${OPTARG}" >&2
			return 1
			;;
		esac
	done
	shift $((OPTIND - 1))

	local name="${1:-}"
	if [[ -z ${name} ]]; then
		printf '%s\n' "${HELP}" >&2
		return 1
	fi
	dir="$(_mk-dir "${dir}")" || return 1

	# The guard. Undefined must never render as empty, or a caller silently
	# publishes a blank command where a real one belongs.
	local origin
	origin="$(mk-origin -C "${dir}" "${name}")" || return 1
	if [[ ${origin} == "undefined" ]]; then
		echo "make-run: ${name} is not defined in ${dir}" >&2
		return 1
	fi
	# An empty origin means the query itself failed — make never answered.
	# Falling through would print an empty value indistinguishable from a
	# variable that is genuinely empty.
	if [[ -z ${origin} ]]; then
		echo "make-run: could not query ${name} in ${dir}" >&2
		return 1
	fi

	local out
	out="$(_mk-eval "${dir}" "\$(info \$(${name}))")" || return 1
	head -n 1 <<<"${out}"
}

# ---------------------------------------------------------------------------
# mk-vars — dump every file-defined variable as NAME=value, one per line.
#
# Deliberately takes no built-in list of "interesting" variables: such a list
# would be exactly the hand-maintained copy this library exists to abolish.
# Callers filter with the optional REGEX.
#
# All values resolve in a SINGLE make invocation. Per-variable invocations are
# correct but cost one process each, which matters when a caller renders a
# whole document.
#
# Example
# -------
#   $ mk-vars -C ~/doppler '_CMD$'
#   DOCS_BUILD_CMD=uv run --group docs zensical build --clean --strict
#   TEST_CMD=ctest --test-dir build --output-on-failure
# ---------------------------------------------------------------------------
mk-vars() {
	local HELP
	IFS= read -r -d '' HELP <<-'EOF'
		Usage: mk-vars [-C DIR] [REGEX]

		  Print NAME=value for every variable the repository's makefiles
		  define, fully expanded. REGEX filters variable NAMES (ERE).
		  Nothing is built and no recipe is run.

		Options:
		  -h        Show this message and exit.
		  -C DIR    Repository directory (default: current directory).
	EOF

	local dir="."
	local OPTIND=0
	while getopts ":hC:" option; do
		case ${option} in
		h)
			printf '%s\n' "${HELP}"
			return 0
			;;
		C) dir="${OPTARG}" ;;
		\?)
			echo "make-run: invalid option -${OPTARG}" >&2
			return 1
			;;
		esac
	done
	shift $((OPTIND - 1))

	local filter="${1:-.}"
	dir="$(_mk-dir "${dir}")" || return 1

	# `-p` dumps make's database; `-Rrq` suppresses built-in rules/variables
	# and stops it running anything. Make annotates each definition with its
	# origin on the PRECEDING line — "# makefile (from 'standard.mk', line
	# 353)" — and that comment is what separates a makefile-defined variable
	# from make's own built-ins and the inherited environment.
	local db names out
	db="$(_mk-db "${dir}")" || return 1
	names="$(
		awk '/^# makefile/ { want = 1; next }
		     /^[A-Za-z_][A-Za-z0-9_]* :?=/ && want { print $1 }
		     { want = 0 }' <<<"${db}" |
			grep -E "${filter}" | sort -u | tr '\n' ' '
	)" || true
	[[ -z ${names} ]] && return 0

	out="$(_mk-eval "${dir}" \
		"\$(foreach v,${names},\$(info \$(v)=\$(\$(v))))")" || return 1
	grep -vE "^make(\[[0-9]+\])?: " <<<"${out}" || true
}

# ---------------------------------------------------------------------------
# mk-run — run a target using the repository's own recipe for it.
#
# The point of the whole library: `mk-run docs` runs whatever THAT repo means
# by docs. A caller never needs to know the command, so a caller can never
# get it wrong or drift from it.
#
# The target is verified to exist first, so a rename fails with a useful
# message instead of make's "No rule to make target".
# ---------------------------------------------------------------------------
mk-run() {
	local HELP
	IFS= read -r -d '' HELP <<-'EOF'
		Usage: mk-run [-C DIR] TARGET [MAKE_ARGS...]

		  Run TARGET using the repository's own makefile. Any further
		  arguments pass through to make. Fails if TARGET is not defined
		  by that repository.

		Options:
		  -h        Show this message and exit.
		  -C DIR    Repository directory (default: current directory).
	EOF

	local dir="."
	local OPTIND=0
	while getopts ":hC:" option; do
		case ${option} in
		h)
			printf '%s\n' "${HELP}"
			return 0
			;;
		C) dir="${OPTARG}" ;;
		\?)
			echo "make-run: invalid option -${OPTARG}" >&2
			return 1
			;;
		esac
	done
	shift $((OPTIND - 1))

	local target="${1:-}"
	if [[ -z ${target} ]]; then
		printf '%s\n' "${HELP}" >&2
		return 1
	fi
	shift
	dir="$(_mk-dir "${dir}")" || return 1

	if ! mk-has -C "${dir}" "${target}"; then
		echo "make-run: no target '${target}' in ${dir}" >&2
		return 1
	fi

	make -C "${dir}" "${target}" "$@"
}

# ---------------------------------------------------------------------------
# mk-has — predicate: does the repository define TARGET?
#
# Reads make's target database rather than dry-running, so a target with a
# missing prerequisite still answers honestly instead of erroring.
# ---------------------------------------------------------------------------
mk-has() {
	local dir="."
	local OPTIND=0
	while getopts ":C:" option; do
		case ${option} in
		C) dir="${OPTARG}" ;;
		\?) return 1 ;;
		esac
	done
	shift $((OPTIND - 1))

	local target="${1:-}"
	[[ -z ${target} ]] && return 1
	dir="$(_mk-dir "${dir}")" || return 1

	local db
	db="$(_mk-db "${dir}")" || return 1
	grep -qE "^${target}:( |$)" <<<"${db}"
}
