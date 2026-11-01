#Requires -Version 5.1

<#
.SYNOPSIS
    Move Documents, Desktop, Pictures, Music and Videos back from OneDrive
    to the local profile, as the user: no elevation, HKCU only.

.DESCRIPTION
    OneDrive's Known Folder Move points these folders at the OneDrive
    folder, and uninstalling OneDrive does not point them back. A box set
    up that way keeps Documents -- and with it $PROFILE -- inside a folder
    whose files may be online-only placeholders nothing can read any more
    (#202). setup-system's folders step runs this to undo it (#204).

    For each Known Folder Move value under
    HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders
    -- Personal (Documents), Desktop, My Pictures, My Music, My Video --
    whose path resolves under a OneDrive folder:

      1. %USERPROFILE%\<Folder> is created.
      2. robocopy /E /MOVE moves the files there, excluding online-only
         ones: the Offline attribute (/XA:O), and by name any file that is
         RecallOnDataAccess without it. Reading a cloud-only file recalls
         it, so none is opened. A file whose name is already taken in the
         local folder is not moved either (/XC /XN /XO): neither copy is
         overwritten.
      3. The value -- and any other value in the key naming the same
         folder, such as Documents' {F42EE2D3-...} -- is set to
         %USERPROFILE%\<Folder>, REG_EXPAND_SZ.
      4. Each folder is reported: what moved, and how many online-only
         files stayed behind, to download from onedrive.com.
      5. When Documents moved, get-jb.ps1's profile writer rewrites the jbx
         block into the restored Documents' profiles, so PowerShell finds
         jbx there.

    A folder already local is left alone and reported `ok (local)`, so a
    re-run changes nothing.

    When OneDrive would put the redirect straight back -- it is running, or
    a Known Folder Move policy (KFMSilentOptIn, KFMBlockOptOut under
    HKLM:\SOFTWARE\Policies\Microsoft\OneDrive) is set -- nothing is moved
    and OneDrive is not uninstalled; that is a separate choice. It is
    reported, and PowerShell is fixed anyway: the jbx block goes in the
    LOCAL Documents' profiles, and each redirected profile gets, in the
    block's place, a stub that dot-sources its local twin. Lines of the
    user's own outside the block are kept, and a profile that cannot be
    read is never written (get-jb.ps1's Write-JbProfile decides that).

    The last line of output is `result: <summary>`, which setup-system puts
    in its summary; every line before it is progress.

    Environment (tests point every one at scratch state):
      JB_KNOWN_FOLDERS_KEY    the User Shell Folders key to read and write
      JB_ONEDRIVE_POLICY_KEY  the OneDrive policy key to read
      JB_ONEDRIVE_PROCESS     the process name that means OneDrive runs
      USERPROFILE             the local profile the folders move into
      JB_PS_PROFILE           when set, profiles are left alone: the user
                              has named their own

.PARAMETER DryRun
    Report what would move and be written; change nothing.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-folders.ps1 -DryRun

    See which folders are on OneDrive and what a real run would move.
#>
[CmdletBinding()]
param([switch]$DryRun)

# The profile reader, writer and jbx block are get-jb.ps1's; dot-sourcing it
# defines them and stops at its own guard, installing nothing.
. (Join-Path $PSScriptRoot 'get-jb.ps1')

# Value name -> the local folder it is restored to. The one table.
$JbKnownFolders = @(
    [pscustomobject]@{ Name = 'Personal'; Folder = 'Documents' }
    [pscustomobject]@{ Name = 'Desktop'; Folder = 'Desktop' }
    [pscustomobject]@{ Name = 'My Pictures'; Folder = 'Pictures' }
    [pscustomobject]@{ Name = 'My Music'; Folder = 'Music' }
    [pscustomobject]@{ Name = 'My Video'; Folder = 'Videos' }
)
# FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS and FILE_ATTRIBUTE_OFFLINE: either
# marks a file whose data is not on this disk (get-jb.ps1 reads the same two).
$JbCloudAttributes = 0x400000 -bor 0x1000

function Get-JbShellFolderKey {
    <#
    .SYNOPSIS
        The User Shell Folders key: JB_KNOWN_FOLDERS_KEY, else the user's.
    #>
    if ($env:JB_KNOWN_FOLDERS_KEY) { return $env:JB_KNOWN_FOLDERS_KEY }
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
}

function Get-JbShellFolder {
    <#
    .SYNOPSIS
        Every value in the key, unexpanded, as name -> data; empty when the
        key is absent.
    .DESCRIPTION
        Unexpanded, because the data is written back the same way:
        %USERPROFILE% stays a reference, not this user's path today.
    #>
    param([Parameter(Mandatory)][string]$Key)
    $values = @{}
    $item = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
    if (-not $item) { return $values }
    foreach ($n in $item.GetValueNames()) {
        $values[$n] = [string]$item.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
    }
    $values
}

function Write-JbShellFolder {
    <#
    .SYNOPSIS
        Set one value to Data as REG_EXPAND_SZ, which is what Explorer
        writes and what keeps %USERPROFILE% unexpanded.
    #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Data)
    Set-ItemProperty -LiteralPath $Key -Name $Name -Value $Data -Type ExpandString
}

function Test-JbOneDrivePath {
    <#
    .SYNOPSIS
        True when Path is inside a OneDrive folder.
    .DESCRIPTION
        Under a root OneDrive names in the environment (OneDrive,
        OneDriveConsumer, OneDriveCommercial), or through a folder named
        `OneDrive` or `OneDrive - <org>` -- which is how the folder is still
        found after an uninstall has removed the variables.
    .EXAMPLE
        Test-JbOneDrivePath 'C:\Users\me\OneDrive - Contoso\Documents'
    #>
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.TrimEnd('\', '/')
    foreach ($root in $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) {
        if (-not $root) { continue }
        $r = $root.TrimEnd('\', '/')
        if ($p -eq $r -or $p.StartsWith($r + '\', 'OrdinalIgnoreCase') -or
            $p.StartsWith($r + '/', 'OrdinalIgnoreCase')) { return $true }
    }
    foreach ($segment in $p -split '[\\/]') {
        if ($segment -match '^OneDrive( - .+)?$') { return $true }
    }
    $false
}

function Get-JbOneDriveBlock {
    <#
    .SYNOPSIS
        Why OneDrive would redirect the folders again, one reason per item;
        nothing when it would not.
    #>
    $reasons = @()
    $proc = 'OneDrive'
    if ($env:JB_ONEDRIVE_PROCESS) { $proc = $env:JB_ONEDRIVE_PROCESS }
    if (Get-Process -Name $proc -ErrorAction SilentlyContinue) {
        $reasons += 'OneDrive is running'
    }
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    if ($env:JB_ONEDRIVE_POLICY_KEY) { $key = $env:JB_ONEDRIVE_POLICY_KEY }
    $policy = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($policy) {
        foreach ($name in 'KFMSilentOptIn', 'KFMBlockOptOut') {
            $v = $policy.PSObject.Properties[$name]
            if ($v -and "$($v.Value)" -ne '' -and "$($v.Value)" -ne '0') {
                $reasons += "the $name policy is set"
            }
        }
    }
    $reasons
}

function Get-JbFolderInventory {
    <#
    .SYNOPSIS
        The files under Path, split into Local (data on this disk) and Cloud
        (online-only). Enumerating reads attributes only, so no file is
        recalled.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $local = @()
    $cloud = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            if ([int]$f.Attributes -band $JbCloudAttributes) { $cloud += $f } else { $local += $f }
        }
    }
    [pscustomobject]@{ Local = $local; Cloud = $cloud }
}

function Move-JbFolderContent {
    <#
    .SYNOPSIS
        robocopy Source into Destination, moving; return robocopy's exit
        code (below 8 is success).
    .DESCRIPTION
        /XA:O leaves Offline files where they are, and Exclude names the
        RecallOnDataAccess files that lack Offline, so no online-only file
        is opened. /XC /XN /XO leave a file whose name the destination
        already has, so neither copy is overwritten. /R:0 /W:0: a file in
        use is skipped and reported, not waited on.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination,
        [AllowEmptyCollection()][string[]]$Exclude = @())
    $robo = @($Source, $Destination, '/E', '/MOVE', '/XA:O', '/XC', '/XN', '/XO',
        '/R:0', '/W:0', '/NP', '/NJH', '/NJS', '/NFL', '/NDL')
    if ($Exclude.Count -gt 0) { $robo += '/XF'; $robo += $Exclude }
    & robocopy.exe @robo | Out-Null
    $LASTEXITCODE
}

function Get-JbJbxBlock {
    <#
    .SYNOPSIS
        The jbx profile block get-jb.ps1 writes, for this machine's bash and
        driver; nothing when get-jb.ps1 has not installed jbx for
        PowerShell here (no driver), or there is no bash.
    #>
    $driver = Get-JbDriverPath
    if (-not (Test-Path -LiteralPath $driver)) { return }
    $bash = Find-JbBash
    if (-not $bash) { return }
    Get-JbProfileBlock -Bash $bash -Driver $driver
}

function Get-JbProfileStub {
    <#
    .SYNOPSIS
        The block body for a profile Windows still reads from OneDrive: it
        loads the local profile, where the jbx functions are.
    #>
    param([Parameter(Mandatory)][string]$Local)
    $q = $Local -replace "'", "''"
    @(
        '# Documents is still redirected to OneDrive, so this profile only'
        '# loads its local twin, where setup-system put jbx (#204). Written'
        '# by setup-system''s folders step; it goes when the folders move back.'
        "if (Test-Path -LiteralPath '$q') { . '$q' }"
    )
}

function Invoke-JbKnownFolderRestore {
    <#
    .SYNOPSIS
        The whole run; see the script's own help. Writes progress lines,
        then `result: <summary>`.
    #>
    param([switch]$DryRun)
    $InformationPreference = 'Continue'
    $key = Get-JbShellFolderKey
    $values = Get-JbShellFolder -Key $key
    $onedrive = @()
    foreach ($f in $JbKnownFolders) {
        $raw = $values[$f.Name]
        if (-not $raw) {
            Write-Output "$($f.Folder): ok (not redirected)"
            continue
        }
        $path = [Environment]::ExpandEnvironmentVariables($raw)
        if (-not (Test-JbOneDrivePath -Path $path)) {
            Write-Output "$($f.Folder): ok (local)"
            continue
        }
        $onedrive += [pscustomobject]@{
            Name = $f.Name; Folder = $f.Folder; Path = $path
            Local = Join-Path $env:USERPROFILE $f.Folder
            Data = '%USERPROFILE%\' + $f.Folder
        }
    }
    if ($onedrive.Count -eq 0) {
        Write-Output 'result: ok (local)'
        return
    }
    $names = ($onedrive | ForEach-Object { $_.Folder }) -join ', '
    $docs = $onedrive | Where-Object { $_.Name -eq 'Personal' }
    $profiles = -not $env:JB_PS_PROFILE

    $why = @(Get-JbOneDriveBlock)
    if ($why.Count -gt 0) {
        foreach ($r in $onedrive) { Write-Output "$($r.Folder): left on OneDrive ($($r.Path))" }
        Write-Output ("not moved: $($why -join ', '), so OneDrive would redirect " +
            'them again. Quit OneDrive or stop its folder backup (and clear the ' +
            'policy), then re-run: setup-system -s folders')
        $note = 'profile stub not needed'
        if ($docs -and $profiles) {
            $block = Get-JbJbxBlock
            if (-not $block) {
                $note = 'no jbx profile block to keep'
            } elseif ($DryRun) {
                Write-Output "would put jbx in $(Join-Path $docs.Local '*\profile.ps1') and a stub loading it in $(Join-Path $docs.Path '*\profile.ps1')"
                $note = 'profile stub (dry run)'
            } else {
                $local = @(Get-JbProfilePath -Documents $docs.Local)
                $remote = @(Get-JbProfilePath -Documents $docs.Path)
                $skipped = @(Write-JbProfileAll -Path $local -Body $block)
                for ($i = 0; $i -lt $remote.Count; $i++) {
                    $skipped += @(Write-JbProfileAll -Path $remote[$i] -Body (Get-JbProfileStub -Local $local[$i]))
                }
                $note = 'profile stub written'
                if ($skipped.Count -gt 0) { $note = "profile stub written; skipped $($skipped -join ', ')" }
            }
        }
        Write-Output "result: skipped ($names on OneDrive: $($why -join ', '); $note)"
        return
    }

    $done = @()
    $failed = @()
    foreach ($r in $onedrive) {
        $inv = Get-JbFolderInventory -Path $r.Path
        if ($DryRun) {
            Write-Output ("$($r.Folder): would move $($inv.Local.Count) files from $($r.Path) " +
                "to $($r.Local) and point it there; $($inv.Cloud.Count) online-only would stay")
            $done += $r.Folder
            continue
        }
        if (-not (Test-Path -LiteralPath $r.Local)) {
            New-Item -ItemType Directory -Path $r.Local -Force | Out-Null
        }
        if (Test-Path -LiteralPath $r.Path) {
            # Offline is /XA:O's; a placeholder that is only RecallOnDataAccess
            # is excluded by name.
            $exclude = @($inv.Cloud | Where-Object { -not ([int]$_.Attributes -band 0x1000) } |
                    ForEach-Object { $_.FullName })
            $rc = Move-JbFolderContent -Source $r.Path -Destination $r.Local -Exclude $exclude
            if ($rc -ge 8) {
                Write-Output "$($r.Folder): failed (robocopy exit $rc); left pointing at $($r.Path)"
                $failed += $r.Folder
                continue
            }
        }
        Write-JbShellFolder -Key $key -Name $r.Name -Data $r.Data
        # Windows keeps a second value for some folders (Documents'
        # {F42EE2D3-909F-4907-8871-4C22FC0BF756}); one still naming the old
        # path would send part of the shell back there.
        foreach ($n in @($values.Keys)) {
            if ($n -eq $r.Name -or -not $values[$n]) { continue }
            if ([Environment]::ExpandEnvironmentVariables($values[$n]) -eq $r.Path) {
                Write-JbShellFolder -Key $key -Name $n -Data $r.Data
            }
        }
        $after = Get-JbFolderInventory -Path $r.Path
        $line = "$($r.Folder): moved $($inv.Local.Count - $after.Local.Count) files to $($r.Local)"
        if ($after.Cloud.Count -gt 0) {
            $line += "; $($after.Cloud.Count) online-only stayed in $($r.Path) (download them from onedrive.com)"
        }
        if ($after.Local.Count -gt 0) {
            $line += "; $($after.Local.Count) not moved (in use, or the name is taken in $($r.Local)) and still in $($r.Path)"
        }
        Write-Output $line
        $done += $r.Folder
    }

    $note = ''
    if ($docs -and $profiles -and ($done -contains 'Documents')) {
        $block = Get-JbJbxBlock
        if ($block -and $DryRun) {
            Write-Output "would write the jbx block into $(Join-Path $docs.Local '*\profile.ps1')"
        } elseif ($block) {
            $skipped = @(Write-JbProfileAll -Path @(Get-JbProfilePath -Documents $docs.Local) -Body $block)
            if ($skipped.Count -gt 0) { $note = "; profile skipped: $($skipped -join ', ')" }
        }
    }
    $verb = 'restored'
    if ($DryRun) { $verb = 'would restore' }
    if ($done.Count -gt 0 -and -not $DryRun) {
        Write-Output 'sign out and back in so every app sees the restored folders (restarting Explorer is enough for Explorer)'
    }
    if ($failed.Count -gt 0) {
        Write-Output "result: failed ($($failed -join ', ') still on OneDrive; $verb $(@($done) -join ', ')$note)"
    } elseif ($DryRun) {
        Write-Output "result: ok ($verb $($done -join ', ')) (dry run)"
    } else {
        Write-Output "result: ok ($verb $($done -join ', '); sign out to finish$note)"
    }
}

# Dot-sourcing defines the functions and stops here, which is how the tests
# reach them without touching the machine.
if ($MyInvocation.InvocationName -eq '.') { return }

Invoke-JbKnownFolderRestore -DryRun:$DryRun
