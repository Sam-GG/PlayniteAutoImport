# Defaults.ps1
# Default configuration + load/save. The live copy lives in
# %AppData%\Playnite\ExtensionsData\<extension id>\config.json
# and is safe to hand-edit; unknown keys are preserved, missing keys are
# back-filled from these defaults on load.

function Find-LikelyGameRoots {
    <#
    .SYNOPSIS
        Guesses where this machine keeps hand-installed games.
    .DESCRIPTION
        Looks for a few conventional folder names at the root of every fixed
        drive. Only used to seed config.json on first run - after that the
        user's own ScanRoots list is authoritative and this is never consulted
        again, so a wrong guess is a one-time edit rather than a lasting
        problem.
    #>
    $names = @('Games', 'PC Games', 'Game', 'GameLibrary')
    $found = @()

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
        if (-not $drive.IsReady) { continue }
        foreach ($n in $names) {
            $path = Join-Path $drive.Name $n
            if (Test-Path -LiteralPath $path -PathType Container) { $found += $path }
        }
    }

    return @($found)
}

function New-DefaultAutoImportConfig {

    # Folders that hold one game each, one level down. Detected once, on first
    # run; edit config.json afterwards to add, remove or correct them.
    $scanRoots = Find-LikelyGameRoots

    # Folder names that are never games. Matched as regex against the folder
    # name only (not the full path), case-insensitively.
    $ignoreNames = @(
        # --- emulators & frontends (managed by Playnite's emulator scanners) ---
        '^RetroArch$'
        '^Citra'
        '^Dolphin'
        '^ePSXe'
        '^VBA\b'
        '^PCSX2'
        '^PPSSPP'
        '^DuckStation'
        '^Cemu'
        '^(Yuzu|Ryujinx|RPCS3|Xenia)'
        '^mugen'
        '^snes$'
        '^Emulators$'

        # --- launchers / storefronts ---
        '^Origin$'
        '^EA\s*(Desktop|Games|App)$'
        '^GOG Galaxy$'
        '^Ubisoft'
        '^Epic Games$'
        '^Steam$'

        # --- mod managers, editors, tooling ---
        'Mod\s*Manager'
        '^Vortex'
        '^Fluffy'
        'Save\s*Editor'
        '^NMSSaveEditor$'
        'server[-\s]*manager'
        '^chromedriver'
        '^Nitrox'
        '^Trainer'
        '^Cheat'

        # --- not-a-game payloads ---
        'Game Stub'
        'Vault Pack'
        'Cross-Gen Pack'
        'Supporter Pack'
        '\bDLC\d*\b'
        'Soundtrack|\bOST\b'
        '\bbackup\b'
        '\bsaves?\b(?!\s*the\b)'
        '^\s*Mods?$'
        'Mods$'

        # --- scratch / junk ---
        '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
        '^\$'
        '^_'
    )

    # Sub-folders that never contain the main executable. "Engine" is the
    # Unreal Engine runtime folder, whose helper binaries otherwise outrank the
    # real game executable.
    $excludeDirPattern = '(?i)(^|\\)(_?CommonRedist|_?Redist|Redistributables?|DirectX|DotNet|vcredist|' +
                         '__Installer|Installer|Prerequisites|Support|EasyAntiCheat|BattlEye|' +
                         'CrashReport\w*|Crashpad|Engine|DXSETUP|Tools|SDK|Mods?)(\\|$)'

    # Folder names that describe structure, not identity. Finding the game in
    # one of these says nothing about whether the parent groups several games.
    $structuralDirPattern = '(?i)^(bin|binaries|win32|win64|win|x64|x86|game|games|data|app|' +
                            'launcher|client|build|release|dist|content|program|retail)$'

    # Executable base names that are never the game.
    # Executable base names that are never the game. Anything containing
    # "AntiCheat" is matched anywhere in the name, not just at the start:
    # EA ships EAAntiCheat.Installer.exe right beside the real binary.
    $excludeExePattern = '(?i)^(unins\w*|setup\w*|install\w*|uninstall\w*|vc_?redist\w*|dxsetup|dxwebsetup|' +
                         'dotnet\w*|oalinst|openal\w*|UnityCrashHandler\w*|CrashReport\w*|crashpad\w*|' +
                         'BattlEye\w*|BEService\w*|nvngx\w*|Cleanup|Touchup|activation|' +
                         'DXSETUP|vcredist\w*|python\w*|7z\w*|ffmpeg|notepad|dotNetFx\w*)$' +
                         '|(?i)anticheat|(?i)^.*_?(redist|prereq)\w*$'

    return [ordered]@{
        # --- what to scan -------------------------------------------------
        ScanRoots          = $scanRoots
        MaxContainerDepth  = 1      # how many levels to descend into group folders
        ExeSearchDepth     = 4      # how deep to hunt for the main .exe

        # --- when to scan -------------------------------------------------
        # With both on, "Update Game Library" (F5) doubles as a manual re-scan.
        ScanOnStartup       = $true
        ScanOnLibraryUpdate = $true
        # Startup fires both events within seconds; this suppresses only that
        # duplicate, so a deliberate F5 later still scans.
        MinSecondsBetweenScans = 90

        # --- what to do with results -------------------------------------
        # $false -> let you review and tick boxes before anything is added
        # $true  -> add everything found, no prompt (turn on once the ignore
        #           list is tuned to your liking)
        # In review mode the window opens as soon as a scan finds something.
        # Cancelling it means "not now": the same set will not be offered again
        # until Playnite restarts or the set on disk changes.
        AutoAddWithoutReview = $false

        # Applied to every imported game so they are easy to find/filter.
        ImportedTagName    = 'Auto-Imported'
        # Leave blank to let the metadata plugins decide the platform.
        PlatformName       = 'PC (Windows)'
        SplitCamelCase     = $false

        # --- filtering ----------------------------------------------------
        IgnoreNamePatterns = $ignoreNames
        IgnoredPaths       = @()    # grown by the "Never ask again" button
        ExcludeDirPattern    = $excludeDirPattern
        ExcludeExePattern    = $excludeExePattern
        StructuralDirPattern = $structuralDirPattern

        # --- bookkeeping --------------------------------------------------
        LastScanUtc        = ''
        ConfigVersion      = 1
    }
}

function Get-AutoImportConfigPath {
    param([string]$DataPath)
    return (Join-Path $DataPath 'config.json')
}

function Get-AutoImportConfig {
    param([Parameter(Mandatory = $true)][string]$DataPath)

    $defaults = New-DefaultAutoImportConfig
    $path     = Get-AutoImportConfigPath -DataPath $DataPath

    if (-not (Test-Path -LiteralPath $path)) {
        if (-not (Test-Path -LiteralPath $DataPath)) {
            New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
        }
        Save-AutoImportConfig -DataPath $DataPath -Config $defaults
        return $defaults
    }

    try {
        $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $defaults
    }

    # Back-fill anything the user's file is missing (e.g. after an upgrade).
    $merged = [ordered]@{}
    foreach ($k in $defaults.Keys) {
        $hasKey = $null -ne ($loaded.PSObject.Properties[$k])
        if ($hasKey) { $merged[$k] = $loaded.$k } else { $merged[$k] = $defaults[$k] }
    }
    # Preserve any extra keys the user added.
    foreach ($p in $loaded.PSObject.Properties) {
        if (-not $merged.Contains($p.Name)) { $merged[$p.Name] = $p.Value }
    }
    return $merged
}

function Save-AutoImportConfig {
    param(
        [Parameter(Mandatory = $true)][string]$DataPath,
        [Parameter(Mandatory = $true)]$Config
    )
    if (-not (Test-Path -LiteralPath $DataPath)) {
        New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
    }
    $path = Get-AutoImportConfigPath -DataPath $DataPath
    ($Config | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
}
