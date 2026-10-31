#Requires -Version 5.1

<#
.SYNOPSIS
    Run Windows' own OpenSSH server as a boot-time service: key-only,
    PowerShell as the login shell, reachable only from the addresses you
    name.

.DESCRIPTION
    The point is a box you can reach whether or not anything else on it is
    running. An ssh server that lives inside WSL2 dies with the WSL VM, and
    the VM stops on its own when idle or after a crash, so the machine
    goes unreachable for exactly the moments you need it. Windows' sshd is
    a service: it starts at boot, before anyone logs in, and it does not
    care whether WSL is up. From there `wsl` is one command away.

    Every step below is idempotent. Re-running this script is how you pick
    up new keys and repair drift, not a mistake:

      1. The OpenSSH.Server Windows capability is installed if it is not.
         When it is not and Windows is waiting on a reboot to finish
         servicing, the run stops before changing anything: the install
         would fail, so reboot first.
      2. The authorized keys are mirrored from GitHub (-GitHubUser) or a
         file (-KeysFile) into the file sshd actually reads for this user --
         administrators_authorized_keys when the user is a local admin,
         ~/.ssh/authorized_keys otherwise -- inside a marked block, so keys
         added by hand outside the markers survive. The file's ACL is then
         set the way Windows OpenSSH demands, or it silently ignores it.
      3. sshd_config gets PasswordAuthentication no and
         PubkeyAuthentication yes. The edit is validated with `sshd -t`
         and rolled back if sshd rejects it.
      4. The login shell is pwsh.exe (PowerShell 7), installed at the pinned
         -PwshVersion when it is missing: with winget, else the release MSI
         (winget is refused inside a RunAs-elevated first run).
      5. The firewall rule for port 22 is limited to -RemoteAddress, and a
         second rule admits this machine's own WSL (its virtual interface),
         so later runs can come over an admin ssh session with no prompt.
         WSL rebuilds that interface on every boot, so a SYSTEM scheduled
         task re-scopes the second rule each time WSL's switch comes up.
      6. The sshd service is set to start automatically, and restarted so
         the new configuration is live.

    Why keys only: once this runs, the machine answers on port 22 from
    boot, unattended. Password logins there are an invitation. Why the
    script REFUSES to run with no keys: with passwords off and no key
    authorized, the server would be up and admit nobody -- a lock you
    installed yourself.

    Must run elevated. setup-system's `sshd` step does that from WSL,
    raising one UAC prompt on the Windows desktop.

    Windows PowerShell 5.1 is supported on purpose, as the interpreter that
    RUNS this script: a fresh machine has it and does not have pwsh 7 yet,
    and bringing that machine up is what this script is for. It is not the
    login shell; step 4 installs pwsh for that.

.PARAMETER GitHubUser
    Mirror https://github.com/<user>.keys. Every machine's key is already
    registered there (setup-system's ssh step prints the `gh ssh-key add`
    to do it), so this list does not need to be kept anywhere else.

.PARAMETER KeysFile
    Read the authorized keys from this file instead of GitHub.

.PARAMETER RemoteAddress
    Addresses allowed through the firewall to port 22, in the forms
    New-NetFirewallRule accepts. Default: Any. For a machine reached over
    Tailscale, '100.64.0.0/10','fd7a:115c:a1e0::/48' admits the tailnet
    and nothing else.

.PARAMETER PwshVersion
    The PowerShell 7 release to install when pwsh.exe is missing, e.g.
    7.6.6. setup-system passes its own pin, so Linux and Windows run the
    same release. Required only when pwsh is absent; an installed pwsh is
    never replaced.

.PARAMETER User
    The Windows account the keys are for. Default: the current user, which
    under UAC elevation is the same account that asked.

.PARAMETER RescopeWslRule
    Re-scope the jb-sshd-wsl firewall rule to the WSL adapter that exists
    now, and do nothing else. This is what the scheduled task runs, from
    the copy of this script under %ProgramData%\just-bashit; it waits up to
    a minute for the adapter, because the task fires as WSL's virtual
    switch initialises, a moment before the adapter is named.

.PARAMETER CheckWslRule
    Report, without elevation, whether jb-sshd-wsl admits the WSL adapter
    that exists now, read from the firewall's persistent store. Exit 0 when
    it does, 1 when it is stale, missing, or there is no WSL adapter.

.EXAMPLE
    .\windows-sshd.ps1 -GitHubUser octocat

    From an elevated PowerShell: key-only sshd for octocat's GitHub keys,
    open to any address.

.EXAMPLE
    .\windows-sshd.ps1 -GitHubUser octocat -RemoteAddress '100.64.0.0/10','fd7a:115c:a1e0::/48'

    The same, reachable only from a Tailscale tailnet.

.EXAMPLE
    setup-system.sh -s sshd --github-user octocat

    From WSL: the same thing through setup-system, which raises the UAC
    prompt and reports the outcome.
#>

[CmdletBinding()]
param(
    [string]$GitHubUser,
    [string]$KeysFile,
    [string[]]$RemoteAddress = @('Any'),
    [string]$PwshVersion,
    [string]$User = $env:USERNAME,
    [switch]$RescopeWslRule,
    [switch]$CheckWslRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Write-Information rather than Write-Host: progress for a human that a
# caller can still capture or silence. The preference makes it visible.
$InformationPreference = 'Continue'

$BlockBegin = '# >>> managed by just-bashit windows-sshd.ps1 >>>'
$BlockEnd = '# <<< just-bashit <<<'

# ---------------------------------------------------------------------------
# Pure functions: text in, text out, no system state. They are what the test
# suite exercises on a Linux runner, where nothing below them could run.
# ---------------------------------------------------------------------------

function Get-KeyLine {
    <#
    .SYNOPSIS
        The authorized_keys lines in some text: one per key, blanks,
        comments and anything malformed dropped.
    .DESCRIPTION
        GitHub's .keys endpoint answers an unknown user with an HTML error
        page and a 404, and a proxy can substitute a login page with a 200.
        Filtering to lines that look like keys means neither can be written
        into authorized_keys, and the empty result that follows is caught by
        the caller's refusal to run with no keys.
    .EXAMPLE
        Get-KeyLine "ssh-ed25519 AAAA a`n<html>`n"   # -> 'ssh-ed25519 AAAA a'
    #>
    param([AllowEmptyString()][string]$Text)
    $keyPattern = '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-\S+|sk-\S+)\s+\S+'
    @($Text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match $keyPattern } |
            Select-Object -Unique)
}

function Merge-ManagedBlock {
    <#
    .SYNOPSIS
        Replace the marked block in a file's lines with Body; keep every
        other line exactly as it was.
    .DESCRIPTION
        The same contract as sync-ssh-hosts' splice: a file with no markers
        yet is handled by the same path as one being refreshed, trailing
        blank lines are trimmed so repeated runs do not grow the file, and
        the block always ends the file. Keys added by hand live outside the
        markers and are never touched.
    .EXAMPLE
        Merge-ManagedBlock -Existing @('ssh-rsa BBBB mine') -Body @('ssh-ed25519 AAAA gh')
    #>
    param(
        [AllowEmptyCollection()][string[]]$Existing,
        [string[]]$Body
    )
    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in @($Existing)) {
        if ($line -eq $BlockBegin) { $skip = $true; continue }
        if ($line -eq $BlockEnd) { $skip = $false; continue }
        if (-not $skip) { $kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') {
        $kept.RemoveAt($kept.Count - 1)
    }
    if ($kept.Count -gt 0) { $kept.Add('') }
    $kept.Add($BlockBegin)
    foreach ($line in $Body) { $kept.Add($line) }
    $kept.Add($BlockEnd)
    , $kept.ToArray()
}

function Edit-SshdOption {
    <#
    .SYNOPSIS
        Set one global sshd_config keyword, replacing its value in place.
    .DESCRIPTION
        Only the global section is considered: everything before the first
        `Match` line. A keyword written after a Match applies to that match
        alone, so appending there -- the obvious edit -- would scope the
        setting to administrators and leave everyone else on the default.

        Exactly one line is rewritten, chosen in this order:
          - the single live (uncommented) line for the keyword, or
          - failing that, the single commented-out default the stock file
            ships (`#PasswordAuthentication yes`), so the setting lands
            where a reader expects it, or
          - failing both, a new line inserted just above the first Match.
        Two live lines, or two commented candidates and no live one, is a
        file this function cannot edit safely, and it throws rather than
        guessing which one sshd will honour.
    .EXAMPLE
        Edit-SshdOption -Lines @('#PasswordAuthentication yes','Match Group administrators') -Name PasswordAuthentication -Value no
    #>
    param(
        [string[]]$Lines,
        [string]$Name,
        [string]$Value
    )
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange([string[]]@($Lines))

    $end = $out.Count
    for ($i = 0; $i -lt $out.Count; $i++) {
        if ($out[$i] -match '^\s*Match\s') { $end = $i; break }
    }
    $live = @()
    $commented = @()
    for ($i = 0; $i -lt $end; $i++) {
        if ($out[$i] -match "^\s*$Name\s") { $live += $i }
        elseif ($out[$i] -match "^\s*#\s*$Name\s") { $commented += $i }
    }

    $setting = "$Name $Value"
    if ($live.Count -gt 1) {
        throw "sshd_config sets $Name on $($live.Count) lines; refusing to guess which one sshd honours"
    }
    if ($live.Count -eq 1) {
        $out[$live[0]] = $setting
    }
    elseif ($commented.Count -eq 1) {
        $out[$commented[0]] = $setting
    }
    elseif ($commented.Count -gt 1) {
        throw "sshd_config has $($commented.Count) commented $Name lines and no live one; refusing to guess"
    }
    else {
        $out.Insert($end, $setting)
    }
    , $out.ToArray()
}

function Install-WithWinget {
    <#
    .SYNOPSIS
        Install a package machine-wide with winget, pinned to -Version.
        Returns $true when winget ran and reported success, $false when
        winget is absent or failed -- the caller then has a fallback, and
        says which path it took.
    #>
    param([string]$Id, [string]$Version)
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Information "  note  no winget in this session; using the fallback for $Id"
        return $false
    }
    Write-Information "  install $Id $Version with winget"
    & $winget.Source install --id $Id --version $Version --exact --scope machine `
        --silent --accept-package-agreements --accept-source-agreements `
        --disable-interactivity | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Information ("  note  winget exit $LASTEXITCODE for $Id " +
            '(a RunAs-elevated first run is refused); using the fallback')
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# The WSL firewall rule. These touch the system only through cmdlets, so the
# test suite drives them on Linux with each cmdlet replaced by a stub.
# ---------------------------------------------------------------------------

# The rule that admits this machine's own WSL to port 22, and the task that
# keeps it pointed at WSL's adapter.
$WslRuleName = 'jb-sshd-wsl'
$RescopeTaskName = 'jb-sshd-wsl-rescope'
$RescopeTaskPath = '\just-bashit\'

# The host side of WSL's NAT switch. Only WSL's VM is attached to that
# switch, so traffic arriving on this adapter is this machine's WSL and
# nothing else -- tighter than WSL's subnet as a -RemoteAddress, which would
# also admit a LAN that happens to use the same 172.16.0.0/12 range.
$WslAdapterPattern = 'vEthernet (WSL*'

# Hyper-V's vmswitch logs event 9, "Switch ... successfully initialized", to
# the System log each time WSL creates its switch: on the first WSL start
# after a boot, not at the boot itself (zen-x2elite-x, 2026-10-20: boot
# 19:24, WSL's switch 20:41). The adapter, with its new GUID, follows within
# a second. Not narrowed to WSL's switch by name: the name differs across
# WSL releases ("WSL", "WSL (Hyper-V firewall)"), event XPath has no prefix
# match, and the event is rare (three in 17 days on that box) while a
# re-scope that finds the rule current changes nothing.
$WslSwitchEventQuery = '<QueryList><Query Id="0" Path="System">' +
'<Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Hyper-V-VmSwitch''] and EventID=9]]</Select>' +
'</Query></QueryList>'

function Select-WslInterface {
    <#
    .SYNOPSIS
        The adapters, among those given, that carry this machine's WSL
        traffic to Windows: the host side of WSL's virtual switch.
    .DESCRIPTION
        `vSwitch (WSL ...)` is the switch itself, not an interface traffic
        arrives on, and every other adapter faces the LAN or a VPN; none of
        them is selected.
    .EXAMPLE
        Select-WslInterface (Get-NetAdapter -IncludeHidden)
    #>
    param([AllowEmptyCollection()][object[]]$Adapter)
    @($Adapter | Where-Object { $_.Name -like $WslAdapterPattern })
}

function Sync-WslSshdRule {
    <#
    .SYNOPSIS
        Point the jb-sshd-wsl rule at the WSL adapter that exists now,
        creating the rule when it is absent. Returns $true when there was
        an adapter to point it at.
    .DESCRIPTION
        The ONE place the rule's scope is decided: the setup run calls it,
        and so does the scheduled task, through -RescopeWslRule.

        The scope is an interface alias, which Windows resolves to the
        adapter's InterfaceGuid when the rule is written -- the persisted
        rule says `IF={guid}`. WSL recreates the adapter with a new GUID on
        every boot, so a rule written once admits nothing after the next
        one (#80). Re-writing it after WSL builds its adapter is what keeps
        it current; HNS does the same to its own `IF=`-scoped rules for
        WSL's DNS.

        Only jb-sshd-wsl is touched. The -RemoteAddress rule for port 22
        (OpenSSH-Server-In-TCP) is never read or written here.
    #>
    $wslIf = @(Select-WslInterface @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue) |
            ForEach-Object { $_.Name })
    if ($wslIf.Count -eq 0) { return $false }
    if (Get-NetFirewallRule -Name $WslRuleName -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $WslRuleName -Enabled True -Profile Any -InterfaceAlias $wslIf
    }
    else {
        New-NetFirewallRule -Name $WslRuleName -DisplayName 'OpenSSH Server (sshd) from WSL' `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
            -Profile Any -InterfaceAlias $wslIf | Out-Null
    }
    Write-Information "  ok    firewall: port 22 from this machine's WSL ($($wslIf -join ', '))"
    return $true
}

function Test-WslRuleScope {
    <#
    .SYNOPSIS
        Whether a persisted jb-sshd-wsl rule admits exactly the WSL
        adapter(s) given. Text in, verdict out.
    .DESCRIPTION
        Rule is the rule's value in the firewall's persistent store
        (HKLM\SYSTEM\...\FirewallPolicy\FirewallRules), which is readable
        without elevation where Get-NetFirewallInterfaceFilter is not. Its
        `IF={guid}` fields are compared with the live adapters'
        InterfaceGuid. Returns an object with Current, Have and Want.
    .EXAMPLE
        Test-WslRuleScope 'v2.33|IF={AB}|' @([pscustomobject]@{Name='vEthernet (WSL)'; InterfaceGuid='{AB}'})
    #>
    param(
        [AllowEmptyString()][string]$Rule,
        [AllowEmptyCollection()][object[]]$Adapter
    )
    $want = @(Select-WslInterface $Adapter |
            ForEach-Object { ([string]$_.InterfaceGuid).Trim('{}').ToUpperInvariant() } |
            Sort-Object)
    $have = @([regex]::Matches([string]$Rule, '\|IF=\{?([0-9A-Fa-f-]+)\}?') |
            ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object)
    [pscustomobject]@{
        Current = ($want.Count -gt 0 -and ($want -join ',') -eq ($have -join ','))
        Have    = $have
        Want    = $want
    }
}

function Register-WslRescopeTask {
    <#
    .SYNOPSIS
        Register (or replace) the SYSTEM task that re-runs Sync-WslSshdRule
        whenever WSL builds its switch, and at startup.
    .DESCRIPTION
        The task runs a copy of this script, not the one setup-system left
        in the user's %TEMP%: a SYSTEM task must never run a file the user
        can rewrite. The copy lives in %ProgramData%\just-bashit, whose ACL
        is reset to Administrators and SYSTEM in full, Users read-only (the
        unelevated -CheckWslRule reads it).

        Register-ScheduledTask -Force replaces a task of the same name and
        path, so a re-run updates the one task rather than adding another.

        Triggers: event 9 from Hyper-V's vmswitch (see
        $WslSwitchEventQuery), and startup, for a switch built before the
        event subscription is live. Either way the run waits up to a minute
        for the adapter and then exits.
    #>
    param([string]$Source)
    $dir = Join-Path $env:ProgramData 'just-bashit'
    $target = Join-Path $dir 'windows-sshd.ps1'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' `
        '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $dir" }
    if ($Source -ne $target) { Copy-Item -LiteralPath $Source -Destination $target -Force }
    # A file that existed before the directory's ACL was reset keeps its own;
    # /reset makes it take the directory's.
    & icacls.exe $target /reset | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $target" }

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument (
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$target`" -RescopeWslRule")
    $onSwitch = New-CimInstance -ClientOnly -CimClass (
        Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler')
    $onSwitch.Subscription = $WslSwitchEventQuery
    $onSwitch.Enabled = $true
    $triggers = @((New-ScheduledTaskTrigger -AtStartup), $onSwitch)
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances Queue
    Register-ScheduledTask -TaskName $RescopeTaskName -TaskPath $RescopeTaskPath -Action $action `
        -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    Write-Information ("  ok    task $RescopeTaskPath$RescopeTaskName re-scopes $WslRuleName " +
        'whenever WSL rebuilds its adapter')
}

# ---------------------------------------------------------------------------
# The OpenSSH server capability, and the pending reboot that blocks it.
# ---------------------------------------------------------------------------

# The servicing stack's own "waiting on a reboot" keys. Add-WindowsCapability
# is a servicing (CBS) operation, and with either present it fails with a raw
# 0x800f0950 (measured on zen-x2elite-x, 2026-10-30: RebootPending set by a
# VS Build Tools modify that exited 3010). Deliberately not counted:
#   - WindowsUpdate\Auto Update\RebootRequired, Windows Update's own flag.
#     When what it waits on is servicing, CBS sets RebootPending too and
#     this list catches it; when it is not, it does not block a capability
#     install, and refusing would block for nothing.
#   - Session Manager\PendingFileRenameOperations, which installers fill
#     with delete-on-reboot temp files and which is rarely empty (106
#     entries on that box, Edge and Copilot updater leftovers); it blocks no
#     servicing operation.
$ServicingRebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
)

function Get-ServicingRebootPending {
    <#
    .SYNOPSIS
        The servicing keys present that say Windows is waiting on a reboot;
        empty when there is none. See $ServicingRebootKeys for which count.
    #>
    @($ServicingRebootKeys | Where-Object { Test-Path -LiteralPath $_ })
}

function Install-SshdCapability {
    <#
    .SYNOPSIS
        Install the OpenSSH.Server capability when it is missing; refuse,
        before changing anything, when a pending servicing reboot would make
        the install fail.
    .DESCRIPTION
        InstallPending counts as installed: sshd runs, and Windows finishes
        the servicing at the next reboot. Treated as missing, every re-run
        -- routine now that re-runs come over ssh -- repeated the slow
        Add-WindowsCapability for nothing (measured on zen-ai445,
        2026-09-28).

        The pending-reboot check runs only when the capability needs
        installing: an installed sshd is not blocked by a reboot that has
        nothing to do with it. The refusal starts "reboot pending:", which
        setup-system reads to put the reason in its summary.
    #>
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -eq 'InstallPending') {
        Write-Information "  ok    $($cap.Name) installed (Windows finishes it at the next reboot)"
        return
    }
    if ($cap.State -eq 'Installed') {
        Write-Information "  ok    $($cap.Name) installed"
        return
    }
    $pending = @(Get-ServicingRebootPending)
    if ($pending.Count -gt 0) {
        throw ("reboot pending: Windows is waiting on a reboot to finish servicing " +
            "($(($pending | ForEach-Object { ($_ -split '\\')[-1] }) -join ', ')), and $($cap.Name) cannot be " +
            'installed until it does. Reboot Windows, then re-run setup-system -s sshd.')
    }
    Write-Information "  install $($cap.Name) (this can take a few minutes)"
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}

# The test suite dot-sources this file for the functions above and must not
# fall through into the part that changes the machine.
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# Main: everything below changes the machine.
# ---------------------------------------------------------------------------

function Write-Utf8NoBom {
    # Windows PowerShell's Set-Content writes a BOM. sshd reads the BOM as
    # part of the first line, so the first key in authorized_keys -- or the
    # first directive in sshd_config -- is silently unrecognised.
    param([string]$Path, [string[]]$Lines)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $enc)
}

# -CheckWslRule needs no elevation: the firewall's persistent store is
# readable by any user, where Get-NetFirewallInterfaceFilter is not.
if ($CheckWslRule) {
    $store = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
    # GetValue answers $null for an absent value, where a property read
    # throws under strict mode.
    $rule = (Get-Item -LiteralPath $store).GetValue($WslRuleName)
    $verdict = Test-WslRuleScope -Rule $rule -Adapter @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)
    $want = ($verdict.Want | ForEach-Object { "{$_}" }) -join ', '
    $have = ($verdict.Have | ForEach-Object { "{$_}" }) -join ', '
    if ($verdict.Current) { Write-Information "$WslRuleName scope: current ($have)"; exit 0 }
    if (-not $rule) { Write-Information "$WslRuleName scope: MISSING (no such rule)" }
    elseif ($verdict.Want.Count -eq 0) { Write-Information "$WslRuleName scope: no WSL adapter (is WSL running?)" }
    else { Write-Information "$WslRuleName scope: STALE (rule admits $have; WSL adapter is $want)" }
    exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'must run elevated (Run as administrator); setup-system -s sshd does this for you'
}
# The scheduled task's run: the rule and nothing else. The task fires as
# WSL's switch initialises; the adapter follows within a second or so, so
# wait for it rather than miss it.
if ($RescopeWslRule) {
    for ($i = 0; $i -lt 30; $i++) {
        if (Sync-WslSshdRule) { exit 0 }
        Start-Sleep -Seconds 2
    }
    Write-Information "  note  no WSL adapter yet; $WslRuleName is re-scoped when WSL starts"
    exit 0
}
if (-not $GitHubUser -and -not $KeysFile) {
    throw 'no key source: pass -GitHubUser or -KeysFile'
}

# -- 1. keys first: nothing is changed unless there is someone to let in ----
if ($KeysFile) {
    $keys = Get-KeyLine (Get-Content -Raw -LiteralPath $KeysFile)
    $source = $KeysFile
}
else {
    # TLS 1.2 by hand: Windows PowerShell 5.1 still defaults to protocols
    # GitHub refuses.
    [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url = "https://github.com/$GitHubUser.keys"
    $keys = Get-KeyLine (Invoke-RestMethod -Uri $url -UseBasicParsing)
    $source = $url
}
if ($keys.Count -eq 0) {
    throw "no keys found at $source; refusing to turn off passwords with nothing to log in with"
}
Write-Information "  keys  $($keys.Count) from $source"

# -- 2. the server itself ---------------------------------------------------
Install-SshdCapability

$sshDir = Join-Path $env:ProgramData 'ssh'
$config = Join-Path $sshDir 'sshd_config'
# sshd writes its default config and host keys on first start. A capability
# installed a moment ago has neither yet.
if (-not (Test-Path -LiteralPath $config)) {
    Start-Service sshd
    Stop-Service sshd
}

# -- 3. authorized keys, in the file sshd reads for this user ---------------
# Administrators are special-cased by the stock sshd_config
# (`Match Group administrators`): their ~/.ssh/authorized_keys is IGNORED in
# favour of one machine-wide file. Writing the per-user file for an admin
# is the classic "the key is right there and it still asks for a password".
#
# Get-LocalGroupMember throws on a group holding an orphaned SID (a deleted
# account, a machine that left a domain) -- a long-standing Windows bug. A
# throw there must not quietly become "not an admin", which would write the
# file sshd ignores, so `net localgroup` is asked instead. It is resolved by
# SID because the group's NAME is localised.
$adminSid = 'S-1-5-32-544'
$userPattern = "(^|\\)$([regex]::Escape($User))$"
try {
    $members = @(Get-LocalGroupMember -SID $adminSid | ForEach-Object { $_.Name })
}
catch {
    $group = (New-Object Security.Principal.SecurityIdentifier($adminSid)).Translate(
        [Security.Principal.NTAccount]).Value.Split('\')[-1]
    $members = @(& net.exe localgroup $group | ForEach-Object { $_.Trim() })
}
$isAdmin = [bool]($members | Where-Object { $_ -match $userPattern })
if ($isAdmin) {
    $keyFile = Join-Path $sshDir 'administrators_authorized_keys'
}
else {
    $keyFile = Join-Path (Join-Path (Split-Path $env:USERPROFILE) $User) '.ssh\authorized_keys'
    New-Item -ItemType Directory -Force -Path (Split-Path $keyFile) | Out-Null
}
$existing = @()
if (Test-Path -LiteralPath $keyFile) { $existing = @(Get-Content -LiteralPath $keyFile) }
Write-Utf8NoBom -Path $keyFile -Lines (Merge-ManagedBlock -Existing $existing -Body $keys)

# Re-asserted every run: the bytes are not what rots, the ACL is. sshd skips
# a key file writable by anyone but its owner, SYSTEM and Administrators,
# and says so only in its own log.
if ($isAdmin) {
    & icacls.exe $keyFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
}
else {
    & icacls.exe $keyFile /inheritance:r /grant:r "${User}:F" '*S-1-5-18:F' | Out-Null
}
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $keyFile" }
Write-Information "  ok    $keyFile"

# -- 4. key-only authentication, validated before it goes live --------------
$before = @(Get-Content -LiteralPath $config)
$after = Edit-SshdOption -Lines $before -Name PasswordAuthentication -Value no
$after = Edit-SshdOption -Lines $after -Name PubkeyAuthentication -Value yes
if (Compare-Object $before $after -SyncWindow 0) {
    Copy-Item -LiteralPath $config -Destination "$config.bak" -Force
    Write-Utf8NoBom -Path $config -Lines $after
    & (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe') -t
    if ($LASTEXITCODE -ne 0) {
        Copy-Item -LiteralPath "$config.bak" -Destination $config -Force
        throw "sshd -t rejected the new sshd_config; the previous one is restored"
    }
    Write-Information "  ok    $config (key-only; previous kept as sshd_config.bak)"
}
else {
    Write-Information "  ok    $config already key-only"
}

# -- 5. pwsh.exe as the login shell ------------------------------------------
# The MSI's fixed install path, not a PATH lookup: sshd starts the shell as a
# service, with the machine PATH of the moment, and a stale PATH is no
# reason to log people into something else.
$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh) -and $PwshVersion) {
    # winget first: it is how everything else on these boxes is installed
    # (install-deps' winget section), and over an admin ssh session -- how
    # setup-system runs this once sshd exists -- it installs machine-wide
    # with no prompt (measured on yoga-x2p, 2026-09-28).
    # Captured: an uncaptured return value is printed, and the first real
    # run (swiftgo-ultra7) showed a bare `False` line in the log.
    $null = Install-WithWinget -Id 'Microsoft.PowerShell' -Version $PwshVersion
}
if (-not (Test-Path -LiteralPath $pwsh)) {
    # The release MSI, for the one context winget fails in: a process elevated
    # with Start-Process -Verb RunAs, which is how the FIRST run on a box gets
    # elevated (0x80070005, access denied -- measured on an arm64 box). The
    # MSI needs nothing but elevation, which this process has.
    if (-not $PwshVersion) {
        throw "pwsh.exe is not installed and no -PwshVersion was given to install"
    }
    # The MACHINE's architecture: an emulated x86 process reports x86 in
    # PROCESSOR_ARCHITECTURE and the real one in PROCESSOR_ARCHITEW6432.
    $machine = $env:PROCESSOR_ARCHITEW6432
    if (-not $machine) { $machine = $env:PROCESSOR_ARCHITECTURE }
    switch ($machine) {
        'ARM64' { $arch = 'arm64' }
        'AMD64' { $arch = 'x64' }
        default { throw "no PowerShell MSI for architecture $machine" }
    }
    $msiName = "PowerShell-$PwshVersion-win-$arch.msi"
    $msi = Join-Path $env:TEMP $msiName
    $msiUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/$msiName"
    Write-Information "  install PowerShell $PwshVersion ($arch) from $msiUrl"
    [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $msiUrl -OutFile $msi -UseBasicParsing
    $p = Start-Process msiexec.exe -PassThru -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart', 'ADD_PATH=1')
    # WaitForExit, not -Wait: in Windows PowerShell -Wait waits for every
    # descendant, and an installer that starts anything long-lived never
    # returns. Measured 2026-09-26: the Tailscale MSI hung here for 15 min.
    $p.WaitForExit()
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    # 3010: installed, a reboot is pending -- installed all the same.
    if (($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) -or -not (Test-Path -LiteralPath $pwsh)) {
        throw "the PowerShell MSI did not install pwsh.exe at $pwsh (msiexec exit $($p.ExitCode))"
    }
}
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value $pwsh -PropertyType String -Force | Out-Null
Write-Information "  ok    login shell $pwsh"

# -- 6. firewall --------------------------------------------------------------
# The capability creates this rule open to every address on every profile.
$ruleName = 'OpenSSH-Server-In-TCP'
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH SSH Server (sshd)' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
}
Set-NetFirewallRule -Name $ruleName -Enabled True -Profile Any -RemoteAddress $RemoteAddress
Write-Information "  ok    firewall: port 22 from $($RemoteAddress -join ', ')"

# And from this machine's own WSL, whatever -RemoteAddress says. setup-system
# runs this script -- and a box's later provisioning -- over an admin ssh
# session from WSL, which needs no UAC prompt; the rule above, limited to a
# tailnet, drops WSL's traffic (it comes from the WSL virtual switch). WSL
# rebuilds its adapter with a new GUID on every boot, which strands a rule
# scoped to it (#80), so the task re-scopes it each time; registered even
# when WSL has not started yet, so the rule appears the first time it does.
if (-not (Sync-WslSshdRule)) {
    Write-Information "  note  no WSL adapter yet; the task adds $WslRuleName when WSL starts"
}
Register-WslRescopeTask -Source $PSCommandPath

# -- 7. the service ------------------------------------------------------------
Set-Service -Name sshd -StartupType Automatic
# Newer Windows builds ship services that depend on sshd -- SshdBroker on
# 28000 -- and a plain Restart-Service refuses to stop a service with
# dependents. -Force stops them too, but does not bring them back, so the
# ones that were running are started again afterwards.
$dependents = @((Get-Service -Name sshd).DependentServices |
        Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
Restart-Service -Name sshd -Force
foreach ($name in $dependents) { Start-Service -Name $name }
$listening = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue
if (-not $listening) { throw 'sshd restarted but nothing is listening on port 22' }
Write-Information '  ok    sshd running, starts at boot, listening on 22'
