<#
.SYNOPSIS
    Install jbx (just-runit) on native Windows from PowerShell, with no bash
    window to open.

.DESCRIPTION
    The PowerShell front door to get-jb.sh:

        irm https://just-buildit.github.io/get-jb.ps1 | iex
        jbx setup-system

    jbx and every library it runs are bash, so bash cannot be avoided -- but
    it can be a runtime you never see. This script:

      1. Finds Git for Windows' bash.exe (the registry, then `git` on PATH,
         then the usual install directories). It never uses
         C:\Windows\System32\bash.exe, which is the WSL launcher, not a
         bash. When there is none it installs Git.Git with winget, silently,
         and looks again.
      2. Installs uv with winget (astral-sh.uv) when no uv is found, so an
         ARM64 machine gets the native aarch64 build. winget's Links
         directory is put on this session's PATH, which bash inherits, so
         get-jb.sh below sees that uv and does not install its own.
      3. Runs get-jb.sh in that bash -- the same installer a Linux or Git
         Bash user sources, so jb/jbx have one implementation. Any JB_*
         variable set in this session (JB_REINSTALL=1, say) reaches it.
      4. Writes jbx and just-runit FUNCTIONS into a marked block of the
         PowerShell profile, and defines them in this session too. They
         forward their arguments, stdin and exit code to the jbx in bash.

    Re-running is how you update: get-jb.sh replaces an outdated jbx and the
    profile block is rewritten in place, never duplicated.

    Safe to `iex`: nothing here calls `exit`, its helper functions are
    removed again when it finishes, and a failure is one thrown error that
    names what to do -- your session stays open either way.

    The profile. $PROFILE.CurrentUserAllHosts differs between Windows
    PowerShell 5.1 (Documents\WindowsPowerShell\profile.ps1) and PowerShell
    7 (Documents\PowerShell\profile.ps1), so the block is written to BOTH:
    a machine that only has 5.1 today gets pwsh 7 from setup-system, and
    jbx should work there the moment it is installed. Documents is resolved
    through Windows, so a OneDrive-redirected Documents folder is honoured.
    JB_PS_PROFILE names the file to use instead (tests, or a custom
    profile).

    A profile that cannot be read is never written: its content may exist
    nowhere else. The usual case is a OneDrive online-only file under a
    Documents folder OneDrive still redirects after it was uninstalled --
    reading it needs OneDrive, and it is not running (#202). Each such
    profile is named on one line with the fix; the other profile, the
    driver and this session's jbx are still set up, and the run then ends
    in one thrown error naming every profile it skipped.

    How arguments cross. A Windows program hands bash one command line,
    which the MSYS runtime splits with rules of its own: it globs `*`,
    treats ' as a quote, and mangles an embedded ". So the functions pass
    nothing on that line. Each argument travels in the environment
    (JB_PS_ARGC, JB_PS_ARG1..N) to a small driver, jbx-ps.sh, which rebuilds
    "$@" and execs jbx. Every argument arrives byte for byte, empty ones
    included, in both PowerShell editions.

    Who called. The functions also export JB_CALLER=pwsh. setup-system
    reads it: a PowerShell window cannot `exec bash -l`, and needs none of
    the bash reload reasons (each jbx call starts a fresh login bash), so it
    is told to open a new PowerShell window only when an install put a
    directory on the Windows PATH that this window predates (#179).

    Environment:
      JB_PS_PROFILE   the profile file(s) to write, separated like PATH
                      (default: both editions')
      JB_BASH         use this bash; skips the search (tests)
      JB_WINGET       use this winget; empty means "no winget" (tests)
      JB_GET_JB_URL   where get-jb.sh comes from
                      (default https://just-buildit.github.io/get-jb.sh)

.EXAMPLE
    irm https://just-buildit.github.io/get-jb.ps1 | iex

    Install, then `jbx setup-system` sets up the rest of the machine.

.EXAMPLE
    $env:JB_REINSTALL = '1'; irm https://just-buildit.github.io/get-jb.ps1 | iex

    Reinstall jbx even when it is already current.

.NOTES
    Windows PowerShell 5.1 runs a profile only when the execution policy
    allows scripts, and on a fresh Windows client it does not (Restricted).
    The script says so, with the one command that fixes it; it does not
    change a security setting on its own. pwsh 7's default (RemoteSigned)
    already allows it.
#>

# Every name below is removed again when the script finishes (see the end
# of the file), because `irm | iex` defines them in the caller's session.
$JbBlockBegin = '# >>> just-bashit get-jb.ps1 >>>'
$JbBlockEnd = '# <<< just-bashit get-jb.ps1 <<<'
$JbDefaultUrl = 'https://just-buildit.github.io/get-jb.sh'

function Get-JbWingetFlag {
    <#
    .SYNOPSIS
        The flags every winget install carries: no prompt for an agreement
        or a source, so a run never stops to ask.
    .DESCRIPTION
        The same set as pkg.sh's _WINGET_INSTALL_FLAGS; a test
        holds the two equal, since this file is fetched on its own and
        cannot source that one.
    #>
    @('--exact', '--source', 'winget', '--silent', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity')
}

function Test-JbWindows {
    <#
    .SYNOPSIS
        True on Windows, in 5.1 (which has no $IsWindows) and in 7.
    #>
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-GitBashCandidate {
    <#
    .SYNOPSIS
        Where Git for Windows' bash.exe may be, most authoritative first.
    .DESCRIPTION
        The installer records its directory in the registry (machine or
        per-user install, native or WOW64 view). Then the directory of the
        `git` on PATH -- Git\cmd\git.exe or Git\mingw64\bin\git.exe, both two
        levels below the root. Then the default install directories.
    #>
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in 'HKLM:\SOFTWARE\GitForWindows',
        'HKLM:\SOFTWARE\WOW6432Node\GitForWindows',
        'HKCU:\SOFTWARE\GitForWindows') {
        $p = Get-ItemProperty -Path $key -Name InstallPath -ErrorAction SilentlyContinue
        if ($p) { $roots.Add($p.InstallPath) }
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($git) {
        $root = Split-Path (Split-Path $git.Source -Parent) -Parent
        if ((Split-Path $root -Leaf) -eq 'mingw64') { $root = Split-Path $root -Parent }
        $roots.Add($root)
    }
    foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) {
        if ($base) { $roots.Add((Join-Path $base 'Git')) }
    }
    if ($env:LOCALAPPDATA) { $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git')) }
    foreach ($r in $roots) { Join-Path $r 'bin\bash.exe' }
}

function Find-GitBash {
    <#
    .SYNOPSIS
        The first candidate that exists and is not the WSL launcher, or
        nothing.
    .DESCRIPTION
        System32\bash.exe starts WSL, a whole Linux distribution with its
        own filesystem, and is never a substitute: jbx installed there would
        live in a different home than the one Windows sees. It is refused
        by path, however a candidate list came to name it.
    .EXAMPLE
        Find-GitBash -Candidate 'C:\Windows\System32\bash.exe', 'C:\Program Files\Git\bin\bash.exe'
    #>
    param([AllowEmptyCollection()][string[]]$Candidate = @(Get-GitBashCandidate))
    foreach ($c in $Candidate) {
        if (-not $c) { continue }
        if ($c -match '[\\/](System32|SysWOW64|Sysnative)[\\/]bash\.exe$') { continue }
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
}

function Find-JbWinget {
    <#
    .SYNOPSIS
        The winget to run, or nothing. JB_WINGET overrides; set and empty
        means there is none.
    #>
    if (Test-Path Env:JB_WINGET) { return $env:JB_WINGET }
    $w = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($w) { $w.Source }
}

function Install-JbWingetPackage {
    <#
    .SYNOPSIS
        winget install one id with the shared flags. The caller decides
        success by probing for what it needed, not by winget's exit code,
        which is an HRESULT with no stable meaning for "already present".
    #>
    param([Parameter(Mandatory)][string]$Winget, [Parameter(Mandatory)][string]$Id)
    $flags = @(Get-JbWingetFlag)
    Write-Information "  ->  winget install --id $Id"
    & $Winget install --id $Id @flags
}

function Add-JbWingetLink {
    <#
    .SYNOPSIS
        Put winget's Links directories on this session's PATH.
    .DESCRIPTION
        winget links a portable package such as uv there and adds the
        directory to the USER PATH -- which a running session never
        rereads. Adding it here is what lets bash, which inherits this
        environment, see a uv installed a moment ago.
    #>
    $dirs = @()
    if ($env:LOCALAPPDATA) { $dirs += Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links' }
    if ($env:ProgramFiles) { $dirs += Join-Path $env:ProgramFiles 'WinGet\Links' }
    $parts = @($env:PATH -split [IO.Path]::PathSeparator)
    foreach ($d in $dirs) {
        if ((Test-Path -LiteralPath $d) -and ($parts -notcontains $d)) {
            $env:PATH = $d + [IO.Path]::PathSeparator + $env:PATH
        }
    }
}

function Find-JbUv {
    <#
    .SYNOPSIS
        The uv this session can run, or nothing.
    #>
    $uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($uv) { $uv.Source }
}

function Get-JbProfilePath {
    <#
    .SYNOPSIS
        The profile files the jbx block goes in.
    .DESCRIPTION
        JB_PS_PROFILE, when set, names the only ones: one path, or several
        separated like PATH (`;` on Windows, `:` elsewhere). On Windows,
        otherwise, the CurrentUserAllHosts profile of both editions -- 5.1
        and 7 read different files -- under Documents as Windows resolves
        it. Elsewhere (pwsh on Linux or macOS), this host's own.
    #>
    if ($env:JB_PS_PROFILE) {
        return @($env:JB_PS_PROFILE -split [regex]::Escape([IO.Path]::PathSeparator) |
            Where-Object { $_ })
    }
    if (Test-JbWindows) {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        Join-Path $docs 'WindowsPowerShell\profile.ps1'
        Join-Path $docs 'PowerShell\profile.ps1'
        return
    }
    $PROFILE.CurrentUserAllHosts
}

function Get-JbDriverPath {
    <#
    .SYNOPSIS
        Where jbx-ps.sh lives: Windows' per-user app data, or the XDG data
        directory elsewhere.
    #>
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $HOME '.local/share' }
    Join-Path (Join-Path $base 'just-bashit') 'jbx-ps.sh'
}

function Get-JbDriverText {
    <#
    .SYNOPSIS
        The bash side of the forwarding functions.
    .DESCRIPTION
        Rebuilds "$@" from JB_PS_ARGC and JB_PS_ARG1..N, unsets them so they
        do not leak into what jbx runs, puts ~/.local/bin first on PATH
        (where get-jb.sh installed jbx), and execs the command the function
        named in JB_PS_NAME. An argument PowerShell sent as empty arrives
        empty: Windows deletes a variable set to '', and an unset one reads
        as '' here.
    #>
    @'
# jbx-ps.sh -- written by get-jb.ps1, which also refreshes it. The
# PowerShell jbx function passes its arguments in the environment, not on
# bash's command line, which the MSYS runtime would glob and re-quote.
_jb_n=${JB_PS_ARGC:-0}
_jb_i=1
set --
while [ "${_jb_i}" -le "${_jb_n}" ]; do
	eval "set -- \"\$@\" \"\${JB_PS_ARG${_jb_i}-}\""
	unset "JB_PS_ARG${_jb_i}"
	_jb_i=$((_jb_i + 1))
done
_jb_cmd=${JB_PS_NAME:-jbx}
unset JB_PS_ARGC JB_PS_NAME _jb_i _jb_n
case ":${PATH}:" in
*":${HOME}/.local/bin:"*) ;;
*) PATH="${HOME}/.local/bin:${PATH}" ;;
esac
exec "${_jb_cmd}" "$@"
'@
}

function Get-JbProfileBlock {
    <#
    .SYNOPSIS
        The lines between the markers: jbx and just-runit as functions that
        forward to bash.
    .DESCRIPTION
        One body, stamped out per name. `global:` so the same text defines
        them in this session (from inside a function) and in a profile.

        Forwarding, in order: the arguments go in the environment (see the
        driver), an array argument joined with commas -- PowerShell parses an
        unquoted `-s sshd,git` as an array, which [string] would join with a
        space, and every comma list jbx takes (-s, -x) means `sshd,git`
        (#196); MSYS=noglob is added so the runtime does not expand a `*`
        either way; pipeline input is piped to bash only when there is some,
        because piping nothing would hand bash an empty stdin instead of the
        console and break every prompt; JB_CALLER=pwsh tells what runs that
        it was called from PowerShell, so setup-system's closing advice is
        "open a new PowerShell window" and never `exec bash -l` (#179); and
        every variable is put back as it was, even on Ctrl-C. A variable that was absent is REMOVED, not set
        to $null: pwsh 7 keeps a variable set that way, empty, and the next
        call would hand bash the previous call's extra arguments. A native call sets $LASTEXITCODE, so jbx's exit
        status is there to read afterwards.
    #>
    param([Parameter(Mandatory)][string]$Bash, [Parameter(Mandatory)][string]$Driver)
    $b = $Bash -replace "'", "''"
    $d = $Driver -replace "'", "''"
    $lines = @(
        '# jbx runs in Git for Windows'' bash, which you never have to open.'
        '# Written by get-jb.ps1 (https://just-buildit.github.io/get-jb.ps1);'
        '# re-run it to refresh this block, or delete the block to remove jbx.'
    )
    foreach ($name in 'jbx', 'just-runit') {
        $lines += @(
            "function global:$name {"
            "    `$set = @{ JB_PS_NAME = '$name'; JB_PS_ARGC = [string]`$args.Count; JB_CALLER = 'pwsh'"
            "        MSYS = ((([string]`$env:MSYS) + ' noglob').Trim()) }"
            "    for (`$i = 0; `$i -lt `$args.Count; `$i++) {"
            "        `$v = `$args[`$i]"
            "        if (`$v -is [array]) { `$v = `$v -join ',' }"
            "        `$set[""JB_PS_ARG`$(`$i + 1)""] = [string]`$v"
            "    }"
            "    `$saved = @{}"
            "    foreach (`$k in `$set.Keys) {"
            "        `$saved[`$k] = [Environment]::GetEnvironmentVariable(`$k)"
            "        [Environment]::SetEnvironmentVariable(`$k, `$set[`$k])"
            "    }"
            "    try {"
            "        if (`$MyInvocation.ExpectingInput) { `$input | & '$b' -l '$d' }"
            "        else { & '$b' -l '$d' }"
            "    } finally {"
            "        foreach (`$k in `$saved.Keys) {"
            "            if (`$null -eq `$saved[`$k]) { Remove-Item -LiteralPath ""Env:`$k"" -ErrorAction SilentlyContinue }"
            "            else { Set-Item -LiteralPath ""Env:`$k"" -Value `$saved[`$k] }"
            "        }"
            "    }"
            "}"
        )
    }
    , $lines
}

function Merge-JbProfileBlock {
    <#
    .SYNOPSIS
        Replace the marked block in a profile's lines with Body; keep every
        other line exactly as it was.
    .DESCRIPTION
        The contract windows-sshd.ps1's Merge-ManagedBlock keeps (this file
        is fetched alone and cannot share it): a profile with no block yet
        takes the same path as one being refreshed, trailing blank lines are
        trimmed so re-runs do not grow the file, and the block ends the
        file. Stricter in one way: a profile holding more than one block, or
        a begin with no end, is refused rather than guessed at -- that is a
        hand edit, and splicing over it could delete the user's own lines.
    .EXAMPLE
        Merge-JbProfileBlock -Existing @('Set-Alias ll ls') -Body @('function global:jbx {}')
    #>
    param(
        [AllowEmptyCollection()][string[]]$Existing,
        [Parameter(Mandatory)][string[]]$Body
    )
    $begins = @($Existing | Where-Object { $_ -eq $JbBlockBegin }).Count
    $ends = @($Existing | Where-Object { $_ -eq $JbBlockEnd }).Count
    if ($begins -gt 1 -or $begins -ne $ends) {
        throw ("get-jb.ps1: the profile holds $begins '$JbBlockBegin' and " +
            "$ends '$JbBlockEnd' lines; expected one of each or none. " +
            "Refusing to guess -- remove the extra lines and re-run.")
    }
    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in @($Existing)) {
        if ($line -eq $JbBlockBegin) { $skip = $true; continue }
        if ($line -eq $JbBlockEnd) { $skip = $false; continue }
        if (-not $skip) { $kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') {
        $kept.RemoveAt($kept.Count - 1)
    }
    if ($kept.Count -gt 0) { $kept.Add('') }
    $kept.Add($JbBlockBegin)
    foreach ($line in $Body) { $kept.Add($line) }
    $kept.Add($JbBlockEnd)
    , $kept.ToArray()
}

function Read-JbProfile {
    <#
    .SYNOPSIS
        A profile's text and encoding; throws when the file cannot be read.
    .DESCRIPTION
        Its own function so a test can make the read fail: there is no
        portable way to make a real OneDrive placeholder (#202).
    #>
    param([Parameter(Mandatory)][string]$Path)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $reader = New-Object System.IO.StreamReader($Path, $utf8, $true)
    try {
        $text = $reader.ReadToEnd()
        [pscustomobject]@{ Text = $text; Encoding = $reader.CurrentEncoding }
    } finally { $reader.Dispose() }
}

function Get-JbUnreadableReason {
    <#
    .SYNOPSIS
        One line naming an unreadable profile, why, and what to do.
    .DESCRIPTION
        A OneDrive online-only file is told apart from any other failure
        two ways, either enough: its attributes (RecallOnDataAccess
        0x400000 or Offline 0x1000, read with GetAttributes, which does not
        open the file and so recalls nothing), or the error itself being
        ERROR_CLOUD_FILE_PROVIDER_NOT_RUNNING (0x8007016A) anywhere in the
        exception chain.

        The attributes alone are not a reason to skip a file unread: with
        OneDrive running, reading a placeholder downloads it and works, and
        nothing here can tell that OneDrive is the provider or that it runs.
        So the read is always tried, and the attributes only word the
        failure.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Exception)
    $cloud = $false
    try {
        $attr = [int][IO.File]::GetAttributes($Path)
        if ($attr -band (0x400000 -bor 0x1000)) { $cloud = $true }
    } catch { $cloud = $false }
    $e = $Exception
    $detail = $Exception.Message
    while ($e) {
        if ($e.HResult -eq -2147024534) { $cloud = $true }
        $detail = $e.Message
        $e = $e.InnerException
    }
    if ($cloud) {
        return ("get-jb.ps1: skipped $Path -- it is an online-only OneDrive " +
            "file and OneDrive is not running or is uninstalled, so it cannot " +
            "be read, and jb never overwrites a profile it cannot read. To fix: " +
            "recover it from onedrive.com if you want its content, then delete " +
            "the placeholder (or reinstall OneDrive to download it), and re-run " +
            "the one-liner.")
    }
    "get-jb.ps1: skipped $Path -- it could not be read ($($detail.Trim())), " +
        "and jb never overwrites a profile it cannot read. Fix what stops it " +
        "being read, then re-run the one-liner."
}

function Write-JbProfile {
    <#
    .SYNOPSIS
        Write the block into one profile file, keeping its encoding and its
        line endings. Returns why it did not, or nothing.
    .DESCRIPTION
        Windows PowerShell 5.1's `>` writes UTF-16, and a profile may be
        UTF-8 with or without a BOM; whatever the file is, it stays that.
        A new file is UTF-8 without a BOM (the block is ASCII, which every
        edition reads the same way).

        A file that exists and cannot be read is left exactly as it is, and
        the one-line reason is returned for the caller to report (#202):
        writing would replace content that may live only in the cloud.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Body)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $nl = [Environment]::NewLine
    $existing = @()
    if (Test-Path -LiteralPath $Path) {
        try {
            $read = Read-JbProfile -Path $Path
        } catch {
            return (Get-JbUnreadableReason -Path $Path -Exception $_.Exception)
        }
        $text = $read.Text
        $enc = $read.Encoding
        if ($text -match "`r`n") { $nl = "`r`n" } elseif ($text -match "`n") { $nl = "`n" }
        $existing = @($text -split "`r?`n")
    } else {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    $lines = Merge-JbProfileBlock -Existing $existing -Body $Body
    [IO.File]::WriteAllText($Path, (($lines -join $nl) + $nl), $enc)
}

function Write-JbProfileAll {
    <#
    .SYNOPSIS
        Write the block into each profile; return the ones skipped.
    .DESCRIPTION
        One unreadable profile does not stop the others: each is reported
        as it is met, and the caller fails the run once the rest of the
        install is done.
    #>
    param([Parameter(Mandatory)][string[]]$Path, [Parameter(Mandatory)][string[]]$Body)
    foreach ($p in $Path) {
        $why = Write-JbProfile -Path $p -Body $Body
        if ($why) {
            Write-Warning $why
            $p
        } else {
            Write-Information "  ok  jbx function in $p"
        }
    }
}

function Write-JbBanner {
    <#
    .SYNOPSIS
        The same disclaimer get-jb.sh prints, naming this script's URL.
    #>
    $box = @(
        '  +----------------------------------------------------------+'
        '  |  This script is provided AS IS, without warranty of any  |'
        '  |  kind. Review the source before running:                 |'
        '  |  https://just-buildit.github.io/get-jb.ps1               |'
        '  |                                                          |'
        '  |  The tool it installs fetches and executes arbitrary     |'
        '  |  code from URLs you provide. It performs no review,      |'
        '  |  scanning, or sandboxing. You are solely responsible     |'
        '  |  for what you choose to run.                             |'
        '  |                                                          |'
        '  |  Use at your own risk.                                   |'
        '  +----------------------------------------------------------+'
    )
    foreach ($l in $box) { Write-Information $l }
    Write-Information ''
}

function Install-JustBashit {
    <#
    .SYNOPSIS
        The whole install; see the script's own help.
    #>
    # Scoped to this function, so `iex` leaves the caller's settings alone.
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    # Write-Information rather than Write-Host, as windows-sshd.ps1 does:
    # progress a caller can still capture or silence.
    $InformationPreference = 'Continue'

    Write-JbBanner
    $winget = Find-JbWinget

    # -- bash ---------------------------------------------------------------
    if ($env:JB_BASH) { $bash = $env:JB_BASH } else { $bash = Find-GitBash }
    if (-not $bash) {
        if (-not $winget) {
            throw ('get-jb.ps1: no Git for Windows bash.exe found, and no winget ' +
                'to install it with. Install Git for Windows ' +
                '(https://gitforwindows.org) and re-run.')
        }
        Write-Information '  ->  no Git for Windows bash found; installing Git.Git'
        Install-JbWingetPackage -Winget $winget -Id 'Git.Git'
        $bash = Find-GitBash
        if (-not $bash) {
            throw ('get-jb.ps1: winget ran, but Git for Windows bash.exe is still ' +
                'not found. Install Git for Windows (https://gitforwindows.org) ' +
                'and re-run.')
        }
    }
    Write-Information "  ok  bash: $bash"

    # -- uv -----------------------------------------------------------------
    Add-JbWingetLink
    $uv = Find-JbUv
    if ($uv) {
        Write-Information "  ok  uv: $uv"
    } elseif ($winget) {
        Install-JbWingetPackage -Winget $winget -Id 'astral-sh.uv'
        Add-JbWingetLink
        $uv = Find-JbUv
        if ($uv) { Write-Information "  ok  uv: $uv" }
        else { Write-Warning 'uv was NOT installed; jbx setup-system installs it' }
    } else {
        Write-Warning 'no winget, so uv was not installed; jbx setup-system installs it'
    }

    # -- jbx, through get-jb.sh ------------------------------------------------
    # The URL travels in the environment so the command line carries no
    # quote for MSYS to re-parse (see the script's help).
    $urlWasSet = Test-Path Env:JB_GET_JB_URL
    if (-not $urlWasSet) { $env:JB_GET_JB_URL = $JbDefaultUrl }
    try {
        Write-Information "  ->  running $env:JB_GET_JB_URL in bash"
        & $bash -l -c '. <(curl -fsSL $JB_GET_JB_URL)'
        # get-jb.sh is sourced, so its status is that of its last line, not
        # of the install; whether jbx is there is the answer.
        & $bash -l -c 'test -x ~/.local/bin/jbx'
        if ($LASTEXITCODE -ne 0) {
            throw ("get-jb.ps1: get-jb.sh did not install ~/.local/bin/jbx " +
                "(from $env:JB_GET_JB_URL); its output above says why.")
        }
    } finally {
        if (-not $urlWasSet) { Remove-Item Env:JB_GET_JB_URL -ErrorAction SilentlyContinue }
    }

    # -- the driver and the profile ---------------------------------------
    $driver = Get-JbDriverPath
    $dir = Split-Path -Parent $driver
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lf = (Get-JbDriverText) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($driver, $lf, (New-Object System.Text.UTF8Encoding($false)))

    $block = Get-JbProfileBlock -Bash $bash -Driver $driver
    $skipped = @(Write-JbProfileAll -Path @(Get-JbProfilePath) -Body $block)
    . ([scriptblock]::Create($block -join "`n"))

    if (Test-JbWindows) {
        $policy = Get-ExecutionPolicy
        if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned' -or $policy -eq 'Undefined') {
            Write-Warning ("this PowerShell's execution policy ($policy) will not run " +
                'your profile, so new sessions will not have jbx. To allow it: ' +
                'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned')
        }
    }

    # -- prove it -----------------------------------------------------------
    # just-runit, not jbx: the subcommands (version, cache, ...) are the
    # just-runit name's alone, and this proves the second function too.
    just-runit --version
    if ($LASTEXITCODE -ne 0) {
        throw "get-jb.ps1: jbx was installed but did not run (exit $LASTEXITCODE)."
    }
    if ($skipped.Count -gt 0) {
        throw ("get-jb.ps1: jbx works in this session, but its function was " +
            "NOT added to $($skipped -join ', ') (see the warning above), so " +
            "new sessions reading that profile will not have it. Fix it as " +
            "the warning says and re-run.")
    }
    Write-Information ''
    Write-Information '  just-runit is ready, in this session and in new ones.'
    Write-Information ''
    Write-Information '  jbx setup-system                          set up this machine'
    Write-Information '  jbx just-bashit:datetime iso-8601-basic   quick test'
    Write-Information ''
}

# Dot-sourcing defines the functions and stops here, which is how the tests
# reach them without installing anything.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Install-JustBashit
} finally {
    # `irm | iex` runs in the caller's scope: leave only jbx and just-runit
    # behind, as get-jb.sh unsets its helpers.
    foreach ($f in 'Get-JbWingetFlag', 'Test-JbWindows', 'Get-GitBashCandidate',
        'Find-GitBash', 'Find-JbWinget', 'Install-JbWingetPackage',
        'Add-JbWingetLink', 'Find-JbUv', 'Get-JbProfilePath', 'Get-JbDriverPath',
        'Get-JbDriverText', 'Get-JbProfileBlock', 'Merge-JbProfileBlock',
        'Read-JbProfile', 'Get-JbUnreadableReason', 'Write-JbProfile',
        'Write-JbProfileAll', 'Write-JbBanner', 'Install-JustBashit') {
        Remove-Item -Path "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name JbBlockBegin, JbBlockEnd, JbDefaultUrl -ErrorAction SilentlyContinue
}
