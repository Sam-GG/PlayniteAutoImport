# Test-Scan.ps1
# Dry run: reads the real Playnite library straight from LiteDB (read-only,
# against a copy) and reports exactly what the extension would import.
# Nothing is written to Playnite.
#
#   powershell -ExecutionPolicy Bypass -File test\Test-Scan.ps1
#   powershell -ExecutionPolicy Bypass -File test\Test-Scan.ps1 -NamesOnly

[CmdletBinding()]
param(
    [switch]$NamesOnly,      # only run the name-cleaning unit tests
    [switch]$ShowRejected    # also list folders that were skipped, and why
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'src\Scanner.ps1')
. (Join-Path $root 'src\Defaults.ps1')

# --------------------------------------------------------------------------
# 1. Name cleaning
# --------------------------------------------------------------------------

$nameCases = @(
    @{ In = "Call of Duty- Modern Warfare 2";                 Out = "Call of Duty: Modern Warfare 2" }
    @{ In = "Age of Empires III- Definitive Edition";         Out = "Age of Empires III: Definitive Edition" }
    @{ In = "Cities- Skylines II - PC Edition";               Out = "Cities: Skylines II" }
    @{ In = "Return.Of.The.Obra.Dinn";                        Out = "Return Of The Obra Dinn" }
    @{ In = "Untitled.Goose.Game";                            Out = "Untitled Goose Game" }
    @{ In = "Maximum.Action.v0.70";                           Out = "Maximum Action" }
    @{ In = "Nitrox_1.7.1.0";                                 Out = "Nitrox" }
    @{ In = "N++(NPLUSPLUS).v09.12.2017";                     Out = "N++" }
    @{ In = "The Legend of Zelda Twilight Princess HD [AZAP01]"; Out = "The Legend of Zelda Twilight Princess HD" }
    @{ In = "Metal Gear Solid (USA) (Disc 1) (Rev 1)";        Out = "Metal Gear Solid" }
    @{ In = "Legend of Spyro, The - A New Beginning (USA)";   Out = "Legend of Spyro, The - A New Beginning" }
    @{ In = "Golf With Your Friends Win 10";                  Out = "Golf With Your Friends" }
    @{ In = "Dead Space (2023)";                              Out = "Dead Space (2023)" }
    @{ In = "Shapez 2";                                       Out = "Shapez 2" }
    @{ In = "The Jackbox Party Pack 10";                      Out = "The Jackbox Party Pack 10" }
    @{ In = "Marvel's Spider-Man - Miles Morales";            Out = "Marvel's Spider-Man - Miles Morales" }
    @{ In = "Rocksmith 2014 Edition - Remastered";            Out = "Rocksmith 2014 Edition - Remastered" }
    @{ In = "Enter the Gungeon - Advanced Gungeons and Draguns"; Out = "Enter the Gungeon - Advanced Gungeons and Draguns" }
    @{ In = "assetto-server-manager_v1.7.9";                  Out = "assetto-server-manager" }
    @{ In = "Sid Meier's Civilization V";                     Out = "Sid Meier's Civilization V" }
)

$pass = 0; $fail = 0
Write-Host "`n=== Name cleaning ===" -ForegroundColor Cyan
foreach ($c in $nameCases) {
    $actual = ConvertTo-CleanGameName -FolderName $c.In
    if ($actual -ceq $c.Out) {
        $pass++
        Write-Host ("  ok    {0,-52} -> {1}" -f $c.In, $actual) -ForegroundColor DarkGray
    }
    else {
        $fail++
        Write-Host ("  FAIL  {0}" -f $c.In) -ForegroundColor Red
        Write-Host ("        expected: {0}" -f $c.Out) -ForegroundColor Yellow
        Write-Host ("        actual:   {0}" -f $actual) -ForegroundColor Yellow
    }
}
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })

if ($NamesOnly) { return }

# --------------------------------------------------------------------------
# 2. Build a library index straight from Playnite's database
# --------------------------------------------------------------------------

Write-Host "`n=== Reading Playnite library ===" -ForegroundColor Cyan

$live = Join-Path $env:APPDATA 'Playnite\library\games.db'
if (-not (Test-Path -LiteralPath $live)) { throw "Playnite games.db not found at $live" }

# Playnite holds games.db open with no sharing at all, so the dry run needs it
# closed. Note that Playnite may still be in the tray after its window closes.
if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Host ''
    Write-Host 'Playnite is running and holds an exclusive lock on games.db.' -ForegroundColor Red
    Write-Host 'Close it completely (check the system tray) and run this again.' -ForegroundColor Red
    Write-Host 'Name-cleaning tests can still be run with -NamesOnly.' -ForegroundColor Yellow
    exit 2
}

$work = Join-Path $env:TEMP 'playnite-autoimport-test'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item $live (Join-Path $work 'games.db') -Force
Copy-Item (Join-Path $env:LOCALAPPDATA 'Playnite\LiteDB.dll') (Join-Path $work 'LiteDB.dll') -Force
Add-Type -Path (Join-Path $work 'LiteDB.dll')

$dirs  = New-Object 'System.Collections.Generic.List[string]'
$names = New-Object 'System.Collections.Generic.HashSet[string]'

$db = New-Object LiteDB.LiteDatabase("Filename=$work\games.db;Mode=ReadOnly")
try {
    foreach ($doc in $db.GetCollection('Game').FindAll()) {
        if ($doc.ContainsKey('InstallDirectory')) {
            $v = $doc['InstallDirectory'].AsString
            if (-not [string]::IsNullOrWhiteSpace($v)) { $dirs.Add($v) }
        }
        if ($doc.ContainsKey('Name')) {
            [void]$names.Add((ConvertTo-ComparableName $doc['Name'].AsString))
        }
    }
}
finally { $db.Dispose() }

Write-Host ("  {0} games, {1} distinct install dirs" -f $names.Count, $dirs.Count)

$index = @{ Dirs = $dirs; Names = $names }

# --------------------------------------------------------------------------
# 3. Scan
# --------------------------------------------------------------------------

$config = New-DefaultAutoImportConfig
Write-Host "`n=== Scanning ===" -ForegroundColor Cyan
$config.ScanRoots | ForEach-Object { Write-Host "  root: $_" }

$sw = [Diagnostics.Stopwatch]::StartNew()
$found = Find-CandidateGames -Config $config -LibraryIndex $index
$sw.Stop()

Write-Host ("`n=== WOULD IMPORT: {0} games  ({1:n1}s) ===" -f $found.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
$found | ForEach-Object {
    Write-Host ("  {0,-46} {1}" -f $_.Name, $_.ExeName) -ForegroundColor White
    Write-Host ("  {0,-46} {1}" -f '', $_.Directory) -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# 4. What got skipped, and why
# --------------------------------------------------------------------------

if ($ShowRejected) {
    Write-Host "`n=== SKIPPED ===" -ForegroundColor Cyan
    $keep = @{}
    $found | ForEach-Object { $keep[(ConvertTo-NormalizedPath $_.Directory)] = $true }

    foreach ($rootPath in $config.ScanRoots) {
        if (-not (Test-Path -LiteralPath $rootPath)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction SilentlyContinue) {
            if ($keep.ContainsKey((ConvertTo-NormalizedPath $d.FullName))) { continue }

            $reason = $null
            if (Test-IsIgnoredFolder -FolderName $d.Name -FullPath $d.FullName -Config $config) {
                $reason = 'ignore list'
            }
            else {
                foreach ($libDir in $index.Dirs) {
                    if (Test-PathRelated $d.FullName $libDir) { $reason = 'already in library (path)'; break }
                }
                if (-not $reason) {
                    # Same order as Find-CandidateGames: executable first, then
                    # the container question, which depends on where it lives.
                    $exe = Get-MainExecutable -Directory $d.FullName -Config $config
                    if ($null -eq $exe) {
                        $reason = 'no runnable executable'
                    }
                    elseif (Test-IsContainerFolder -Directory $d.FullName -MainExe $exe -Config $config) {
                        $reason = 'container (descended into it)'
                    }
                    else {
                        $reason = 'already in library (name)'
                    }
                }
            }
            Write-Host ("  {0,-28} {1}" -f $reason, $d.Name) -ForegroundColor DarkGray
        }
    }
}
