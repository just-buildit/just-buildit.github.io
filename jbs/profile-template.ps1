#Requires -Version 7.0

<#
.SYNOPSIS
    PowerShell profile with the shell niceties bashrc-template.sh provides.

.DESCRIPTION
    The PowerShell half of this repo's shell templates. bashrc-template.sh
    makes bash behave; this makes pwsh behave the same way, so a person moving
    between WSL and Windows on one machine does not have to hold two sets of
    key bindings in their head.

    The headline is Up/Down. In bash, `history-search-backward` bound to the
    arrow keys means typing a prefix and pressing Up walks only the commands
    that START with it. PowerShell's default walks the whole history instead,
    ignoring what you have typed, which is the single biggest day-to-day
    difference between the two shells. PSReadLine can do exactly what bash
    does; it just is not wired that way out of the box.

    Everything here is guarded. A profile that throws makes every session
    start with a red wall, and a profile that assumes it is interactive breaks
    scripts, CI and language servers. Nothing in this file is required for a
    shell to work -- if PSReadLine is missing or too old, the shell is plain
    rather than broken.

.EXAMPLE
    Copy-Item profile-template.ps1 $PROFILE.CurrentUserAllHosts

    Install for every host (console, VS Code, ISE) for this user.

.EXAMPLE
    '. "$HOME/.config/just-bashit/profile.ps1"' | Add-Content $PROFILE.CurrentUserAllHosts

    Dot-source it instead, which is what the bash side does: the template
    stays updatable in one place and $PROFILE holds one line.

.NOTES
    $PROFILE may not be where you expect. With OneDrive's Known Folder Move
    enabled -- the default on many Windows installs -- Documents is redirected
    and $PROFILE resolves to something like

        C:\Users\you\OneDrive\Documents\PowerShell\profile.ps1

    which means the profile syncs between machines outside any version
    control you have chosen. That is fine if you want it and surprising if
    you do not. Run `$PROFILE.CurrentUserAllHosts` to see where yours is
    before you edit anything.
#>

# A profile runs on every session, including ones nobody is watching. Stop on
# nothing: a broken line here should cost its own feature, not the shell.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# PSReadLine -- history, search and key bindings
# ---------------------------------------------------------------------------
# Wrapped whole: PSReadLine is absent in some hosts (a bare `pwsh -NoLogo` in
# a non-console app, older Windows PowerShell) and absent is not an error.
if (Get-Module -ListAvailable -Name PSReadLine) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue

    if (Get-Module PSReadLine) {
        $psrl = (Get-Module PSReadLine).Version

        # The point of the file. Type `git ` and press Up: only commands
        # starting with `git ` are walked, exactly as bash does with
        # history-search-backward bound to the arrow keys.
        #
        # HistorySearchCursorMovesToEnd matters more than it sounds: without
        # it the cursor stays where you left it, so the recalled line looks
        # right and Enter submits it truncated.
        Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        Set-PSReadLineOption -HistorySearchCursorMovesToEnd

        # bashrc-template.sh sets HISTSIZE=100000 with erasedups and append.
        # These are the same three decisions: keep a lot, keep it unique, and
        # write it as you go so a crashed session does not lose the day.
        Set-PSReadLineOption -MaximumHistoryCount 100000
        Set-PSReadLineOption -HistoryNoDuplicates
        Set-PSReadLineOption -HistorySaveStyle SaveIncrementally

        # Tab completion that shows the options rather than cycling blind
        # through them, which is bash's `menu-complete` behaviour.
        Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

        # Ctrl-D ends the session on an empty line and deletes a character
        # otherwise -- one key doing what it does in every POSIX shell.
        Set-PSReadLineKeyHandler -Key Ctrl+d -Function DeleteCharOrExit

        # Ctrl-Left/Right, Home/End and Ctrl-U/K already match bash in
        # PSReadLine's defaults, so they are deliberately not re-bound here:
        # a binding restated is a binding that can drift from the default it
        # was copying.

        # Predictive IntelliSense: history-derived suggestions inline, added
        # in PSReadLine 2.2.
        #
        # The version test is necessary and NOT sufficient, which this file
        # learned the hard way. Prediction also needs a console that supports
        # virtual terminal processing, so on a redirected or non-VT host a
        # new-enough PSReadLine still refuses:
        #
        #     The predictive suggestion feature cannot be enabled because the
        #     console output doesn't support virtual terminal processing or
        #     it's redirected.
        #
        # That is a host fact, not a version fact, and no `if` on the version
        # can see it. Unguarded it painted two red error blocks over the top
        # of every redirected session -- precisely the red wall this file's
        # header promises not to cause. So it is attempted and dropped.
        if ($psrl -ge [version]'2.2.0') {
            try {
                Set-PSReadLineOption -PredictionSource History -ErrorAction Stop
                Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction Stop
            } catch {
                # A shell without inline suggestions is still a shell, and
                # this recurs on every prompt, so it must not be noisy. Not
                # an EMPTY catch though -- PSScriptAnalyzer is right that a
                # silently swallowed error is indistinguishable from one
                # nobody thought about. Write-Verbose is silent by default
                # and there for anyone who goes looking with -Verbose.
                Write-Verbose "PSReadLine prediction unavailable: $_"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Small POSIX-shaped conveniences
# ---------------------------------------------------------------------------
# `which` is muscle memory; PowerShell spells it Get-Command. Defined as a
# function rather than an alias so it can print the PATH entry that won,
# which is the question `which` is actually asked.
function which {
    param([Parameter(Mandatory)][string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $c) { Write-Error "which: $Name not found"; return }
    if ($c.Path) { $c.Path } else { "$($c.Name) [$($c.CommandType)]" }
}

# ---------------------------------------------------------------------------
# Repos
# ---------------------------------------------------------------------------
# One layout on both sides of the machine. sync-repos clones into $HOME/<repo>
# (its ROOT is $HOME unless JM_SYNC_ROOT says otherwise), and WSL uses the
# same names, so `~/doppler` means the same thing in either shell.
#
# Visual Studio defaults its clone dialog to %USERPROFILE%\source\repos, which
# is a different layout for no benefit once the repos are managed by a script.
# Change it in Tools > Options > Source Control > Git Global Settings if you
# use that dialog; nothing else needs to know.
function repo {
    param([Parameter(Mandatory)][string]$Name)
    $p = Join-Path $HOME $Name
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Error "repo: $p does not exist (sync-repos clones into `$HOME)"
        return
    }
    Set-Location -LiteralPath $p
}
