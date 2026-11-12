#!/bin/bash
# ############################################################################
# EXECUTABLE: runner-host.sh                                                 #
# PACKAGE: just-bashit                                                       #
# ############################################################################
# Turn a Mac into a GitHub Actions runner host that runs every job in a      #
# throwaway Tart VM. One clean image, one VM per job, destroyed after. The   #
# host account is never the job's account: this Mac is also someone's      #
# macOS test environment (just-buildit.github.io#203).                       #
# ############################################################################
set -euo pipefail
IFS=$'\n\t'
# Bash 5.2+ reads `&` in a ${v//pat/rep} replacement as the match, which
# turns _xml's "&lt;" into "<lt;". Off, so `&` is literal on every bash.
shopt -u patsub_replacement 2>/dev/null || :

_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Every default is an environment variable, so the LaunchDaemon, a test and a
# person at a shell all configure it the same way.
ORG="${JB_RUNNER_ORG:-just-buildit}"
TOKEN_FILE="${JB_RUNNER_TOKEN_FILE:-${HOME}/.config/jb-runner/token}"
# Pinned by digest: `latest` is rebuilt upstream, and an image that changes
# under a CI fleet is a build that changes for no reason in the diff.
BASE="${JB_RUNNER_BASE:-ghcr.io/cirruslabs/macos-tahoe-base@sha256:65c3133a633fda8753cf1f71f2d55727792d534a2125b0032466563dcc8e58fd}"
IMAGE="${JB_RUNNER_IMAGE:-jb-base}"
# actions/runner. --disableupdate means GitHub stops sending jobs to a runner
# more than 30 days behind the latest release, so re-pin and re-run `image`
# at least that often.
RUNNER_VERSION="${JB_RUNNER_VERSION:-2.338.2}"
RUNNER_SHA256="${JB_RUNNER_SHA256:-25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388}"
CPU="${JB_RUNNER_CPU:-4}"
MEMORY="${JB_RUNNER_MEMORY:-8192}"
BREW="${JB_RUNNER_BREW:-jq}"
LABELS="${JB_RUNNER_LABELS:-self-hosted,macOS,ARM64}"
PREFIX="${JB_RUNNER_PREFIX:-jb-job}"
API="${JB_RUNNER_API:-https://api.github.com}"
BOOT_TIMEOUT="${JB_RUNNER_BOOT_TIMEOUT:-300}"
TART="${JB_RUNNER_TART:-tart}"
# Every VM boots under Softnet with these blocked, so a job reaches the
# internet and nothing private: not this Mac (the VM's gateway is in one of
# these ranges, picked fresh each boot), not the LAN, not the tailnet
# (100.64.0.0/10). Softnet already drops non-global IPv4 except the gateway;
# this closes the gateway too. The VM's DNS is then public (see `image`).
NET_BLOCK="${JB_RUNNER_NET_BLOCK:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10}"
DNS="${JB_RUNNER_DNS:-1.1.1.1 8.8.8.8}"
# The one softnet tart may run. Tart finds softnet on PATH, and the daemon's
# PATH starts with ~/.local/bin, which this user can write: a softnet planted
# there would run in place of the filter. So tart gets this binary's
# directory first on its PATH, and the binary and every directory above it
# must be root's alone.
SOFTNET="${JB_RUNNER_SOFTNET:-/usr/local/bin/softnet}"
# Owners trusted for SOFTNET and its directories besides root. Root only by
# default; the tests, which cannot make root-owned files, add their own uid.
TRUSTED_UID="${JB_RUNNER_TRUSTED_UID:-0}"
# This host's short name, in every VM and runner name: two hosts registering
# `jb-job-<epoch>` with --replace would replace each other's runners.
HOST_TAG="${JB_RUNNER_HOST_TAG:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
# Held by `run` and `image`, which must not overlap: a second `run` sweeps
# the first one's live VM as stale, and `image` renames the image under a
# clone in progress.
LOCK_DIR="${JB_RUNNER_LOCK:-${HOME}/.local/state/jb-runner.lock}"

DAEMON_LABEL="io.github.just-buildit.runner-host"
DAEMON_PLIST="${JB_RUNNER_PLIST:-/Library/LaunchDaemons/${DAEMON_LABEL}.plist}"
INSTALL_DIR="${JB_RUNNER_INSTALL_DIR:-${HOME}/.local/libexec/jb-runner}"
LOG_FILE="${JB_RUNNER_LOG:-${HOME}/Library/Logs/jb-runner.log}"

DRY_RUN=0
ONCE=0
CMD=""

read -r -d '' HELP <<-'EOF' || true
	Usage: runner-host.sh [OPTIONS] COMMAND

	  Host GitHub Actions jobs for an org in throwaway Tart VMs on this Mac.
	  Each job gets a fresh clone of one clean image, registers an ephemeral
	  runner inside it, runs exactly one job, and is deleted.

	  Why a VM per job: a self-hosted runner gets no container and no fresh
	  machine on its own, and `container:` jobs are Linux-only. A runner on
	  the bare host would run every job as the account someone also uses.

	Commands:
	  image      Build the clean image: clone the pinned base, install the
	             pinned actions/runner and JB_RUNNER_BREW packages into it,
	             and save it as JB_RUNNER_IMAGE. Re-run to upgrade.
	  run        The job loop, forever: mint a registration token, clone the
	             image, boot it, run one job, delete the VM. What the
	             LaunchDaemon runs. --once stops after one VM.
	  install    Copy this script to a stable path and install a LaunchDaemon
	             that runs `run` from boot, as this user. Uses sudo.
	  uninstall  Remove the LaunchDaemon and any job VMs. Uses sudo.
	  status     The daemon, the VMs, and the org's registered runners.

	Options:
	  -h / --help     Show this message and exit.
	  -n / --dry-run  Print what would happen; change nothing.
	  --once          With `run`: one VM, then exit.

	Environment (defaults in brackets):
	  JB_RUNNER_ORG         org the runners register to [just-buildit]
	  JB_RUNNER_TOKEN_FILE  fine-grained PAT, org "Self-hosted runners:
	                        Read and write" [~/.config/jb-runner/token]
	  JB_RUNNER_BASE        Tart base image, pinned by digest
	  JB_RUNNER_IMAGE       the clean image's local name [jb-base]
	  JB_RUNNER_VERSION     actions/runner version, with JB_RUNNER_SHA256
	  JB_RUNNER_CPU / JB_RUNNER_MEMORY  per VM [4 / 8192 MB]
	  JB_RUNNER_NET_BLOCK   CIDRs no VM may reach [RFC 1918, 100.64.0.0/10]
	  JB_RUNNER_DNS         the image's DNS servers [1.1.1.1 8.8.8.8]
	  JB_RUNNER_SOFTNET     the softnet tart runs [/usr/local/bin/softnet];
	                        setuid, and it and its directories root's alone
	  JB_RUNNER_HOST_TAG    in every VM and runner name [hostname -s]
	  JB_RUNNER_LOCK        held by run and image [~/.local/state/jb-runner.lock]
	  JB_RUNNER_BREW        packages added to the image [jq]
	  JB_RUNNER_LABELS      runner labels [self-hosted,macOS,ARM64]; one
	                        shaped like a GitHub-hosted image (ubuntu-*,
	                        macos-*, windows-*) is refused

	  install writes these, as given, into the LaunchDaemon. The token file
	  must be mode 600 or 400 and owned by the user that runs this.

	  The PAT never enters a VM. Only a registration token does, and it is
	  passed on stdin, never on a command line the host's ps can see.

	Exit status:
	  0  done
	  1  an error
EOF

_say() { printf '%s\n' "$*"; }
_log() { printf '%s runner-host: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
_die() {
	printf 'runner-host: %s\n' "$*" >&2
	exit 1
}

# Echo the command in dry-run, run it otherwise.
_run() {
	if [[ ${DRY_RUN} -eq 1 ]]; then
		local IFS=' '
		printf '  would: %s\n' "$*"
	else
		"$@"
	fi
}

# _rh_command WORD -- take WORD as the command, the one positional. Shared
# by the option loop and the words after `--`, so both refuse alike.
_rh_command() {
	case "$1" in
	image | run | install | uninstall | status)
		[[ -z ${CMD} ]] || _die "one command at a time (got ${CMD} and $1)"
		CMD="$1"
		;;
	*) _die "unknown argument: $1 (try --help)" ;;
	esac
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		_say "${HELP}"
		exit 0
		;;
	-n | --dry-run) DRY_RUN=1 ;;
	--once) ONCE=1 ;;
	--)
		# End of options (gh-248): every word after it is a command word,
		# so `-- --once` is no option.
		shift
		for _rh_word in "$@"; do _rh_command "${_rh_word}"; done
		break
		;;
	*) _rh_command "$1" ;;
	esac
	shift
done
[[ -n ${CMD} ]] || _die "no command given (try --help)"

# ── Preconditions ───────────────────────────────────────────────────────────

_need_macos() {
	[[ "${JB_RUNNER_OS:-$(uname -s)}" == Darwin ]] ||
		_die "macOS only: Tart runs on Apple's Virtualization.framework"
}

# A label shaped like a GitHub-hosted image name (ubuntu-*, macos-*,
# windows-*) is refused. The workflow-side fork-PR gate treats such labels as
# GitHub-hosted, so a runner carrying one would take a fork job that asked
# for, say, macos-latest. GitHub matches labels case-insensitively, so this
# does too.
#
# Each label is trimmed first, and LABELS is rewritten from the trimmed
# list, so the label checked is the label registered: ' macos-latest' with
# its space is still macos-latest to GitHub.
_need_safe_labels() {
	local label lower out=''
	local -a labels
	IFS=, read -r -a labels <<<"${LABELS}"
	for label in "${labels[@]}"; do
		label="${label#"${label%%[![:space:]]*}"}"
		label="${label%"${label##*[![:space:]]}"}"
		[[ -n ${label} ]] || continue
		lower="$(printf '%s' "${label}" | tr '[:upper:]' '[:lower:]')"
		[[ ! ${lower} =~ ^(ubuntu|macos|windows)- ]] ||
			_die "refusing label ${label}: it looks like a GitHub-hosted image"
		out+="${out:+,}${label}"
	done
	[[ -n ${out} ]] || _die "no runner labels"
	LABELS="${out}"
}

_need_tart() {
	command -v "${TART}" >/dev/null 2>&1 ||
		_die "tart not found (https://github.com/cirruslabs/tart/releases)"
	_need_softnet
}

# _owner_mode PATH -- "UID MODE" for PATH, MODE in octal with its setuid and
# sticky bits (4755, 1777). GNU stat first (the tests run on Linux), then
# BSD, whose %p carries the file type too: only its last four digits count.
_owner_mode() {
	local out uid mode
	out="$(stat -c '%u %a' "$1" 2>/dev/null || stat -f '%u %p' "$1")" || return 1
	IFS=' ' read -r uid mode <<<"${out}"
	((${#mode} <= 4)) || mode="${mode:${#mode}-4}"
	printf '%s %s\n' "${uid}" "${mode}"
}

# softnet runs setuid root. A setuid-root binary that anyone but root can
# replace, or that sits in a directory anyone but root can write, is a root
# escalation: write your own, and tart runs it as root. So SOFTNET must be a
# real file (not a symlink), setuid, owned by root, writable by no group or
# other, and so must every directory from it up to /. A sticky directory
# (/tmp) is allowed when root owns it: no one else can replace an entry in
# it. Without softnet, `tart run --net-softnet-block` fails, and a VM on
# Tart's default network reaches this Mac, the LAN and the tailnet. So refuse
# rather than fall back.
_need_softnet() {
	local why="(docs/runner-host.md, Network)"
	[[ -f ${SOFTNET} && ! -L ${SOFTNET} ]] ||
		_die "softnet is not installed at ${SOFTNET} ${why}"
	local uid mode p="${SOFTNET}"
	while :; do
		uid='' mode=''
		IFS=' ' read -r uid mode < <(_owner_mode "${p}")
		# Unreadable is a refusal: an empty mode must never read as "not
		# writable".
		[[ ${uid} =~ ^[0-9]+$ && ${mode} =~ ^[0-7]{3,4}$ ]] ||
			_die "cannot read the owner and mode of ${p} ${why}"
		if [[ ${p} == "${SOFTNET}" ]] && ! ((8#${mode} & 8#4000)); then
			_die "softnet is not installed setuid ${why}"
		fi
		[[ ${uid} == 0 || ${uid} == "${TRUSTED_UID}" ]] ||
			_die "${p} is owned by uid ${uid}, not root: softnet runs as root ${why}"
		if ((8#${mode} & 8#022)) &&
			! [[ -d ${p} && ${uid} == 0 && $((8#${mode} & 8#1000)) -ne 0 ]]; then
			_die "${p} is writable by group or other: softnet runs as root ${why}"
		fi
		[[ ${p} != / ]] || break
		p="$(cd -P "$(dirname "${p}")" && pwd -P)"
	done
}

# The PAT file must be this user's alone: mode 600 or 400, owned by us. A
# 644 token is readable by every account on the Mac. GNU stat first (the
# tests run on Linux), BSD stat otherwise.
_need_token() {
	[[ -r ${TOKEN_FILE} ]] || _die "no token at ${TOKEN_FILE}"
	# A symlink's own mode is 777, whatever it points at, and who can
	# replace the link is a question about its directory. Name the file.
	[[ ! -L ${TOKEN_FILE} ]] ||
		_die "${TOKEN_FILE} is a symlink; point JB_RUNNER_TOKEN_FILE at the file itself"
	local mode owner
	IFS=' ' read -r mode owner < <(stat -c '%a %U' "${TOKEN_FILE}" 2>/dev/null ||
		stat -f '%Lp %Su' "${TOKEN_FILE}")
	[[ ${owner} == "$(id -un)" ]] ||
		_die "${TOKEN_FILE} is owned by ${owner}, not $(id -un)"
	[[ ${mode} == 600 || ${mode} == 400 ]] ||
		_die "${TOKEN_FILE} is mode ${mode}; run: chmod 600 ${TOKEN_FILE}"
}

# This boot's start time, so a pid recorded before a reboot, and reused
# since by some other process, is not taken for a live holder.
_boot_id() {
	local b
	b="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')"
	[[ -n ${b} ]] || b="$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null)"
	printf '%s\n' "${b:-unknown}"
}

# One process at a time takes LOCK_DIR. mkdir is atomic. The holder writes
# "PID BOOT" to a temp file and renames it into place, so the pid file is
# never seen half-written. A lock whose holder is gone (dead pid, or a pid
# from an earlier boot) is taken over: renamed away to a name of our own,
# then checked to be the stale lock we read, so two processes taking over
# at once cannot remove a live one. An empty lock dir is a holder between
# mkdir and rename: waited for, and taken over only if it stays empty.
# Released on exit, which the signal traps reach too.
_lock() {
	mkdir -p "$(dirname "${LOCK_DIR}")"
	local boot try held seen
	boot="$(_boot_id)"
	# Up to 5 s for an empty lock to fill, then room to take it over.
	for try in 1 2 3 4 5 6 7 8; do
		if mkdir "${LOCK_DIR}" 2>/dev/null; then
			printf '%s %s\n' "$$" "${boot}" >"${LOCK_DIR}/pid.$$"
			mv -f "${LOCK_DIR}/pid.$$" "${LOCK_DIR}/pid"
			trap '_unlock' EXIT
			return 0
		fi
		held="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
		if [[ -z ${held} && ${try} -lt 6 ]]; then
			sleep 1
			continue
		fi
		# A pid alone (no boot time) is trusted as this boot's.
		local pid="${held%% *}" pboot="${boot}"
		[[ ${held} != *' '* ]] || pboot="${held#* }"
		if [[ -n ${held} && ${pboot} == "${boot}" ]] && kill -0 "${pid}" 2>/dev/null; then
			_die "another runner-host (pid ${pid}) holds ${LOCK_DIR}"
		fi
		mv "${LOCK_DIR}" "${LOCK_DIR}.stale.$$" 2>/dev/null || continue
		seen="$(cat "${LOCK_DIR}.stale.$$/pid" 2>/dev/null || true)"
		if [[ ${seen} != "${held}" ]]; then
			# Someone else's fresh lock, taken between our read and the
			# rename: put it back.
			[[ -e ${LOCK_DIR} ]] || mv "${LOCK_DIR}.stale.$$" "${LOCK_DIR}"
			_die "${LOCK_DIR} changed hands while being taken over; try again"
		fi
		rm -rf "${LOCK_DIR}.stale.$$"
	done
	_die "could not take ${LOCK_DIR}"
}

_unlock() {
	local held
	held="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
	[[ ${held%% *} != "$$" ]] || rm -rf "${LOCK_DIR}"
}

# _curl_tls_init -- the TLS options every curl fetch passes, in _CURL_TLS:
# --ssl-revoke-best-effort on a Schannel curl (Git for Windows). A COPY of
# pkg.sh's, which is canonical and says why: the installed daemon is this
# one file, with no pkg.sh beside it. test/curl-tls.bats holds this body
# byte-identical to it.
_curl_tls_init() {
	local v=''
	if [[ -n ${_CURL_TLS_SET-} ]]; then
		return 0
	fi
	_CURL_TLS_SET=1
	read -r v < <(curl -V 2>/dev/null) || :
	if [[ ${v} =~ Schannel ]]; then
		_CURL_TLS+=(--ssl-revoke-best-effort)
	fi
}

# ── GitHub ──────────────────────────────────────────────────────────────────
# The PAT goes to curl as a header on stdin (-H @-), never in argv: a
# LaunchDaemon's command lines are visible to every user's ps.

_api() { # METHOD PATH
	_need_token
	_curl_tls_init
	local pat
	pat="$(<"${TOKEN_FILE}")"
	printf 'Authorization: Bearer %s\n' "${pat}" |
		curl -fsS "${_CURL_TLS[@]+"${_CURL_TLS[@]}"}" -X "$1" -H @- \
			-H 'Accept: application/vnd.github+json' \
			-H 'X-GitHub-Api-Version: 2022-11-28' \
			"${API}$2"
}

# Remove a runner registration by name. An ephemeral runner removes itself
# after its job; one whose VM was killed first stays listed until GitHub
# expires it, and shows as an idle runner nobody can reach.
_deregister() { # NAME
	local id
	id="$(_api GET "/orgs/${ORG}/actions/runners?per_page=100" |
		jq -r --arg n "$1" '.runners[] | select(.name == $n) | .id')" || return 0
	[[ -z ${id} ]] || _api DELETE "/orgs/${ORG}/actions/runners/${id}" >/dev/null || true
}

_registration_token() {
	local t
	t="$(_api POST "/orgs/${ORG}/actions/runners/registration-token" | jq -r '.token // empty')" || return 1
	[[ -n ${t} ]] || return 1
	printf '%s\n' "${t}"
}

# ── VMs ─────────────────────────────────────────────────────────────────────

_vm_exists() { "${TART}" list --format json | jq -e --arg n "$1" 'any(.[]; .Name == $n)' >/dev/null; }

_vm_delete() {
	"${TART}" stop "$1" >/dev/null 2>&1 || true
	"${TART}" delete "$1" >/dev/null 2>&1 || true
}

# Boot headless and wait for the guest agent, which `tart exec` needs. The
# Cirrus Labs images ship the agent; a vanilla image does not.
_vm_boot() { # NAME
	PATH="$(dirname "${SOFTNET}"):${PATH}" \
		"${TART}" run --no-graphics --net-softnet-block="${NET_BLOCK}" "$1" >/dev/null 2>&1 &
	local waited=0
	until "${TART}" exec "$1" /usr/bin/true >/dev/null 2>&1; do
		((waited < BOOT_TIMEOUT)) || return 1
		sleep 5
		waited=$((waited + 5))
	done
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_image() {
	_need_macos
	_need_tart
	[[ ${DRY_RUN} -eq 1 ]] || _lock
	local build="${IMAGE}-build"
	local url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
	_say "Building ${IMAGE} from ${BASE}"
	_say "  actions/runner ${RUNNER_VERSION}; brew: ${BREW:-none}"
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_run "${TART}" clone "${BASE}" "${build}"
		_run "${TART}" set "${build}" --cpu "${CPU}" --memory "${MEMORY}"
		_run "${TART}" exec "${build}" '<install runner and packages>'
		_run "${TART}" rename "${build}" "${IMAGE}"
		return 0
	fi
	_vm_delete "${build}"
	"${TART}" clone "${BASE}" "${build}"
	"${TART}" set "${build}" --cpu "${CPU}" --memory "${MEMORY}"
	_vm_boot "${build}" || {
		_vm_delete "${build}"
		_die "${build} did not come up within ${BOOT_TIMEOUT}s"
	}
	# Positional arguments, not interpolation into the script text, so no
	# value can change what the guest runs.
	# shellcheck disable=SC2016  # expanded in the guest, not here
	"${TART}" exec "${build}" /bin/bash -lc '
		set -euo pipefail
		# Public DNS first: the gateway, which would answer it, is blocked.
		# Saved in the image, so every clone has it.
		IFS=" " read -r -a dns <<<"$4"
		svc="$(networksetup -listallnetworkservices | sed -n 2p)"
		sudo -n networksetup -setdnsservers "$svc" "${dns[@]}"
		rm -rf ~/actions-runner && mkdir ~/actions-runner && cd ~/actions-runner
		curl -fsSL -o runner.tgz "$1"
		printf "%s  runner.tgz\n" "$2" | shasum -a 256 -c -
		tar xzf runner.tgz && rm runner.tgz
		if [ -n "$3" ]; then
			IFS=" " read -r -a pkgs <<<"$3"
			brew install --quiet "${pkgs[@]}"
		fi
		# `tart stop` is a power-off: what is still in the page cache is
		# lost. A build once saved an image holding half of runner.tgz and
		# nothing unpacked. So flush, and check what the image must hold.
		sync
		test -x ~/actions-runner/config.sh
	' _ "${url}" "${RUNNER_SHA256}" "${BREW}" "${DNS}" || {
		_vm_delete "${build}"
		_die "provisioning ${build} failed"
	}
	"${TART}" stop "${build}"
	_vm_delete "${IMAGE}"
	"${TART}" rename "${build}" "${IMAGE}"
	_say "Done: ${IMAGE} is ready."
}

# One job: a fresh VM, an ephemeral runner, deleted whatever happens.
_one_job() {
	local vm token
	vm="${PREFIX}-${HOST_TAG}-$(date +%s)"
	token="$(_registration_token)" || {
		_log "could not mint a registration token"
		return 1
	}
	_log "clone ${IMAGE} -> ${vm}"
	# Set first: a clone killed halfway leaves a partial VM to delete.
	CURRENT_VM="${vm}"
	"${TART}" clone "${IMAGE}" "${vm}" || {
		_cleanup
		return 1
	}
	if ! _vm_boot "${vm}"; then
		_log "${vm} did not come up within ${BOOT_TIMEOUT}s"
		_cleanup
		return 1
	fi
	_log "${vm} up; registering and waiting for a job"
	local rc=0
	# In the background and waited for: bash runs a trap only between
	# foreground commands, so a SIGTERM from launchd during a job that runs
	# for an hour would otherwise wait that hour. `wait` is interrupted.
	# shellcheck disable=SC2016  # expanded in the guest, not here
	printf '%s\n' "${token}" | "${TART}" exec -i "${vm}" /bin/bash -lc '
		set -euo pipefail
		read -r t
		cd ~/actions-runner
		./config.sh --unattended --ephemeral --disableupdate --replace \
			--url "$1" --name "$2" --labels "$3" --token "$t" >/dev/null
		# The runner reads PATH from .path, which config.sh has just written
		# from this shell. Put ~/.local/bin first, where tools a job
		# installs land (pipx; uv when setup-uv puts it there).
		printf "%s\n" "$HOME/.local/bin:$(cat .path)" >.path
		exec ./run.sh
	' _ "https://github.com/${ORG}" "${vm}" "${LABELS}" &
	EXEC_PID=$!
	wait "${EXEC_PID}" || rc=$?
	EXEC_PID=""
	_log "${vm} finished (exit ${rc}); deleting"
	_cleanup
	return "${rc}"
}

# The VM the loop is on, so a signal can take it down with the loop.
CURRENT_VM=""
EXEC_PID=""
_cleanup() {
	# The `tart exec` the job runs in: deleting the VM ends it on a real
	# host, but a stopped loop should not leave it to chance.
	[[ -z ${EXEC_PID} ]] || kill "${EXEC_PID}" 2>/dev/null || true
	EXEC_PID=""
	[[ -n ${CURRENT_VM} ]] || return 0
	local vm="${CURRENT_VM}"
	CURRENT_VM=""
	_vm_delete "${vm}"
	_deregister "${vm}"
}

_on_signal() { # EXIT_CODE
	_log "signal; deleting ${CURRENT_VM:-no VM}"
	_cleanup
	exit "$1"
}

cmd_run() {
	_need_safe_labels
	_need_macos
	_need_tart
	if [[ ${DRY_RUN} -eq 1 ]]; then
		_say "would loop: mint token for ${ORG}; clone ${IMAGE}; boot; run one job; delete"
		return 0
	fi
	_need_token
	_lock
	_vm_exists "${IMAGE}" || _die "no image ${IMAGE}; run: runner-host.sh image"
	trap '_on_signal 143' TERM
	trap '_on_signal 130' INT
	trap '_on_signal 129' HUP
	# A crash or reboot mid-job leaves a VM behind. Nothing else names VMs
	# with this prefix, so any found at start are ours and stale.
	local stale
	for stale in $("${TART}" list --format json | jq -r --arg p "${PREFIX}-" '.[] | select(.Name | startswith($p)) | .Name'); do
		_log "deleting stale ${stale}"
		_vm_delete "${stale}"
		_deregister "${stale}"
	done
	if [[ ${ONCE} -eq 1 ]]; then
		_one_job
		return
	fi
	local backoff=30
	while :; do
		if _one_job; then
			backoff=30
		else
			_log "retrying in ${backoff}s"
			sleep "${backoff}"
			backoff=$((backoff < 600 ? backoff * 2 : 600))
		fi
	done
}

# The effective configuration, so the daemon runs what `install` was run
# with rather than the defaults. XML-escaped: a value is data, not markup.
_xml() {
	local v="$1"
	v="${v//&/&amp;}"
	v="${v//</&lt;}"
	v="${v//>/&gt;}"
	printf '%s' "${v}"
}

_plist_env() {
	local k v
	for k in ORG TOKEN_FILE BASE IMAGE RUNNER_VERSION RUNNER_SHA256 CPU MEMORY \
		BREW LABELS PREFIX API BOOT_TIMEOUT TART HOST_TAG LOCK_DIR NET_BLOCK \
		SOFTNET; do
		v="$(_xml "${!k}")"
		case "${k}" in
		RUNNER_VERSION) k=VERSION ;;
		RUNNER_SHA256) k=SHA256 ;;
		LOCK_DIR) k=LOCK ;;
		*) ;;
		esac
		printf '<key>JB_RUNNER_%s</key><string>%s</string>\n' "${k}" "${v}"
	done
}

_plist() {
	cat <<-EOF
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>Label</key><string>${DAEMON_LABEL}</string>
			<key>UserName</key><string>$(_xml "$(id -un)")</string>
			<key>ProgramArguments</key>
			<array>
				<string>/bin/bash</string>
				<string>$(_xml "${INSTALL_DIR}")/runner-host.sh</string>
				<string>run</string>
			</array>
			<key>EnvironmentVariables</key>
			<dict>
				<key>HOME</key><string>$(_xml "${HOME}")</string>
				<key>PATH</key><string>$(_xml "${HOME}")/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
				$(_plist_env)
			</dict>
			<key>RunAtLoad</key><true/>
			<key>KeepAlive</key><true/>
			<key>ThrottleInterval</key><integer>30</integer>
			<key>StandardOutPath</key><string>$(_xml "${LOG_FILE}")</string>
			<key>StandardErrorPath</key><string>$(_xml "${LOG_FILE}")</string>
		</dict>
		</plist>
	EOF
}

cmd_install() {
	# Under sudo, `id -un` is root and the daemon would run jobs as root.
	# JB_RUNNER_EUID stands in for EUID in the tests, which cannot be root.
	[[ ${JB_RUNNER_EUID:-${EUID}} -ne 0 ]] || _die "run install as the runner's user, not root; it calls sudo itself"
	_need_safe_labels
	_need_macos
	_need_tart
	_need_token
	local tmp
	tmp="$(mktemp)"
	_plist >"${tmp}"
	_say "Installing ${DAEMON_LABEL} (runs as $(id -un))"
	_run mkdir -p "${INSTALL_DIR}" "$(dirname "${LOG_FILE}")"
	_run install -m 755 "${_SCRIPT_PATH}" "${INSTALL_DIR}/runner-host.sh"
	_run sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
	_run sudo install -m 644 -o root -g wheel "${tmp}" "${DAEMON_PLIST}"
	_run sudo launchctl bootstrap system "${DAEMON_PLIST}"
	rm -f "${tmp}"
	_say "Done. Log: ${LOG_FILE}"
}

cmd_uninstall() {
	_need_macos
	_run sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
	_run sudo rm -f "${DAEMON_PLIST}"
	if command -v "${TART}" >/dev/null 2>&1; then
		local vm
		for vm in $("${TART}" list --format json | jq -r --arg p "${PREFIX}-" '.[] | select(.Name | startswith($p)) | .Name'); do
			_run _vm_delete "${vm}"
		done
	fi
	# And this host's runners GitHub still lists: a VM killed mid-job
	# leaves one behind.
	if [[ -r ${TOKEN_FILE} ]]; then
		local name
		for name in $(_api GET "/orgs/${ORG}/actions/runners?per_page=100" |
			jq -r --arg p "${PREFIX}-${HOST_TAG}-" '.runners[] | select(.name | startswith($p)) | .name'); do
			_run _deregister "${name}"
		done
	fi
	_say "Removed ${DAEMON_LABEL}. ${IMAGE} is kept; delete it with: ${TART} delete ${IMAGE}"
}

cmd_status() {
	_say "daemon:"
	if launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
		launchctl print "system/${DAEMON_LABEL}" | grep -E '^[[:space:]]*(state|pid|last exit code) =' | sed 's/^[[:space:]]*/  /'
	else
		_say "  not loaded"
	fi
	_say "vms:"
	if command -v "${TART}" >/dev/null 2>&1; then
		"${TART}" list --format json | jq -r --arg i "${IMAGE}" --arg p "${PREFIX}-" \
			'.[] | select(.Name == $i or (.Name | startswith($p))) | "  \(.Name)  \(.State)"'
	else
		_say "  tart not installed"
	fi
	_say "runners registered to ${ORG}:"
	_api GET "/orgs/${ORG}/actions/runners" |
		jq -r '.runners[] | "  \(.name)  \(.status)\(if .busy then "  busy" else "" end)"'
}

"cmd_${CMD}"
