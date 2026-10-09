# bfmediactl

Read and control the current Windows media session (System Media Transport
Controls) from the command line. Any app that publishes to the Windows media
overlay — Spotify, browsers, Windows Media Player, etc. — shows up here.

Built with Zig against the raw WinRT/COM ABI: no C++/WinRT, no `windows-rs`,
no runtime dependencies beyond what ships with Windows.

## Status

Scaffold. Requires **Windows 10 1809+** and **Zig 0.17.0**.

## Build

```
zig build
```

Produces `zig-out/bin/bfmediactl.exe`. Run with `zig build run -- <args>`.

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

`--source <substr>` selects the session whose `SourceAppUserModelId` contains
`<substr>` (case-insensitive), instead of the OS "current" session.

Example `info` output:

```json
{"source":"Spotify.exe","status":"playing","title":"…","artist":"…",
 "album":"…","albumArtist":"…","trackNumber":3,"positionMs":12345,
 "durationMs":210000}
```

## Notes

- `positionMs` is the timeline snapshot from `GetTimelineProperties`; it is not
  extrapolated for playback rate.
- Per-app volume is **not** part of SMTC and is not implemented.
- Album art (`Thumbnail`) is not exposed yet.
