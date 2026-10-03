#!/bin/bash
# ############################################################################
# EXECUTABLE: ssh-to-windows.sh                                              #
# PACKAGE: just-bashit                                                       #
# ############################################################################
# Publish WSL2's ssh keys to Windows, with the NTFS ACLs Windows OpenSSH     #
# insists on. A key that works perfectly in the WSL shell is refused by      #
# git.exe two directories away, and chmod cannot fix it: Windows reads ACLs, #
# not mode bits. Idempotent — re-running is how you repair drift.            #
# ############################################################################
set -euo pipefail
IFS=$'\n\t'

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_SCRIPT_DIR}/windows.sh"

DRY_RUN=0
VERBOSE=0
FORCE=0
KEY_NAME=""

read -r -d '' HELP <<-'EOF' || true
	Usage: ssh-to-windows.sh [OPTIONS]

	  Copy this WSL distro's ssh private keys to the Windows user profile and
	  set the NTFS ACLs that Windows OpenSSH requires, so git.exe, ssh.exe and
	  VS Code can use the keys you already have.

	  Why this exists: ~/.ssh in WSL is on a Linux filesystem and chmod 600
	  means something there. %USERPROFILE%\.ssh is on NTFS, where Windows
	  OpenSSH ignores mode bits and reads the ACL instead. Copy a key across
	  with cp and Windows answers:

	      Permissions for 'C:\Users\you\.ssh\id_ed25519' are too open.

	  ...because the file inherited the profile's ACL, which grants more than
	  the owner. Repairing that needs icacls, which no chmod sweep can do.

	  Copies in ONE direction only, WSL to Windows. It never reads a Windows
	  key back over a Linux one, and it never touches ~/.ssh in this distro.

	Options:
	  -h / --help         Show this message and exit.
	  -n / --dry-run      Print what would happen; change nothing.
	  -v / --verbose      Name every file, not just the ones that changed.
	  -f / --force        Overwrite a Windows key whose contents differ.
	                      Without this, a difference is reported and skipped.
	  -k / --key NAME     Publish only ~/.ssh/NAME (and NAME.pub) rather than
	                      every private key found.

	Exit status:
	  0  keys are published and their ACLs are correct
	  1  an error, including "not running under WSL"
	  2  a Windows key differs and --force was not given
EOF

_say() { printf '%s\n' "$*"; }
_note() { [[ ${VERBOSE} -eq 1 ]] && printf '  %s\n' "$*" || true; }
_die() {
	printf 'ssh-to-windows: %s\n' "$*" >&2
	exit 1
}

# Echo the command in dry-run, run it otherwise. Keeps every mutating call in
# one place, so --dry-run cannot miss one by accident.
_run() {
	if [[ ${DRY_RUN} -eq 1 ]]; then
		# IFS is newline+tab for the rest of the script, which would print
		# each argument on its own line here. Space just for the echo.
		local IFS=' '
		printf '  would: %s\n' "$*"
	else
		# stdout is dropped rather than redirected at each call site: icacls
		# is chatty, and a `>/dev/null` on the call swallowed the dry-run
		# line too -- so --dry-run silently hid the ACL changes, which are
		# the most important thing it has to show.
		"$@" >/dev/null
	fi
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		_say "${HELP}"
		exit 0
		;;
	-n | --dry-run) DRY_RUN=1 ;;
	-v | --verbose) VERBOSE=1 ;;
	-f | --force) FORCE=1 ;;
	-k | --key)
		[[ $# -ge 2 ]] || _die "--key needs a name"
		KEY_NAME="$2"
		shift
		;;
	*) _die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

# ── Preconditions ───────────────────────────────────────────────────────────
# Stated as errors rather than skips: this script is asked for by name, so a
# machine that cannot run it is a mistake worth hearing about, not a silent
# success. (A caller that wants it optional can test /proc/version itself.)

# Overridable so the suite can exercise this on a Linux runner, which is the
# only place CI has. A tool that can only be tested on the one platform it
# targets gets tested by hand, which means eventually not at all.
_PROC_VERSION="${JB_PROC_VERSION:-/proc/version}"

if ! { [[ -r ${_PROC_VERSION} ]] && grep -qi microsoft "${_PROC_VERSION}"; }; then
	_die "not running under WSL — there is no Windows profile to publish to"
fi

command -v wslpath >/dev/null 2>&1 ||
	_die "wslpath not found; WSL interop with Windows must be enabled"
# By full path when PATH lacks Windows' directories, as it does in a shell
# reached over ssh (windows.sh says why).
ICACLS="$(win-exe icacls.exe)" ||
	_die "icacls.exe not found; WSL interop with Windows must be enabled"
CMD="$(win-exe cmd.exe)" ||
	_die "cmd.exe not found; WSL interop with Windows must be enabled"
WHOAMI="$(win-exe whoami.exe)" ||
	_die "whoami.exe not found; WSL interop with Windows must be enabled"

SRC_DIR="${HOME}/.ssh"
[[ -d ${SRC_DIR} ]] || _die "${SRC_DIR} does not exist — no keys to publish"

# ── Where Windows keeps the profile ─────────────────────────────────────────
# Asked of Windows rather than assembled from a guess: the profile is not
# always C:\Users\<linux username>, and on a domain-joined machine it is
# frequently neither. cmd.exe is run from /mnt/c because it warns (loudly, on
# stderr, every call) when its working directory is a Linux path.

_win_home_raw="$( (
	cd /mnt/c 2>/dev/null || true
	"${CMD}" /c 'echo %USERPROFILE%' 2>/dev/null
) | tr -d '\r\n')" || _win_home_raw=""
[[ -n ${_win_home_raw} ]] || _die "could not resolve %USERPROFILE% through cmd.exe"

WIN_HOME="$(wslpath -u "${_win_home_raw}")"
[[ -d ${WIN_HOME} ]] || _die "%USERPROFILE% resolved to ${WIN_HOME}, which is not a directory"

DEST_DIR="${WIN_HOME}/.ssh"

# The ACL principal. whoami.exe prints DOMAIN\user, which is what icacls wants
# and is correct on a domain-joined machine where %USERNAME% alone is not.
WIN_USER="$( (
	cd /mnt/c 2>/dev/null || true
	"${WHOAMI}" 2>/dev/null
) | tr -d '\r\n')" || WIN_USER=""
[[ -n ${WIN_USER} ]] || _die "could not resolve the Windows user through whoami.exe"

_say "Publishing ssh keys to ${DEST_DIR} (as ${WIN_USER})"

# ── Which keys ──────────────────────────────────────────────────────────────
# A private key is identified by its header, the same test setup-system.sh
# uses to decide what to harden. Matching on a NAME instead would miss
# everything not called id_* and would happily publish a known_hosts file.

_is_private_key() {
	local f="$1"
	[[ -f ${f} ]] || return 1
	case "$(head -n 1 -- "${f}" 2>/dev/null || true)" in
	*"PRIVATE KEY"*) return 0 ;;
	*) return 1 ;;
	esac
}

keys=()
if [[ -n ${KEY_NAME} ]]; then
	candidate="${SRC_DIR}/${KEY_NAME}"
	_is_private_key "${candidate}" ||
		_die "${candidate} is not a private key"
	keys+=("${candidate}")
else
	for f in "${SRC_DIR}"/*; do
		_is_private_key "${f}" && keys+=("${f}")
	done
fi

[[ ${#keys[@]} -gt 0 ]] || _die "no private keys found in ${SRC_DIR}"

# ── The destination directory and its ACL ───────────────────────────────────
# /inheritance:r drops the ACEs inherited from the profile -- which is the
# whole problem -- and the grant that follows is then the only one left.
# (OI)(CI) makes it the inheritable default, so keys copied in afterwards are
# born correct rather than needing a second pass.

if [[ ! -d ${DEST_DIR} ]]; then
	_say "  create ${DEST_DIR}"
	_run mkdir -p "${DEST_DIR}"
fi

DEST_DIR_WIN="$(wslpath -w "${DEST_DIR}" 2>/dev/null || printf '%s\\.ssh' "${_win_home_raw}")"
_note "acl ${DEST_DIR_WIN}"
_run "${ICACLS}" "${DEST_DIR_WIN}" /inheritance:r /grant:r "${WIN_USER}:(OI)(CI)F"

# ── Publish ─────────────────────────────────────────────────────────────────

status=0
copied=0

_publish() {
	local src="$1" dest="$2" private="$3"

	if [[ -e ${dest} ]] && cmp -s -- "${src}" "${dest}"; then
		_note "same  $(basename -- "${dest}")"
	elif [[ -e ${dest} ]] && [[ ${FORCE} -eq 0 ]]; then
		printf '  DIFFERS, not overwritten: %s (use --force)\n' "${dest}" >&2
		status=2
		return 0
	else
		_say "  copy  $(basename -- "${src}")"
		_run cp -- "${src}" "${dest}"
		copied=$((copied + 1))
	fi

	# Re-asserted every run, even when the file was unchanged: the copy is not
	# what rots, the ACL is. A profile-wide permissions change, a restore from
	# backup or a file recreated by another tool all leave the bytes correct
	# and the ACL wrong, which is exactly the state that reads as "the key
	# stopped working for no reason".
	if [[ ${private} -eq 1 ]]; then
		local win
		win="$(wslpath -w "${dest}" 2>/dev/null || true)"
		if [[ -n ${win} ]]; then
			_note "acl   $(basename -- "${dest}")"
			_run "${ICACLS}" "${win}" /inheritance:r /grant:r "${WIN_USER}:F"
		fi
	fi
}

for key in "${keys[@]}"; do
	name="$(basename -- "${key}")"
	_publish "${key}" "${DEST_DIR}/${name}" 1
	[[ -f ${key}.pub ]] && _publish "${key}.pub" "${DEST_DIR}/${name}.pub" 0
done

if [[ ${status} -eq 2 ]]; then
	_say "Some keys differ and were left alone. Re-run with --force to replace them."
else
	_say "Done. ${#keys[@]} key(s) published, ${copied} file(s) written."
fi
exit "${status}"
