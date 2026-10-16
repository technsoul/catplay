# CAT

CAT is a fast IPTV player for Windows, Linux, macOS and Android TV, built with Flutter and libmpv.

- **Sources:** Xtream Codes API, M3U/M3U8 (URL or local file), XMLTV guides (`.xml` / `.xml.gz`)
- **Live TV:** categories, channel list with now/next, preview player, channel zapping, auto-reconnect
- **TV guide:** full-day timeline grid, day picker, programme details, catch-up (Xtream `tv_archive`)
- **Movies & series:** poster grids, sorting, details/plot, seasons & episodes, resume where you left off
- **Downloads:** save movies and episodes (or a whole season) to watch offline, with pause/resume
- **Search:** instant full-text search across all playlists (SQLite FTS5, prefix matching)
- **Favorites, continue watching, recent channels**, multiple playlists
- **Playback:** libmpv via `media_kit` — HEVC, AC3/E-AC3, MPEG-TS, HLS, hardware decoding, audio/subtitle tracks

## Run / build

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

### Android TV

```bash
flutter build apk --release --split-per-abi
```

Install `app-armeabi-v7a-release.apk` (most TV boxes and sticks) or `app-arm64-v8a-release.apk`
with `adb install` or a file manager on the TV. Release builds are signed with `android/key.properties`
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
