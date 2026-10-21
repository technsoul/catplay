# CAT

CAT is a fast IPTV player for Windows, Linux, macOS, Android TV and Android phones.

- **Desktop (Windows, Linux, macOS):** native Rust app in [`desktop/`](desktop/) — egui + libmpv.
  It only redraws on input or when the video has a new frame, so it idles at 0% CPU and stays cool.
- **Android TV and phones:** the Flutter app in `lib/`.

Both use the same database layout, so the desktop app keeps the playlists, favorites and history of
an earlier Flutter desktop install.

- **Sources:** Xtream Codes API, M3U/M3U8 (URL or local file), XMLTV guides (`.xml` / `.xml.gz`)
- **Live TV:** categories, channel list with now/next, preview player, channel zapping, auto-reconnect
- **TV guide:** full-day timeline grid, day picker, programme details, catch-up (Xtream `tv_archive`)
- **Movies & series:** poster grids, sorting, details/plot, seasons & episodes, resume where you left off
- **Downloads:** save movies and episodes (or a whole season) to watch offline, with pause/resume
- **App lock:** optional PIN asked at start-up (salted hash in the OS credential store)
- **Picture-in-picture** (desktop): a small always-on-top video in the screen corner (P)
- **Zoom:** fit, fill (crop) or stretch (Z)
- **Search:** instant full-text search across all playlists (SQLite FTS5, prefix matching)
- **Favorites, continue watching, recent channels**, multiple playlists
- **Playback:** libmpv via `media_kit` — HEVC, AC3/E-AC3, MPEG-TS, HLS, hardware decoding, audio/subtitle tracks

## Desktop app (Rust)

Requirements: Rust (stable) and libmpv at run time — `sudo apt install libmpv2` on Ubuntu 24.04+
(`libmpv1` on 22.04), `brew install mpv` on macOS, or `libmpv-2.dll` next to the exe on Windows.

```bash
cd desktop
cargo run --release
cargo test
```

Packages: `tool/package_linux.sh` (.deb), `tool/package_windows.ps1` (setup .exe),
`tool/package_macos.sh` (.dmg with libmpv bundled).

Troubleshooting a stream: `CAT_MPV_LOG=v` writes mpv's log to `logs/app.log`, and
`CAT_MPV_OPTS="key=value,…"` passes extra mpv options.

## Flutter app (Android)

Requirements: Flutter 3.44+, Visual Studio 2022+ with "Desktop development with C++",
and **Windows Developer Mode** (needed for plugin symlinks: `start ms-settings:developers`).

```bash
flutter run -d windows
```

```bash
flutter build windows --release
```

The release app is in `build/windows/x64/runner/Release/` (copy the whole folder).
To create an installer package:

```bash
dart run msix:create
```

### Android TV and phones

```bash
flutter build apk --release --split-per-abi --dart-define=FORM_FACTOR=tv
flutter build apk --release --split-per-abi --dart-define=FORM_FACTOR=mobile
```

`FORM_FACTOR=tv` (the default) is laid out for a remote on a TV; `mobile` is the touch version for
phones and tablets: portrait or landscape, bottom navigation, single-column pages, and a player that
turns to landscape full screen. Screens narrower than 1000 px or shorter than 520 px get the phone
layout (`lib/ui/layout.dart`).

To work on the phone layout without a device, run the desktop app in a phone-sized window (it keeps
its own data, separate from the normal desktop install):

```bash
flutter run -d windows --dart-define=FORM_FACTOR=mobile
``` Install the `armeabi-v7a` APK on most TV boxes and sticks,
or `arm64-v8a` on phones and newer devices. Release builds are signed with `android/key.properties`
(or the `CAT_KEYSTORE_*` environment variables in CI) and fall back to the debug key without one.

## Architecture

```
lib/
  core/        models, settings, HTTP, logging, disk image cache
  core/db/     SQLite schema + DB worker isolate (all UI queries run off the UI thread)
  parsers/     streaming M3U parser, byte-level XMLTV scanner, Xtream API client
  import/      import isolate (playlists) + parallel EPG pipeline, import queue
  data/        Repository: every SQL query
  player/      AppPlayer (libmpv engine, reconnect, zapping, resume) + player UI
  features/    home, live, guide, movies/series, search, playlists, settings
```

### Built for huge playlists

Dart runs UI code on one thread, so nothing heavy happens there:

| Work | Where | How |
|---|---|---|
| Video decoding | libmpv native threads | GPU hardware decoding |
| SQL queries | DB worker isolate | WAL mode; the UI never blocks |
| M3U / Xtream import | Import isolate | Streaming parse, one transaction, FTS rebuild |
| XMLTV import | 2 isolates in parallel | Byte-level scanner → batched rows → SQLite writer |
| Lists (100k rows) | UI | Virtual scrolling, 100-row pages loaded on demand |

The TV guide lives in its own SQLite file per playlist (`epg_<source>_g<gen>.db`), written
without journaling, indexed in one sorted pass, then swapped in atomically. The main
database is never locked during a guide import, and an old guide is dropped by deleting a file.

Benchmark (AOT, this machine), from `tool/bench.dart`:

| Test | Result |
|---|---|
| Import M3U, 100,000 channels | 3.7 s, ~95 MB RAM |
| Import XMLTV, 507 MB / 1.65 M programmes | 16 s, ~230 MB RAM |
| Full-text search over 100k | ~3 ms |
| Category page (100 rows) | ~1 ms |
| Guide grid, 30 channels × 24 h | ~9 ms |

Run it yourself (JIT numbers are slower than the shipped AOT build):

```bash
dart run tool/bench.dart 100000 500
```

## Data locations

- Database, guides, logs: `%APPDATA%\IPTV Player\IPTV Player\` (`iptv.db`, `epg\`, `logs\app.log`)
- Logo/poster cache: `%LOCALAPPDATA%\IPTV Player\IPTV Player\images\`
- Xtream passwords: Windows Credential Manager (never written to the database)

## Tests

```bash
flutter test
```
