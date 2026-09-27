#!/bin/bash
# ############################################################################
# LIBRARY: windows.sh                                                        #
# PACKAGE: just-bashit version 0.6.0                                         #
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
