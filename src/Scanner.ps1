# Scanner.ps1
# Pure scanning / name-cleaning logic for the Playnite Auto Game Importer.
# Deliberately free of any Playnite SDK dependency so it can be exercised
# standalone (see test\Test-Scan.ps1).

# --------------------------------------------------------------------------
# Normalisation helpers
# --------------------------------------------------------------------------

function ConvertTo-ComparableName {
    # Aggressive normalisation, used only for "are these the same game" checks.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $v = $Value.Normalize([Text.NormalizationForm]::FormD)
    $v = ($v.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark'
    }) -join ''
    $v = $v -replace '&', ' and '
    $v = $v -replace '[^A-Za-z0-9]', ''
    return $v.ToLowerInvariant()
}

function ConvertTo-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Trim().TrimEnd('\', '/').ToLowerInvariant()
}

function Test-PathRelated {
    # True when two paths are the same folder, or one contains the other.
    # Playnite frequently stores a sub-folder as InstallDirectory
    # (e.g. F:\Games\Cyberpunk 2077\bin\x64), so containment must work
    # in both directions.
    param([string]$A, [string]$B)
    $a = ConvertTo-NormalizedPath $A
    $b = ConvertTo-NormalizedPath $B
    if ($a -eq '' -or $b -eq '') { return $false }
    if ($a -eq $b) { return $true }
    return $a.StartsWith($b + '\') -or $b.StartsWith($a + '\')
}

# --------------------------------------------------------------------------
# Folder name -> display name
# --------------------------------------------------------------------------

function ConvertTo-CleanGameName {
    <#
    .SYNOPSIS
        Turns a messy on-disk folder name into something the metadata
        providers have a chance of matching.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FolderName,
        [switch]$SplitCamelCase
    )

    $n = $FolderName

    # 1. Bracketed disc / region / title ids:  [AZAP01]  [NTSC]
    $n = $n -replace '\[[^\]]*\]', ' '

    # 2. Trailing version stamps, handled before dots become spaces:
    #    ".v09.12.2017"  "_1.7.1.0"  " v1.2"
    $n = $n -replace '(?i)[\s\._\-]v?\d+([\._]\d+){1,3}\s*$', ''

    # 3. Dotted / underscored release names -> spaces. Only when the name has
    #    no spaces at all, otherwise this would wreck "Marvel's Spider-Man".
    #    Trim first: steps 1-2 substitute spaces and would otherwise mask a
    #    name that is genuinely space-free ("Maximum.Action.v0.70").
    $n = $n.Trim()
    if ($n -notmatch '\s') {
        if ($n -match '\.') { $n = $n -replace '\.', ' ' }
        if ($n -match '_')  { $n = $n -replace '_',  ' ' }
    }

    # 4. Region / disc parentheticals, and screaming ALL-CAPS ones that are
    #    not a release year:  (USA)  (Rev 1)  (NPLUSPLUS)
    $n = $n -replace '(?i)\((usa|europe|japan|world|ntsc|pal|disc\s*\d+|rev\s*\d+|en|en,[^)]*|demo|beta)\)', ' '
    $n = $n -replace '\((?!(19|20)\d{2}\))[A-Z0-9\+\-]{4,}\)', ' '

    # 5. Release-group / packaging noise.
    $junk = 'repack|fitgirl|dodi|codex|plaza|skidrow|empress|rune|tenoke|elamigos|' +
            'multi\d+|build\s*\d+|x64|x86|win(dows)?\s*(10|11|32|64)|pc\s*edition|' +
            'early\s*access|portable|steam\s*rip'
    $n = $n -replace "(?i)[\s\-\._]+($junk)\b", ' '

    # 6. Any remaining inline "v1.2.3".
    $n = $n -replace '(?i)\bv\d+(\.\d+){1,3}\b', ' '

    # 7. A colon is illegal in a folder name, so people write "Word- Word".
    #    Restore it. Requires a word char immediately before the dash and a
    #    space after, so "Spider-Man" and " - " subtitles are left alone.
    $n = $n -replace '(\w)-\s+', '$1: '

    # 8. Optional CamelCase split ("ItTakesTwo" -> "It Takes Two"). Off by
    #    default: it gets "Thronefall" and "SpiderHeck" wrong.
    if ($SplitCamelCase -and $n -notmatch '\s' -and $n -cmatch '^[A-Z][a-z]+[A-Z]') {
        $n = $n -creplace '(?<=[a-z0-9])(?=[A-Z])', ' '
    }

    # 9. Tidy up.
    $n = $n -replace '\(\s*\)', ' '
    $n = $n -replace '\s{2,}', ' '
    $n = $n.Trim([char[]]@(' ', "`t", '-', ':', '.', '_'))

    if ([string]::IsNullOrWhiteSpace($n)) { return $FolderName }
    return $n
}

# --------------------------------------------------------------------------
# Ignore rules
# --------------------------------------------------------------------------

function Test-IsIgnoredFolder {
    param(
        [Parameter(Mandatory = $true)][string]$FolderName,
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)]$Config
    )

    $normFull = ConvertTo-NormalizedPath $FullPath
    foreach ($p in $Config.IgnoredPaths) {
        if ((ConvertTo-NormalizedPath $p) -eq $normFull) { return $true }
    }
    foreach ($pattern in $Config.IgnoreNamePatterns) {
        if ($FolderName -match $pattern) { return $true }
    }
    return $false
}

# --------------------------------------------------------------------------
# Executable detection
# --------------------------------------------------------------------------

function Get-MainExecutable {
    <#
    .SYNOPSIS
        Picks the most plausible "this is the game" .exe inside a folder.
    .OUTPUTS
        FileInfo, or $null when the folder holds nothing runnable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)]$Config
    )

    $dirInfo = Get-Item -LiteralPath $Directory -ErrorAction SilentlyContinue
    if ($null -eq $dirInfo) { return $null }

    $excludeDirRx = $Config.ExcludeDirPattern
    $excludeExeRx = $Config.ExcludeExePattern

    $all = @(Get-ChildItem -LiteralPath $Directory -Filter '*.exe' -File -Recurse `
                -Depth $Config.ExeSearchDepth -Force -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return $null }

    $rootLen    = $dirInfo.FullName.TrimEnd('\').Length
    $normFolder = ConvertTo-ComparableName $dirInfo.Name

    $best = $null
    $bestScore = [double]::NegativeInfinity

    foreach ($exe in $all) {
        $rel    = $exe.FullName.Substring($rootLen).Trim('\')
        $relDir = Split-Path $rel -Parent
        if ($relDir -and ($relDir -match $excludeDirRx)) { continue }
        if ($exe.BaseName -match $excludeExeRx) { continue }

        $depth = 0
        if ($relDir) { $depth = ($relDir -split '\\').Count }

        $norm  = ConvertTo-ComparableName $exe.BaseName
        $score = 0.0

        # Exact folder/exe name agreement is the strongest signal available.
        if ($norm -eq $normFolder) {
            $score += 1000
        }
        elseif ($norm.Length -ge 4 -and ($normFolder.Contains($norm) -or $norm.Contains($normFolder))) {
            # Containment rather than prefix, so CivilizationV.exe scores inside
            # "Sid Meier's Civilization V" while CivilizationV_Tablet.exe does not.
            $score += 350
        }

        # Engine fingerprints.
        if ($exe.BaseName -match '(?i)-Win(64|GDK|32)-Shipping$') { $score += 600 }
        if (Test-Path -LiteralPath (Join-Path $exe.DirectoryName ($exe.BaseName + '_Data'))) { $score += 500 }
        if (Test-Path -LiteralPath (Join-Path $exe.DirectoryName ($exe.BaseName + '.pck')))  { $score += 400 }

        if ($depth -eq 0) { $score += 200 }
        $score -= 60 * $depth

        # Size, capped so a big installer cannot outrank a real match.
        $score += [Math]::Min($exe.Length / 1MB, 120)

        # Soft penalties for things that are usually not the entry point.
        if ($exe.BaseName -match '(?i)(server|dedicated|editor|tool|config|launcher|helper|updater|report|handler|benchmark)') {
            $score -= 250
        }

        if ($score -gt $bestScore) { $bestScore = $score; $best = $exe }
    }

    return $best
}

# --------------------------------------------------------------------------
# Container detection
# --------------------------------------------------------------------------

function Test-IsContainerFolder {
    <#
    .SYNOPSIS
        Decides whether a folder groups several games (F:\Games\GOG Games)
        rather than being one itself.
    .DESCRIPTION
        The verdict hinges on where the winning executable sits. If the best
        candidate lives in a child folder whose name has nothing to do with
        this folder's name, this folder is a group and we should descend.
        Counting "children that contain an exe" is not reliable: a group may
        legitimately hold only one populated child.
    .PARAMETER MainExe
        The result of Get-MainExecutable for this folder, passed in so the
        expensive search is not repeated.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)]$MainExe,
        [Parameter(Mandatory = $true)]$Config
    )

    if ($null -eq $MainExe) { return $false }

    $rootFull = (Get-Item -LiteralPath $Directory).FullName.TrimEnd('\')

    # 1. Executable directly in the folder -> it is a game.
    $rel = $MainExe.FullName.Substring($rootFull.Length).Trim('\')
    $segments = @($rel -split '\\')
    if ($segments.Count -le 1) { return $false }

    # 2. It needs at least two real children to be worth calling a group.
    $subs = @(Get-ChildItem -LiteralPath $Directory -Directory -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch $Config.ExcludeDirPattern })
    if ($subs.Count -lt 2) { return $false }

    $normFolder = ConvertTo-ComparableName (Split-Path $rootFull -Leaf)

    # 3. An executable named after this very folder means one game spread over
    #    subfolders (ItTakesTwo\Nuts\ItTakesTwo.exe), not a group.
    if ((ConvertTo-ComparableName $MainExe.BaseName) -eq $normFolder) { return $false }
    $selfNamed = Get-ChildItem -LiteralPath $Directory -Filter '*.exe' -File -Recurse `
                    -Depth 2 -Force -ErrorAction SilentlyContinue |
                 Where-Object { (ConvertTo-ComparableName $_.BaseName) -eq $normFolder } |
                 Select-Object -First 1
    if ($selfNamed) { return $false }

    # 4. An Unreal Engine shipping build is always a single game, even though
    #    its folder layout (Engine\ + ShortName\Binaries\Win64\) looks like a
    #    group and the short name rarely matches the display folder.
    if ($MainExe.BaseName -match '(?i)-Win(64|GDK|32)-Shipping$') { return $false }

    # 5. Structural folder names carry no identity, so they cannot tell us this
    #    is a group (Enter the Gungeon\win64\EtG.exe).
    if ($segments[0] -match $Config.StructuralDirPattern) { return $false }

    # 6. If the child holding the executable is named after this folder, it is
    #    still one game (EA SPORTS WRC\WRC\...), so only descend when the two
    #    names are unrelated (GOG Games\Terraria\...).
    $normTop = ConvertTo-ComparableName $segments[0]
    if ($normTop.Length -ge 3 -and $normFolder.Length -ge 3 -and
        ($normFolder.Contains($normTop) -or $normTop.Contains($normFolder))) {
        return $false
    }

    return $true
}

# --------------------------------------------------------------------------
# The scan
# --------------------------------------------------------------------------

function Find-CandidateGames {
    <#
    .SYNOPSIS
        Walks the configured roots and returns every folder that looks like an
        installed game and is not already represented in $LibraryIndex.
    .PARAMETER LibraryIndex
        Hashtable with keys 'Dirs' (string[]) and 'Names'
        (HashSet[string] of comparable names). Pass an empty index to see all.
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$LibraryIndex,
        [scriptblock]$OnProgress
    )

    $results   = @()
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($root in $Config.ScanRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
            [void]$queue.Enqueue([PSCustomObject]@{ Dir = $d; Level = 0 })
        }

        while ($queue.Count -gt 0) {
            $item  = $queue.Dequeue()
            $dir   = $item.Dir
            $level = $item.Level

            if ($OnProgress) { & $OnProgress $dir.FullName }
            if (-not $seenPaths.Add((ConvertTo-NormalizedPath $dir.FullName))) { continue }
            if (Test-IsIgnoredFolder -FolderName $dir.Name -FullPath $dir.FullName -Config $Config) { continue }

            # Already known to Playnite?
            $known = $false
            foreach ($libDir in $LibraryIndex.Dirs) {
                if (Test-PathRelated $dir.FullName $libDir) { $known = $true; break }
            }
            if ($known) { continue }

            $exe = Get-MainExecutable -Directory $dir.FullName -Config $Config
            if ($null -eq $exe) { continue }

            # Group folder -> descend one level instead of importing the folder.
            if ($level -lt $Config.MaxContainerDepth -and
                (Test-IsContainerFolder -Directory $dir.FullName -MainExe $exe -Config $Config)) {
                foreach ($sub in Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue) {
                    [void]$queue.Enqueue([PSCustomObject]@{ Dir = $sub; Level = $level + 1 })
                }
                continue
            }

            $name = ConvertTo-CleanGameName -FolderName $dir.Name -SplitCamelCase:([bool]$Config.SplitCamelCase)

            # Name-level duplicate check runs after cleaning, so that
            # "Return.Of.The.Obra.Dinn" matches an existing "Return of the Obra Dinn".
            if ($LibraryIndex.Names.Contains((ConvertTo-ComparableName $name))) { continue }

            $results += [PSCustomObject]@{
                Name       = $name
                FolderName = $dir.Name
                Directory  = $dir.FullName
                Exe        = $exe.FullName
                ExeName    = $exe.Name
                SizeMB     = [Math]::Round($exe.Length / 1MB, 1)
            }
        }
    }

    return @($results | Sort-Object Name)
}
