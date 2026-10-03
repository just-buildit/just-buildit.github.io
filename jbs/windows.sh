#!/bin/bash
# ############################################################################
# LIBRARY: windows.sh                                                        #
# PACKAGE: just-bashit                                                       #
# ############################################################################
#
# Reaching Windows programs from WSL. Sourced by setup-system.sh and
# ssh-to-windows.sh, and vendored by consumers (from the jbs/ mirror) so a
# third copy of the lookup below is never written.
#
# The one question it answers: where is a Windows executable, when WSL's
# PATH may not name it? Windows' directories are on a WSL shell's PATH only
# when WSL launched that shell and appendWindowsPath is on. A shell reached
# over ssh (Tailscale SSH, VS Code Remote-SSH) has none of them, yet interop
# works: the program runs when called by its full path. Measured 2026-09-27
# on yoga-x2p -- a WSL terminal had 14 /mnt/c PATH entries, the ssh'd-in
# session 0, and /mnt/c/Windows/System32/cmd.exe ran from both.

# Enforce sourcing of the script by taking advantage of the fact that return
# only works if sourced and errors otherwise.
(return 0 2>/dev/null) || (echo "This file must be sourced." && exit)

# win-exe NAME -- print the path of Windows executable NAME, or return 1.
#
# PATH first, so a machine that has Windows' PATH keeps whatever it resolves
# to. Then the directories Windows itself puts these programs in, under
# wherever the C: drive is mounted. The mount point is read from the mount
# table, not assumed to be /mnt/c: [automount] root in /etc/wsl.conf moves
# it. JB_PROC_MOUNTS overrides the table, so a Linux test runner can fake one.
#
#   System32                          cmd.exe, icacls.exe, wsl.exe, ...
#   System32/WindowsPowerShell/v1.0   powershell.exe (Windows PowerShell 5.1)
#   Program Files/PowerShell/7        pwsh.exe (PowerShell 7, when installed)
#
# Example:
#   . windows.sh
#   cmd="$(win-exe cmd.exe)" || echo "no WSL interop here"
win-exe() {
	local name="$1" root p
	if p="$(command -v "${name}" 2>/dev/null)"; then
		printf '%s\n' "${p}"
		return 0
	fi
	root="$(awk '$1 ~ /^C:/ && /drvfs/ { print $2; exit }' \
		"${JB_PROC_MOUNTS:-/proc/mounts}" 2>/dev/null || true)"
	[[ -n ${root} ]] || return 1
	for p in "${root}/Windows/System32/${name}" \
		"${root}/Windows/System32/WindowsPowerShell/v1.0/${name}" \
		"${root}/Program Files/PowerShell/7/${name}"; do
		if [[ -x ${p} ]]; then
			printf '%s\n' "${p}"
			return 0
		fi
	done
	return 1
}

# win-home -- this Windows user's profile directory (%USERPROFILE%) as a path
# this shell can open, or return 1 when there is no Windows to ask.
#
# Asked of Windows rather than assembled from a guess: the profile is not
# always C:\Users\<linux username>, and on a domain-joined machine it is
# frequently neither. cmd.exe runs from /mnt/c because it warns (loudly, on
# stderr, every call) when its working directory is a Linux path.
#
# The one lookup: ssh-to-windows publishes keys INTO this profile, and
# setup-system's ssh step adopts the box key FROM it.
#
# Example:
#   . windows.sh
#   home="$(win-home)" && ls "${home}/.ssh"
win-home() {
	local cmd raw home
	cmd="$(win-exe cmd.exe)" || return 1
	raw="$( (
		cd /mnt/c 2>/dev/null || true
		"${cmd}" /c 'echo %USERPROFILE%' 2>/dev/null
	) | tr -d '\r\n')" || raw=""
	[[ -n ${raw} && ${raw} != '%USERPROFILE%' ]] || return 1
	home="$(wslpath -u "${raw}" 2>/dev/null)" || return 1
	[[ -d ${home} ]] || return 1
	printf '%s\n' "${home}"
}

# win-admin-channel -- print the ssh destination (user@host) of this
# machine's OWN Windows sshd when WSL can reach it as an elevated admin, or
# return 1. With it, every elevated step after a box's first runs over ssh:
# an admin logged in by key over Windows OpenSSH gets the full (High
# Mandatory Level) token, with no UAC prompt -- nobody has to be at the
# desktop (measured on yoga-x2p and zen-x2elite, 2026-09-28).
#
# The host is WSL's default gateway (NAT networking), overridable with
# JB_WIN_HOST. It is trusted only after one round trip proves two things:
# the far end's %COMPUTERNAME% is this machine's -- so a gateway that is some
# other box is never mistaken for the host -- and the session is elevated.
# The key is the one named after this host (~/.ssh/<hostname>) when present,
# the ssh step's convention; otherwise ssh's defaults.
#
# Example:
#   . windows.sh
#   if dest="$(win-admin-channel)"; then ssh "${WIN_SSH_OPTS[@]}" "$dest" whoami; fi
# Built here, at source time, not inside win-admin-channel: callers run that
# in $(...), a subshell, so an option it added would never reach them.
WIN_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
# ssh-key-name -- the default ssh key filename: this machine's short name.
#
# The ONE derivation: setup-system's ssh step names the key with it, and the
# admin channel below finds the key with it, so the two cannot disagree. It
# lives here because windows.sh is the library both of them load.
#
# Bash's own $HOSTNAME, not hostname(1): Fedora's WSL image has no hostname
# command, so `hostname -s || hostname || echo id_ed25519` named every key
# there `id_ed25519`, commented `matt@id_ed25519` (FedoraLinux-44 on
# swiftgo-ultra7, 2026-10-03). Bash sets HOSTNAME from gethostname() at
# startup; an inherited value wins, which is what lets a test pin it.
#
# Example:
#   $ HOSTNAME=box.example.org bash -c '. windows.sh; ssh-key-name'
#   box
ssh-key-name() {
	local name="${HOSTNAME:-}"
	name="${name%%.*}"
	printf '%s\n' "${name:-id_ed25519}"
}

# Required to be a FILE: a name that came out empty made the path ~/.ssh/ --
# a readable directory -- and ssh rejected it.
_win_key="$(ssh-key-name)"
if [[ -n ${_win_key} && -f "${HOME}/.ssh/${_win_key}" ]]; then
	WIN_SSH_OPTS+=(-i "${HOME}/.ssh/${_win_key}")
fi
unset _win_key
win-admin-channel() {
	local cmd host user name out
	cmd="$(win-exe cmd.exe)" || return 1
	host="${JB_WIN_HOST:-$(ip route show default 2>/dev/null | awk '{ print $3; exit }')}"
	[[ -n ${host} ]] || return 1
	user="$( (
		cd /mnt/c 2>/dev/null || true
		"${cmd}" /c 'echo %USERNAME%' 2>/dev/null
	) | tr -d '\r\n')"
	name="$( (
		cd /mnt/c 2>/dev/null || true
		"${cmd}" /c 'echo %COMPUTERNAME%' 2>/dev/null
	) | tr -d '\r\n')"
	[[ -n ${user} && -n ${name} ]] || return 1
	# S-1-16-12288 is the High Mandatory Level SID: an elevated token.
	out="$(ssh "${WIN_SSH_OPTS[@]}" "${user}@${host}" \
		'$env:COMPUTERNAME; [bool](whoami /groups | Select-String "S-1-16-12288")' \
		2>/dev/null | tr -d '\r')" || return 1
	[[ ${out} == "${name}"$'\n'True ]] || return 1
	printf '%s\n' "${user}@${host}"
}
