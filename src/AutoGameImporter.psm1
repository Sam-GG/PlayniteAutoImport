# AutoGameImporter.psm1
# Playnite entry points. Everything substantial lives in the dot-sourced
# helpers so it can be tested without Playnite running.
#
# Playnite supplies these globals to script extensions:
#   $PlayniteApi                  IPlayniteAPI
#   $__logger                     ILogger
#   $CurrentExtensionInstallPath  this folder
#   $CurrentExtensionDataPath     %AppData%\Playnite\ExtensionsData\<id>

$ErrorActionPreference = 'Continue'

$script:Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:Root)) {
    if (Test-Path variable:global:CurrentExtensionInstallPath) { $script:Root = $global:CurrentExtensionInstallPath }
    else { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
}

. (Join-Path $script:Root 'Scanner.ps1')
. (Join-Path $script:Root 'Defaults.ps1')
. (Join-Path $script:Root 'ReviewDialog.ps1')

$script:Pending = @()
# These live in memory, not in config: both should reset when Playnite restarts.
$script:LastScanAt         = [datetime]::MinValue
$script:DismissedSignature = ''

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

function Write-AutoImportLog {
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info')
    $line = "[AutoGameImporter] $Message"
    try {
        switch ($Level) {
            'Info'  { $__logger.Info($line) }
            'Warn'  { $__logger.Warn($line) }
            'Error' { $__logger.Error($line) }
        }
    }
    catch { Write-Host $line }
}

function Add-AutoImportNotification {
    <#
        Posts a notification to Playnite.

        Deliberately uses the three-argument constructor with no activation
        action. Passing a PowerShell scriptblock as the NotificationMessage
        Action crashes Playnite outright: it invokes the delegate on the WPF UI
        thread, which has no PowerShell runspace, and the resulting
        PSInvalidOperationException is unhandled. Anything the user needs to
        click lives on the main menu instead (see the Functions block in
        extension.yaml).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Text
    )
    try {
        $PlayniteApi.Notifications.Add(
            (New-Object Playnite.SDK.NotificationMessage(
                $Id, $Text, [Playnite.SDK.NotificationType]::Info)))
    }
    catch {
        Write-AutoImportLog "could not post notification: $($_.Exception.Message)" -Level Warn
    }
}

function Get-AutoImportDataPath {
    if (Test-Path variable:global:CurrentExtensionDataPath) {
        if (-not [string]::IsNullOrWhiteSpace($global:CurrentExtensionDataPath)) {
            return $global:CurrentExtensionDataPath
        }
    }
    # Fallback for when the global is unavailable (older hosts, manual runs).
    return (Join-Path $PlayniteApi.Paths.ExtensionsDataPath 'AutoGameImporter')
}

# --------------------------------------------------------------------------
# Library index
# --------------------------------------------------------------------------

function Get-PlayniteLibraryIndex {
    <#
        Everything Playnite already knows about, in the shape Find-CandidateGames
        expects. Names are included so a folder that was renamed on disk does not
        reappear as a "new" game.
    #>
    $dirs  = New-Object 'System.Collections.Generic.List[string]'
    $names = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($g in $PlayniteApi.Database.Games) {
        if (-not [string]::IsNullOrWhiteSpace($g.InstallDirectory)) { $dirs.Add($g.InstallDirectory) }
        if (-not [string]::IsNullOrWhiteSpace($g.Name)) { [void]$names.Add((ConvertTo-ComparableName $g.Name)) }
        # A game's play action can point somewhere else entirely.
        if ($g.GameActions) {
            foreach ($a in $g.GameActions) {
                if ($a.Type -eq [Playnite.SDK.Models.GameActionType]::File -and
                    -not [string]::IsNullOrWhiteSpace($a.Path)) {
                    try {
                        $p = Split-Path -Parent $a.Path
                        if ($p) { $dirs.Add($p) }
                    }
                    catch { }
                }
            }
        }
    }

    return @{ Dirs = $dirs; Names = $names }
}

# --------------------------------------------------------------------------
# Creating games
# --------------------------------------------------------------------------

function Get-OrAddTagId {
    param([string]$TagName)
    if ([string]::IsNullOrWhiteSpace($TagName)) { return $null }
    $tag = $PlayniteApi.Database.Tags | Where-Object { $_.Name -eq $TagName } | Select-Object -First 1
    if (-not $tag) { $tag = $PlayniteApi.Database.Tags.Add($TagName) }
    if ($tag) { return $tag.Id }
    return $null
}

function Get-PlatformId {
    param([string]$PlatformName)
    if ([string]::IsNullOrWhiteSpace($PlatformName)) { return $null }
    $p = $PlayniteApi.Database.Platforms | Where-Object { $_.Name -eq $PlatformName } | Select-Object -First 1
    if ($p) { return $p.Id }
    return $null
}

function Add-GamesToPlaynite {
    <#
    .SYNOPSIS
        Turns scan rows into real Playnite games.
    .OUTPUTS
        The Game objects that were added.
    #>
    param(
        [Parameter(Mandatory = $true)]$Games,
        [Parameter(Mandatory = $true)]$Config
    )

    $rows = @($Games)
    if ($rows.Count -eq 0) { return @() }

    $tagId      = Get-OrAddTagId  -TagName      $Config.ImportedTagName
    $platformId = Get-PlatformId  -PlatformName $Config.PlatformName
    $added      = @()

    foreach ($row in $rows) {
        try {
            $game = New-Object Playnite.SDK.Models.Game
            $game.Name             = $row.Name
            $game.InstallDirectory = $row.Directory
            $game.IsInstalled      = $true
            # PluginId stays empty: that is what makes it a manually added game,
            # which is exactly how the metadata plugins want to see it.

            $action              = New-Object Playnite.SDK.Models.GameAction
            $action.Type         = [Playnite.SDK.Models.GameActionType]::File
            $action.Path         = $row.Exe
            $action.WorkingDir   = (Split-Path -Parent $row.Exe)
            $action.Name         = 'Play'
            $action.IsPlayAction = $true

            $game.GameActions = New-Object 'System.Collections.ObjectModel.ObservableCollection[Playnite.SDK.Models.GameAction]'
            $game.GameActions.Add($action)

            if ($tagId) {
                $game.TagIds = New-Object 'System.Collections.Generic.List[System.Guid]'
                $game.TagIds.Add($tagId)
            }
            if ($platformId) {
                $game.PlatformIds = New-Object 'System.Collections.Generic.List[System.Guid]'
                $game.PlatformIds.Add($platformId)
            }

            [void]$PlayniteApi.Database.Games.Add($game)
            $added += $game
            Write-AutoImportLog "added '$($row.Name)' -> $($row.Exe)"
        }
        catch {
            Write-AutoImportLog "failed to add '$($row.Name)': $($_.Exception.Message)" -Level Error
        }
    }

    return $added
}

# --------------------------------------------------------------------------
# Flow
# --------------------------------------------------------------------------

function Get-CandidateSignature {
    # Stable fingerprint of a result set, used to tell "the same games again"
    # from "something new showed up".
    param($Candidates)
    $dirs = @($Candidates | ForEach-Object { $_.Directory } | Sort-Object)
    return ($dirs -join '|').ToLowerInvariant()
}

function Invoke-ReviewAndImport {
    <#
        Shows the review window for whatever the last scan turned up and
        imports the user's picks. Safe to call from a notification callback.
    #>
    $config = Get-AutoImportConfig -DataPath (Get-AutoImportDataPath)
    $rows   = @($script:Pending)
    if ($rows.Count -eq 0) {
        $PlayniteApi.Dialogs.ShowMessage('No pending games. Run a scan first.', 'Auto Import')
        return
    }

    try {
        $review = Show-ImportReviewDialog -Candidates $rows
    }
    catch {
        Write-AutoImportLog "review dialog failed: $($_.Exception.Message)" -Level Error
        $PlayniteApi.Dialogs.ShowErrorMessage(
            "Could not open the review window: $($_.Exception.Message)", 'Auto Import')
        return
    }

    if (-not $review.Confirmed) {
        # Cancelling means "not now". Remember this exact set so the window does
        # not reappear on the next library update; a different set still asks.
        $script:DismissedSignature = Get-CandidateSignature -Candidates $rows
        Write-AutoImportLog 'review cancelled; will not re-prompt for the same set this session'
        return
    }

    if (@($review.IgnorePaths).Count -gt 0) {
        $list = @($config.IgnoredPaths) + @($review.IgnorePaths)
        $config.IgnoredPaths = @($list | Select-Object -Unique)
        Save-AutoImportConfig -DataPath (Get-AutoImportDataPath) -Config $config
    }

    $added = Add-GamesToPlaynite -Games $review.Games -Config $config
    $script:Pending = @()

    if (@($added).Count -gt 0) {
        $PlayniteApi.Dialogs.ShowMessage(
            "Imported $(@($added).Count) game(s)." + [Environment]::NewLine + [Environment]::NewLine +
            "Select the '$($config.ImportedTagName)' tag and run Download Metadata to fill in covers and details.",
            'Auto Import')
    }
}

function Invoke-AutoImportScan {
    <#
    .SYNOPSIS
        The whole job: scan, then either import silently or offer a review.
    .PARAMETER Force
        Ignore the debounce window.
    #>
    param([switch]$Force)

    $dataPath = Get-AutoImportDataPath
    $config   = Get-AutoImportConfig -DataPath $dataPath

    # Playnite fires OnApplicationStarted and OnLibraryUpdated within seconds of
    # each other at startup. Suppress only that duplicate - a deliberate
    # "Update Game Library" later on must still trigger a real scan.
    if (-not $Force) {
        $since = ([datetime]::UtcNow - $script:LastScanAt).TotalSeconds
        if ($since -lt [double]$config.MinSecondsBetweenScans) {
            Write-AutoImportLog ("skipped, last scan was {0:n0}s ago" -f $since)
            return
        }
    }

    Write-AutoImportLog "scanning: $(@($config.ScanRoots) -join '; ')"
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        $index = Get-PlayniteLibraryIndex
        $found = @(Find-CandidateGames -Config $config -LibraryIndex $index)
    }
    catch {
        Write-AutoImportLog "scan failed: $($_.Exception.Message)" -Level Error
        return
    }
    finally { $sw.Stop() }

    $script:LastScanAt  = [datetime]::UtcNow
    $config.LastScanUtc = $script:LastScanAt.ToString('o')
    Save-AutoImportConfig -DataPath $dataPath -Config $config

    Write-AutoImportLog ("found {0} candidate(s) in {1:n1}s" -f $found.Count, $sw.Elapsed.TotalSeconds)
    if ($found.Count -eq 0) { return }

    $script:Pending = $found

    if ($config.AutoAddWithoutReview) {
        $added = Add-GamesToPlaynite -Games $found -Config $config
        $script:Pending = @()
        Add-AutoImportNotification -Id 'autoimport-added' -Text (
            "Auto Import added $(@($added).Count) game(s). Run Download Metadata on the '$($config.ImportedTagName)' tag.")
        return
    }

    # Do not nag with a set the user has already waved away this session.
    if ((Get-CandidateSignature -Candidates $found) -eq $script:DismissedSignature) {
        Write-AutoImportLog 'same set was dismissed earlier this session; staying quiet'
        return
    }

    Invoke-ReviewAndImport
}

# --------------------------------------------------------------------------
# Playnite events
# --------------------------------------------------------------------------

function OnApplicationStarted {
    $config = Get-AutoImportConfig -DataPath (Get-AutoImportDataPath)
    if ($config.ScanOnStartup) { Invoke-AutoImportScan }
}

function OnLibraryUpdated {
    $config = Get-AutoImportConfig -DataPath (Get-AutoImportDataPath)
    if ($config.ScanOnLibraryUpdate) { Invoke-AutoImportScan }
}
