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
      2. The authorized keys are mirrored from GitHub (-GitHubUser) or a
         file (-KeysFile) into the file sshd actually reads for this user --
         administrators_authorized_keys when the user is a local admin,
         ~/.ssh/authorized_keys otherwise -- inside a marked block, so keys
         added by hand outside the markers survive. The file's ACL is then
         set the way Windows OpenSSH demands, or it silently ignores it.
      3. sshd_config gets PasswordAuthentication no and
         PubkeyAuthentication yes. The edit is validated with `sshd -t`
         and rolled back if sshd rejects it.
      4. The login shell is pwsh.exe (PowerShell 7), installed from the
         pinned -PwshVersion release MSI when it is missing.
      5. The firewall rule for port 22 is limited to -RemoteAddress.
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
    [string]$User = $env:USERNAME
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

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'must run elevated (Run as administrator); setup-system -s sshd does this for you'
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
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -ne 'Installed') {
    Write-Information "  install $($cap.Name) (this can take a few minutes)"
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}
else {
    Write-Information "  ok    $($cap.Name) installed"
}

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
if (-not (Test-Path -LiteralPath $pwsh)) {
    # The release MSI from GitHub, not winget: winget run inside a process
    # elevated with Start-Process -Verb RunAs fails with 0x80070005 (access
    # denied) -- measured on an arm64 box, where that is exactly how
    # setup-system runs this script. The MSI needs nothing but elevation,
    # which this process has, and it is the same pinned-release-asset
    # approach setup-system's pwsh step takes on Linux.
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
