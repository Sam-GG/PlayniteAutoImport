# Playnite Auto Game Importer

Playnite's library plugins cover Steam, GOG, Epic, EA, Ubisoft and Xbox. Games
you installed by hand — a DRM-free download, something unzipped into a folder,
a title from a launcher Playnite doesn't integrate with — never show up.

This extension finds them and adds them, with a cleaned-up title and a working
play action, so your existing metadata plugins can take it from there.

> On the library it was built against it found 50 hand-installed games across
> four drives, while correctly ignoring ~28 folders that were emulators, mod
> managers, save backups and DLC stubs.

---

## Requirements

- **Playnite 10.x** (developed and tested against 10.35, SDK 6.11)
- Windows PowerShell 5.1 — ships with Windows, nothing to install
- No compiler, no .NET SDK. It is a PowerShell script extension.

## Install

Clone or download this repository, then:

```bash
powershell -ExecutionPolicy Bypass -File install.ps1
```

Restart Playnite — extensions are loaded once, at startup.

On first run it writes a `config.json`, guessing your game folders by looking
for `Games`, `PC Games`, `Game` or `GameLibrary` at the root of every fixed
drive. Check that guess before the first import; see **Settings** below.

To update after editing anything under `src\`, re-run `install.ps1` and restart
Playnite. To remove it:

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Add `-KeepSettings` to keep your tuned `config.json`.

---

## How it works

On Playnite startup, and after every library update, it:

1. Walks the folders listed in `ScanRoots`, treating each immediate subfolder
   as one game.
2. Skips anything already in your library — matching on install directory
   (in both directions, since Playnite often stores a subfolder such as
   `…\Cyberpunk 2077\bin\x64`), on existing play-action paths, and on a
   normalised name.
3. Skips anything matching the ignore list — emulators, mod managers, save
   backups, DLC stubs, storefront clients.
4. Picks the most plausible executable in each remaining folder.
5. Cleans the folder name into a title a metadata provider can match.
6. Shows you the list. Tick what you want, correct any wrong names inline,
   press **Import ticked**.

Imported games get an `Auto-Imported` tag, the `PC (Windows)` platform, and an
empty `PluginId` — which is what marks a game as manually added.

Because both scan triggers are on by default, **F5 (Update Game Library)
doubles as a manual re-scan**.

### When it scans

Scans always run on a background thread, and Playnite never waits for one.
That matters because Playnite does not finish starting up until every
extension's `OnApplicationStarted` handler returns (see the constraints below).

At startup the scan holds off until Playnite's own startup library update
finishes, so it scans a settled library and already knows about anything that
update just imported. If no library update arrives — say your updates are set
to daily — it starts after `StartupDelaySeconds` instead. A library update
later in the session (F5) scans straight away.

The review window opens on that background thread too, so Playnite stays usable
while it is up.

### After importing

Metadata is **not** fetched automatically. Filter on the `Auto-Imported` tag,
select all, and run **Download Metadata**. Your IGDB / RAWG / SteamGridDB
plugins do the rest.

---

## Picking the executable

Every `.exe` under the folder is scored, and the best one wins:

| Signal | Score |
| --- | ---: |
| Name matches the folder name exactly | +1000 |
| Unreal Engine shipping build (`*-Win64-Shipping.exe`) | +600 |
| Unity layout (a sibling `<name>_Data` folder) | +500 |
| Godot layout (a sibling `<name>.pck`) | +400 |
| Folder name contains the exe name, or vice versa | +350 |
| Sitting in the folder root | +200 |
| Per level of depth | −60 |
| File size, capped so a big installer can't outrank a real match | up to +120 |
| Looks like a launcher, server, editor, updater or crash handler | −250 |

Installers, redistributables, anti-cheat binaries and crash handlers are
excluded outright. **A folder with no runnable executable is not a game** —
that one rule filters out ROM folders, save backups and mod directories
without any name matching at all.

### Group folders

A folder like `D:\Games\GOG Games` holds games rather than being one. The test
is where the winning executable lives: if it sits in a child folder whose name
is unrelated to the parent, the parent is a group and gets descended into.

Unreal layouts and structural folder names (`bin`, `win64`, `binaries`) are
excluded from that test, so `EA SPORTS WRC\WRC\…` and
`The Talos Principle 2\Talos2\…` stay single games rather than being split.

## Cleaning names

| On disk | Imported as |
| --- | --- |
| `Call of Duty- Modern Warfare 2` | `Call of Duty: Modern Warfare 2` |
| `Return.Of.The.Obra.Dinn` | `Return Of The Obra Dinn` |
| `Maximum.Action.v0.70` | `Maximum Action` |
| `N++(NPLUSPLUS).v09.12.2017` | `N++` |
| `Golf With Your Friends Win 10` | `Golf With Your Friends` |
| `The Legend of Zelda Twilight Princess HD [AZAP01]` | `The Legend of Zelda Twilight Princess HD` |
| `Dead Space (2023)` | `Dead Space (2023)` — years are kept |
| `Marvel's Spider-Man - Miles Morales` | unchanged — ` - ` subtitles are left alone |

A colon is illegal in a Windows folder name, so `Word- Word` is read back as a
colon. `Spider-Man` is safe: the rule requires a space *after* the dash.

---

## Settings

`%AppData%\Playnite\ExtensionsData\AutoGameImporter_9f3c1a52-7d41-4b8e-9c20-5e6a1b8d4f77\config.json`

Written on first run, safe to hand-edit, re-read on every scan. Missing keys
are back-filled from the defaults and keys you add yourself are preserved, so
upgrades never clobber your tuning.

| Key | Default | What it does |
| --- | --- | --- |
| `ScanRoots` | auto-detected | Folders holding one game per subfolder |
| `AutoAddWithoutReview` | `false` | `true` imports everything found, no prompt |
| `ScanOnStartup` | `true` | Scan when Playnite launches |
| `ScanOnLibraryUpdate` | `true` | Scan after a library update, making F5 a manual re-scan |
| `StartupDelaySeconds` | `60` | How long the startup scan waits for Playnite's startup library update before going ahead anyway |
| `MinSecondsBetweenScans` | `90` | Ignores a library-update scan this soon after the previous one |
| `ScanTimeoutSeconds` | `120` | Abandons a scan that runs longer than this. A normal one takes ~10s |
| `SlowFolderSeconds` | `5` | Logs any single folder that takes longer than this |
| `ImportedTagName` | `Auto-Imported` | Tag applied to every import |
| `PlatformName` | `PC (Windows)` | Blank leaves the platform to your metadata plugins |
| `SplitCamelCase` | `false` | `ItTakesTwo` → `It Takes Two`, but also `Thronefall` → `Throne Fall`. Off by default; correct names in the dialog instead |
| `IgnoreNamePatterns` | 42 regexes | Matched against the folder name only |
| `IgnoredPaths` | `[]` | Exact folders to skip; grown by the dialog's "Never ask again" checkbox |
| `ExcludeDirPattern` | … | Subfolders that never hold the main executable |
| `ExcludeExePattern` | … | Executable names that are never the game |
| `StructuralDirPattern` | … | Folder names describing structure, not identity |
| `ExeSearchDepth` | `4` | How deep to hunt for the executable |
| `MaxContainerDepth` | `1` | How far to descend into group folders |

Cancelling the review window means "not now": that exact set is not offered
again until Playnite restarts or the set on disk changes.

---

## Tuning

Whenever you change a pattern, check the effect before it touches your library.
The dry run reads your real Playnite database read-only, against a copy, and
writes nothing. **Close Playnite first** — it holds an exclusive lock on
`games.db`, and it may still be in the system tray after its window closes.

```bash
powershell -ExecutionPolicy Bypass -File test\Test-Scan.ps1
```

```bash
powershell -ExecutionPolicy Bypass -File test\Test-Scan.ps1 -ShowRejected
```

`-ShowRejected` lists every folder that was skipped and why — the fastest way
to see whether a pattern is too greedy:

```
ignore list                   Fluffy Mod Manager
no runnable executable        Metal Gear Solid (USA) (Disc 1) (Rev 1)
container (descended into it) GOG Games
already in library (path)     DREDGE
```

Unit tests need neither Playnite nor a visible window:

```bash
powershell -ExecutionPolicy Bypass -File test\Test-Scan.ps1 -NamesOnly
```

```bash
powershell -sta -ExecutionPolicy Bypass -File test\Test-Dialog.ps1
```

---

## Playnite 10.35 constraints worth knowing

All three were found the hard way, and all three shaped the design:

- **Playnite does not finish starting until `OnApplicationStarted` returns.**
  The log shows `Application … started`, and the library import begins, only
  after every extension's handler has come back. Version 1.0 scanned inline
  there, so every launch was ~8 seconds slower — and when the scan stalled once,
  Playnite sat on its splash indefinitely. Version 1.1 hands all work to a
  background runspace and returns in milliseconds. That runspace's thread is
  marked as a background thread, because PowerShell creates foreground threads
  by default: a scan stuck on an unresponsive drive would otherwise keep the
  Playnite process alive after you exit it.
- **A PowerShell scriptblock cannot be a notification's activation action.**
  Playnite invokes that delegate on the WPF UI thread, which has no PowerShell
  runspace; the resulting `PSInvalidOperationException` is unhandled and takes
  the whole application down. Notifications here carry no click action.
- **The `Functions:` manifest key is ignored for script extensions,** so they
  get no main-menu entries. Confirmed by feeding Playnite a deliberately
  malformed value, which loaded without complaint. This is why the extension is
  driven entirely by the startup and library-update events.

Emulated games are left alone — that is Playnite's own emulator scanners' job,
and the ignore list keeps emulator folders out of the way.

## Troubleshooting

Everything the extension does is logged to `%AppData%\Playnite\extensions.log`,
on lines tagged `[AutoGameImporter]`. A healthy startup looks like:

```
scanning (startup, after library update): B:\Games; F:\Games; …
library index: 444 names, 525 paths in 0.3s
found 0 candidate(s) in 8.8s
```

Lines worth knowing:

- **`slow folder: <path> took Ns`** — one folder is dragging the scan out. Add
  it to `IgnoredPaths`, or tighten `ExeSearchDepth`.
- **`scan requested … while one is still running: … in <path> for Ns`** — a
  scan is stuck, and this names the folder it is stuck in.
- **`scan stopped: AutoImportTimeout …`** — a scan exceeded
  `ScanTimeoutSeconds` and was abandoned. Playnite is unaffected.

If Playnite was ever force-closed during startup, the next launch asks whether
to start in safe mode. Answer **No**; it is only reporting that the previous
start never completed.

## Layout

```
src\extension.yaml          Playnite manifest
src\AutoGameImporter.psm1   Playnite events; starts and supervises the worker
src\Worker.ps1              background job: library index, scan, review, import
src\Scanner.ps1             scanning + name cleaning (no Playnite dependency)
src\Defaults.ps1            default config, detection, load/save/merge
src\ReviewDialog.ps1        the review window
test\Test-Scan.ps1          name-cleaning tests + live dry run
test\Test-Dialog.ps1        dialog tests, headless
install.ps1                 deploy to Playnite
```

`Scanner.ps1` deliberately carries no Playnite dependency, so the scanning and
name-cleaning logic can be exercised from a plain PowerShell prompt.

## License

MIT — see [LICENSE](LICENSE).
