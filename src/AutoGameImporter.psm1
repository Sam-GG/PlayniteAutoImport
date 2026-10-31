# AutoGameImporter.psm1
# Playnite entry points. Kept deliberately thin: Playnite waits for
# OnApplicationStarted to return before it finishes starting, so these handlers
# only hand work to a background thread (Worker.ps1) and return at once.
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

. (Join-Path $script:Root 'Defaults.ps1')
. (Join-Path $script:Root 'Worker.ps1')    # for Write-AutoImportLog

# State shared with the worker thread. Lives in memory, so it resets when
# Playnite restarts - which is what "dismissed for this session" relies on.
$script:Shared = [hashtable]::Synchronized(@{
    Busy               = $false
    Phase              = 'idle'            # idle | waiting | scanning | reviewing
    WakeNow            = $false
    StartedAt          = [datetime]::MinValue
    LastScanAt         = [datetime]::MinValue
    CurrentFolder      = $null
    FolderSince        = $null
    DismissedSignature = ''
})
$script:Worker = $null

function Get-AutoImportDataPath {
    if (Test-Path variable:global:CurrentExtensionDataPath) {
        if (-not [string]::IsNullOrWhiteSpace($global:CurrentExtensionDataPath)) {
            return $global:CurrentExtensionDataPath
        }
    }
    # Fallback for when the global is unavailable (older hosts, manual runs).
    return (Join-Path $PlayniteApi.Paths.ExtensionsDataPath 'AutoGameImporter')
}

function Get-BusyDescription {
    # One line explaining what the worker is up to, for the log.
    $s = $script:Shared
    $age = [int]([datetime]::UtcNow - $s.StartedAt).TotalSeconds
    $text = "phase '$($s.Phase)' for ${age}s"
    if ($s.CurrentFolder -and $s.FolderSince) {
        $inFolder = [int]([datetime]::UtcNow - $s.FolderSince).TotalSeconds
        $text += ", in $($s.CurrentFolder) for ${inFolder}s"
    }
    return $text
}

function Remove-FinishedWorker {
    $w = $script:Worker
    if ($null -eq $w -or -not $w.Handle.IsCompleted) { return }
    try { [void]$w.PowerShell.EndInvoke($w.Handle) } catch { }
    try { $w.PowerShell.Dispose() } catch { }
    try { $w.Runspace.Dispose() } catch { }
    $script:Worker = $null
}

function Start-AutoImportScan {
    <#
    .SYNOPSIS
        Starts a scan on a background thread and returns immediately.
    .PARAMETER Reason
        'startup' makes the worker wait for the startup library update before
        scanning. Anything else scans straight away.
    #>
    param([Parameter(Mandatory = $true)][string]$Reason)

    $s = $script:Shared
    try {
        $config = Get-AutoImportConfig -DataPath (Get-AutoImportDataPath)

        if ($s.Busy) {
            if ($s.Phase -eq 'waiting' -and $Reason -ne 'startup') {
                # The startup worker is holding off until Playnite's own import
                # finishes. That has now happened, so let it go.
                $s.WakeNow = $true
                return
            }
            Write-AutoImportLog "scan requested ($Reason) while one is still running: $(Get-BusyDescription)" -Level Warn
            return
        }

        $since = ([datetime]::UtcNow - $s.LastScanAt).TotalSeconds
        if ($since -lt [double]$config.MinSecondsBetweenScans) {
            Write-AutoImportLog ("skipped ({0}), last scan was {1:n0}s ago" -f $Reason, $since)
            return
        }

        Remove-FinishedWorker

        $s.Busy      = $true
        $s.Phase     = 'starting'
        $s.WakeNow   = $false
        $s.StartedAt = [datetime]::UtcNow

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'          # the review window is WinForms
        $rs.ThreadOptions  = 'UseNewThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('PlayniteApi', $PlayniteApi)
        $rs.SessionStateProxy.SetVariable('__logger', $__logger)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($Root, $Shared, $DataPath, $Reason)
            # PowerShell's worker threads are foreground threads by default; a
            # scan stuck on a dead drive would then keep Playnite's process
            # alive after exit, and the next launch would find it "already
            # running".
            [System.Threading.Thread]::CurrentThread.IsBackground = $true
            try {
                . (Join-Path $Root 'Scanner.ps1')
                . (Join-Path $Root 'Defaults.ps1')
                . (Join-Path $Root 'ReviewDialog.ps1')
                . (Join-Path $Root 'Worker.ps1')
                Invoke-AutoImportWork -Shared $Shared -DataPath $DataPath -Reason $Reason
            }
            catch {
                $msg = $_.Exception.Message
                $level = 'Error'
                if ($msg -like 'AutoImportTimeout*') { $level = 'Warn' }
                try { Write-AutoImportLog "scan stopped: $msg" -Level $level }
                catch { $__logger.Error("[AutoGameImporter] scan stopped: $msg") }
            }
            finally {
                $Shared.CurrentFolder = $null
                $Shared.Phase = 'idle'
                $Shared.Busy  = $false
            }
        }).AddArgument($script:Root).AddArgument($s).AddArgument((Get-AutoImportDataPath)).AddArgument($Reason)

        $handle = $ps.BeginInvoke()
        $script:Worker = @{ PowerShell = $ps; Runspace = $rs; Handle = $handle }
    }
    catch {
        $s.Busy  = $false
        $s.Phase = 'idle'
        Write-AutoImportLog "could not start scan ($Reason): $($_.Exception.Message)" -Level Error
    }
}

# --------------------------------------------------------------------------
# Playnite events - must return quickly
# --------------------------------------------------------------------------

function OnApplicationStarted {
    try {
        $config = Get-AutoImportConfig -DataPath (Get-AutoImportDataPath)
        if ($config.ScanOnStartup) { Start-AutoImportScan -Reason 'startup' }
    }
    catch { Write-AutoImportLog "OnApplicationStarted: $($_.Exception.Message)" -Level Error }
}

function OnLibraryUpdated {
    try {
        $config = Get-AutoImportConfig -DataPath (Get-AutoImportDataPath)
        if ($config.ScanOnLibraryUpdate) { Start-AutoImportScan -Reason 'library update' }
    }
    catch { Write-AutoImportLog "OnLibraryUpdated: $($_.Exception.Message)" -Level Error }
}
