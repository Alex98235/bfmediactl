# bfmediactl

Read and control the current Windows media session (System Media Transport
Controls) from the command line. Any app that publishes to the Windows media
overlay — Spotify, browsers, Windows Media Player, etc. — shows up here.

Built with Zig against the raw WinRT/COM ABI: no C++/WinRT, no `windows-rs`,
and no runtime dependencies beyond what ships with Windows.

## Requirements

- Windows 10 1809+ (build 17763) or Windows 11.
- To build: Zig **0.17.0**.

## Install

One-shot, per-user, no admin. From a source checkout:

```powershell
zig build
.\install.ps1
```

`install.ps1` copies `bfmediactl.exe` to `%LOCALAPPDATA%\Programs\bfmediactl`
and appends that directory to your **user** PATH. Re-running it upgrades in
place; `.\install.ps1 -Uninstall` removes both. Restart your shell afterwards
if the command isn't found yet.

## Usage

```
bfmediactl [info] [--source <substr>]      print the current session as JSON
bfmediactl list                            list sessions as JSON
bfmediactl play|pause|toggle               transport control
bfmediactl next|prev|stop                  transport control
bfmediactl seek <ms>                       seek to a position
bfmediactl shuffle <on|off>                toggle shuffle
bfmediactl repeat <none|track|list>        set repeat mode
```

Options:

- `-s`, `--source <substr>` — pick the session whose `SourceAppUserModelId`
  contains `<substr>` (case-insensitive), instead of the OS "current" session.
- `-h`, `--help`

Transport commands are silent on success and exit non-zero on failure, with a
distinct error name:

| Error | Meaning |
| --- | --- |
| `Rejected` | The source refused the request. |
| `CallFailed` | The call/async operation failed. |
| `OutOfRange` | `seek` position exceeds what the tick conversion can hold. |
| `InvalidValue` | Bad argument (e.g. a negative or non-numeric position). |
| `NoMediaSession` | No matching session. |

## JSON output

`info` prints one object; `list` prints an array of `{source, status}`.

```json
{
  "source": "Spotify.exe",
  "status": "playing",
  "title": "Parabola",
  "artist": "TOOL",
  "album": "Lateralus",
  "albumArtist": "TOOL",
  "trackNumber": 7,
  "positionMs": 268967,
  "durationMs": 363857,
  "rate": null,
  "shuffle": false,
  "repeat": "list",
  "playbackType": "music",
  "capabilities": {
    "play": false, "pause": true, "stop": true,
    "next": true, "previous": true, "toggle": true,
    "shuffle": true, "repeat": true,
    "rate": false, "position": true,
    "record": false, "fastForward": true, "rewind": true,
    "channelUp": false, "channelDown": false
  }
}
```

- `status`: `closed | opened | changing | stopped | playing | paused`.
- `positionMs` / `durationMs`: `0` for live streams or when unreported.
- `rate`, `shuffle`, `repeat`, `playbackType`: **`null` when the source leaves
  the field unset** (SMTC exposes these as nullable `IReference<T>`).
- `capabilities`: which controls the source advertises. Check these before
  issuing a command — e.g. if `position` is `false`, `seek` will be rejected.
- `repeat`: `none | track | list`. `playbackType`: `unknown | music | video | image`.

## Compatibility

Coverage equals SMTC coverage: if a session appears in the Windows media
flyout (the volume/media popup), `bfmediactl` sees it. What varies is what each
source *publishes*:

- **Metadata is best-effort.** `artist`/`album`/`trackNumber` are frequently
  empty. Browsers often report only a page title.
- **Controls are per-session.** The `capabilities` block tells you what the
  source supports; unsupported commands return `Rejected`.
- **Timeline is a snapshot.** `positionMs` is current as of the source's last
  timeline update and does not tick.
- **Source ids differ in shape**: `Spotify.exe` (Win32) vs
  `SpotifyAB.SpotifyMusic_…!Spotify` (packaged) vs `MSEdge`/`chrome.exe`.
  `--source` substring matching handles all of them.

Not supported by SMTC, therefore not here: per-app/system volume, and (yet)
album art.

## Build

```powershell
zig build          # -> zig-out\bin\bfmediactl.exe
zig build test     # unit tests (pure logic; no live session needed)
zig build run      # build and run
```

## How it works

No C++/WinRT and no generated bindings. The tool loads `combase.dll` at runtime
(`LoadLibraryA` + `GetProcAddress`), and dispatches WinRT interfaces by COM
vtable slot index (`winrt.zig`). `std.DynLib`, `std.Io`, and allocator-heavy
`std` APIs are deliberately avoided because their Windows behaviour is in flux
across recent Zig releases; a thin kernel32 surface is more stable.

- `src/winrt.zig` — types, IIDs, combase exports, HSTRING, vtable dispatch, async.
- `src/smtc.zig` — the `Windows.Media.Control` surface (session, media
  properties, playback info/controls, timeline) and transport commands.
- `src/main.zig` — argument parsing, session selection, JSON output.

Interface IIDs and vtable slot orders were verified against the Windows
`Windows.Media.Control.winmd` metadata (cross-checked with `saltosystems/winrt-go`
and `oh-my-posh`), and are documented inline.
