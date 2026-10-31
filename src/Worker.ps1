# Worker.ps1
# Everything that touches the disk or the Playnite database. It runs on a
# background thread with its own PowerShell runspace (see Start-AutoImportScan
# in AutoGameImporter.psm1), because Playnite waits for OnApplicationStarted to
# return before it finishes starting up: doing this work inline froze Playnite
# for as long as the scan took - normally ~8 seconds, indefinitely if anything
# on disk stalled.
#
# Expects these variables in the runspace: $PlayniteApi, $__logger.

# --------------------------------------------------------------------------
# Logging
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

# --------------------------------------------------------------------------
# Library index
# --------------------------------------------------------------------------

function Get-GamesSnapshot {
    <#
        Copies the game list out of Playnite. Enumerating it while another thread
        modifies it can throw "Collection was modified", so retry briefly
        instead of failing the scan.
    #>
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try { return @($PlayniteApi.Database.Games) }
        catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Get-PlayniteLibraryIndex {
    <#
        Everything Playnite already knows about, in the shape Find-CandidateGames
        expects. Names are included so a folder that was renamed on disk does not
        reappear as a "new" game.
    #>
    $dirs  = New-Object 'System.Collections.Generic.List[string]'
    $names = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($g in (Get-GamesSnapshot)) {
        if (-not [string]::IsNullOrWhiteSpace($g.InstallDirectory)) { $dirs.Add($g.InstallDirectory) }
        if (-not [string]::IsNullOrWhiteSpace($g.Name)) { [void]$names.Add((ConvertTo-ComparableName $g.Name)) }
        # A game's play action can point somewhere else entirely.
        if ($g.GameActions) {
            foreach ($a in @($g.GameActions)) {
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
    $tag = @($PlayniteApi.Database.Tags) | Where-Object { $_.Name -eq $TagName } | Select-Object -First 1
    if (-not $tag) { $tag = $PlayniteApi.Database.Tags.Add($TagName) }
    if ($tag) { return $tag.Id }
    return $null
}

function Get-PlatformId {
    param([string]$PlatformName)
    if ([string]::IsNullOrWhiteSpace($PlatformName)) { return $null }
    $p = @($PlayniteApi.Database.Platforms) | Where-Object { $_.Name -eq $PlatformName } | Select-Object -First 1
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
# User-facing messages
# --------------------------------------------------------------------------

function Show-AutoImportMessage {
    # Owned by this thread, so it never needs Playnite's UI thread. A hidden
    # TopMost owner keeps it from opening behind the Playnite window.
    param([string]$Text)
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    try {
        [void][System.Windows.Forms.MessageBox]::Show($owner, $Text, 'Auto Game Importer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
    }
    finally { $owner.Dispose() }
}

function Add-AutoImportNotification {
    <#
        Posts a notification to Playnite. Deliberately uses the three-argument
        constructor with no activation action: a PowerShell scriptblock passed as
        the Action crashes Playnite, because Playnite invokes it on the WPF UI
        thread, which has no PowerShell runspace.
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

# --------------------------------------------------------------------------
# The job
# --------------------------------------------------------------------------

function Get-CandidateSignature {
    # Stable fingerprint of a result set, used to tell "the same games again"
    # from "something new showed up".
    param($Candidates)
    $dirs = @($Candidates | ForEach-Object { $_.Directory } | Sort-Object)
    return ($dirs -join '|').ToLowerInvariant()
}

function Invoke-AutoImportWork {
    <#
    .SYNOPSIS
        Waits if asked to, scans, then imports or offers a review.
    .PARAMETER Shared
        Synchronized hashtable shared with the Playnite event handlers.
    .PARAMETER Reason
        'startup' waits for the startup library update (or StartupDelaySeconds)
        before scanning; anything else scans immediately.
    #>
    param(
        [Parameter(Mandatory = $true)]$Shared,
        [Parameter(Mandatory = $true)][string]$DataPath,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $config = Get-AutoImportConfig -DataPath $DataPath

    # --- 1. Let Playnite finish its own startup import first --------------
    if ($Reason -eq 'startup') {
        $Shared.Phase = 'waiting'
        $until = [datetime]::UtcNow.AddSeconds([double]$config.StartupDelaySeconds)
        while ([datetime]::UtcNow -lt $until -and -not $Shared.WakeNow) {
            Start-Sleep -Milliseconds 250
        }
        if ($Shared.WakeNow) { $Reason = 'startup, after library update' }
        else { $Reason = "startup, after $($config.StartupDelaySeconds)s" }
    }
    $Shared.WakeNow    = $false
    $Shared.Phase      = 'scanning'
    $Shared.LastScanAt = [datetime]::UtcNow

    # --- 2. Scan ------------------------------------------------------------
    Write-AutoImportLog "scanning ($Reason): $(@($config.ScanRoots) -join '; ')"
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $index = Get-PlayniteLibraryIndex
    Write-AutoImportLog ("library index: {0} names, {1} paths in {2:n1}s" -f
        $index.Names.Count, $index.Dirs.Count, $sw.Elapsed.TotalSeconds)

    $timeout  = [double]$config.ScanTimeoutSeconds
    $slowSecs = [double]$config.SlowFolderSeconds
    $progress = {
        param($path)
        $now = [datetime]::UtcNow
        $prev = $Shared.CurrentFolder
        if ($prev -and $Shared.FolderSince) {
            $took = ($now - $Shared.FolderSince).TotalSeconds
            if ($took -ge $slowSecs) { Write-AutoImportLog ("slow folder: {0} took {1:n1}s" -f $prev, $took) -Level Warn }
        }
        if ($sw.Elapsed.TotalSeconds -gt $timeout) {
            throw "AutoImportTimeout: gave up after $([int]$sw.Elapsed.TotalSeconds)s, before $path"
        }
        $Shared.CurrentFolder = $path
        $Shared.FolderSince   = $now
    }

    $found = @(Find-CandidateGames -Config $config -LibraryIndex $index -OnProgress $progress)
    $Shared.CurrentFolder = $null
    $sw.Stop()

    Write-AutoImportLog ("found {0} candidate(s) in {1:n1}s" -f $found.Count, $sw.Elapsed.TotalSeconds)
    if ($found.Count -eq 0) { return }

    # --- 3. Import ----------------------------------------------------------
    if ($config.AutoAddWithoutReview) {
        $added = Add-GamesToPlaynite -Games $found -Config $config
        Add-AutoImportNotification -Id 'autoimport-added' -Text (
            "Auto Import added $(@($added).Count) game(s). Run Download Metadata on the '$($config.ImportedTagName)' tag.")
        return
    }

    # Do not nag with a set the user has already waved away this session.
    $signature = Get-CandidateSignature -Candidates $found
    if ($signature -eq $Shared.DismissedSignature) {
        Write-AutoImportLog 'same set was dismissed earlier this session; staying quiet'
        return
    }

    $Shared.Phase = 'reviewing'
    $review = Show-ImportReviewDialog -Candidates $found
    if (-not $review.Confirmed) {
        # Cancelling means "not now". Remember this exact set so the window does
        # not reappear on the next library update; a different set still asks.
        $Shared.DismissedSignature = $signature
        Write-AutoImportLog 'review cancelled; will not re-prompt for the same set this session'
        return
    }

    if (@($review.IgnorePaths).Count -gt 0) {
        # Re-read so edits made while the window was open are not lost.
        $config = Get-AutoImportConfig -DataPath $DataPath
        $config.IgnoredPaths = @(@($config.IgnoredPaths) + @($review.IgnorePaths) | Select-Object -Unique)
        Save-AutoImportConfig -DataPath $DataPath -Config $config
        Write-AutoImportLog "ignoring $(@($review.IgnorePaths).Count) folder(s) from now on"
    }

    $added = Add-GamesToPlaynite -Games $review.Games -Config $config
    if (@($added).Count -gt 0) {
        Show-AutoImportMessage (
            "Imported $(@($added).Count) game(s)." + [Environment]::NewLine + [Environment]::NewLine +
            "Select the '$($config.ImportedTagName)' tag and run Download Metadata to fill in covers and details.")
    }
}
