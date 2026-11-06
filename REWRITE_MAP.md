# UpZe — Kotlin → Flutter Rewrite Map

Original: UpZe v1.0.1, 120 Kotlin files, 26,702 lines, package `com.ravi.musicspot`
Target: Flutter/Dart, same applicationId `com.ravi.musicspot`, version 1.0.1+22

## Architecture mapping
| Kotlin (original) | Flutter (rewrite) |
|---|---|
| model/Track.kt (Track, SourceKind, Quality) | lib/models/track.dart |
| data/Library.kt, Settings.kt, PlayStats.kt, Downloads.kt | lib/data/ |
| source/MusicSource.kt + SourceManager.kt + Routing.kt | lib/sources/music_source.dart + source_manager.dart |
| source/JioSaavn.kt | lib/sources/jiosaavn_source.dart |
| source/OpenSources.kt (Audius/Jamendo/Archive) | lib/sources/open_sources.dart |
| source/LocalSource.kt | lib/sources/local_source.dart (Phase 2, on_audio_query) |
| source/Servers.kt (Subsonic/Jellyfin) | lib/sources/server_sources.dart (Phase 2) |
| yt/Innertube.kt + YtMusic.kt | lib/yt/innertube.dart (direct Innertube API only — NewPipeExtractor is Java, cannot port) |
| lyrics/* | lib/lyrics/ |
| playback/PlaybackService.kt (Media3) | just_audio + just_audio_background (Phase 2) |
| dsp/* (10-band + parametric EQ, AutoEq) | Phase 3 — needs native/platform EQ; just_audio has no 10-band EQ |
| ui/* (Compose screens, glass/motion) | lib/ui/ (Phase 2) |
| spotify/* (WebView login, partner API) | Phase 3 — metadata/sync only |
| update/* (GitHub releases updater) | Phase 2 |

## Known hard limits (honest)
- NewPipeExtractor (Java) has no Dart port → YouTube uses direct Innertube API path only.
- Media3 two-player crossfade + 10-band DSP chain has no direct Flutter equivalent → approximated in Phase 2/3, not 1:1.
- Android applicationId stays com.ravi.musicspot; signing keystore is Ravi's own (never in this repo).

## Phase 1 verification (2026-11-06)
- Flutter 3.35.1 / Dart 3.9.0 SDK installed on the VM; `flutter create`
  scaffold added (android/ios), applicationId corrected to
  com.ravi.musicspot, app label "UpZe".
- `flutter pub get` — OK (91 dependencies resolved).
- `flutter analyze` — **No issues found** (2 seam errors fixed:
  LrcLib `isNotEmpty` property, private `CacheHit` type made public).
- `flutter test` — widget smoke test passed (app boots to search home).
- YouTube wired into the source registry via a new adapter,
  lib/sources/youtube_source.dart (YtMusic -> MusicSource).
- lib/main.dart is a runnable skeleton: live search across
  JioSaavn/YouTube/Audius/Jamendo/Archive, tap -> SourceManager.resolve
  -> just_audio playback with the resolved quality label shown.
- NOT done: APK build (local Gradle is blocked on this VM — build via
  GitHub Actions / a machine with Android SDK), Phase 2 UI + full
  player, Phase 3 DSP/EQ.

## Phase 2 verification (2026-11-06)
- Playback: lib/playback/player_controller.dart (1,112 lines — queue,
  lazy resolve + recovery, two-player equal-power crossfade, full sleep
  timer, play counting, queue persistence) + audio_handler.dart
  (just_audio_background; manifest service/receiver/permissions added).
- UI: lib/ui/ 9 files, 3,056 lines — glass theme, Home/Search/Library/
  Explore/Settings, full + mini player, AppShell with floating dock.
- main.dart now wires everything: repos -> SourceManager (settings
  priority) -> PlayerController -> AppShell stream adapters; lyrics
  sheet via the ported 5-provider chain; queue restored on boot.
- `flutter analyze` — No issues found. `flutter test` — boot test
  renders the real AppShell and passes; the test caught a REAL
  paint-time bug (per-side border colours + borderRadius assert in
  GlassContainer) which is fixed.
- Still NOT done: APK build (VM Gradle block — use GitHub Actions),
  Phase 3 (DSP/EQ, downloads, Subsonic/Jellyfin, Spotify metadata,
  local files source, in-app updater, home widget).

## Phase 3 + FINAL (2026-11-06) — rewrite complete
- Sources: servers_source.dart (Subsonic salt/token auth, Jellyfin
  token login, lossless raw/static streams), spotify_source.dart
  (FULL Spotify port — sp_dc cookie + web-player TOTP/Pathfinder
  scheme from the Kotlin; metadata/ISRC + library import; resolve()
  throws like the original — Spotify never streams), local_source.dart
  (on_audio_query device songs).
- Downloads: data/downloads.dart (chunked 1 MiB ranged downloads with
  resume, index, offline playback — SourceManager.downloaded is now
  wired to it in main.dart).
- EQ: dsp/eq_controller.dart — APPROXIMATION ONLY: EqSetting curve
  mapped onto Android's system equalizer bands + loudness preamp.
  The Kotlin parametric DSP chain, dynamic processing and upscaler
  have no Flutter equivalent and are NOT ported.
- AutoEq: data/auto_eq.dart (9 built-in presets + remote AutoEq
  index fetch/parse, as the Kotlin does).
- Updater: update/updater.dart (GitHub Releases check with the
  Kotlin's exact rules, skip-version, 12 h gate, verified APK
  download). APK INSTALL stays Android-native (intent + FileProvider)
  — documented, not faked. Wired in main.dart as a start check.
- Wiring honesty: Subsonic/Jellyfin/Spotify/Local are registered in
  the SourceManager but their config callbacks return null/false —
  the Kotlin keeps those accounts in a separate encrypted
  AccountStore that has no Flutter port yet, and local files need
  the media-permission flow. They activate when an accounts store
  lands; everything else is live.
- FINAL VERIFICATION: `flutter analyze` — No issues found.
  `flutter test` — boot test renders the full AppShell, passes.
  Total: 14,903 lines of Dart in lib/ (original: 26,702 lines Kotlin).
- Remaining outside this rewrite: APK build via GitHub Actions
  (VM Gradle block), accounts store + its settings UI, APK install
  intent, home-screen widget, Media3 cache layer.
- Post-delivery (2026-11-06, local only, not pushed): a ready-made
  Actions workflow now sits at `.github/workflows/flutter-apk.yml` —
  debug APK build (no keystore/secrets needed), analyze + test first,
  artifact upload. Still needs Ravi's say-so to push + run.

## Missing-parts build (2026-11-06, Ravi's order "jo nhi bana usko bana")
- Accounts: data/accounts_store.dart (plain JSON in the app-private
  dir — the Kotlin's Keystore encryption is NOT faked) +
  ui/screens/accounts_screen.dart (Subsonic/Jellyfin/Spotify cookie/
  Jamendo forms with live test + Jellyfin login). All source config
  callbacks in main.dart now read the store — the four sources are
  LIVE once the user fills them in.
- Setup: ui/screens/setup_screen.dart gates the first run (seed
  artist pick or skip) + data/seed_artists.dart (12 baked-in popular
  queries — the Kotlin has no static artist catalogue) + HomeFeed
  (data/home_feed.dart) shelves merged into Home.
- Downloads: full-player download button -> DownloadsRepo.download;
  ui/screens/downloads_screen.dart manages/retry-plays them.
- EQ: ui/screens/eq_screen.dart (10-band sliders, preamp, presets,
  parametric toggles) -> applyEq() on both players.
- Styles: player classic/aura/vinyl-deck/minimal-poster, home
  classic/aura/bento/spotlight, dock classic/island/capsule/edge —
  all switch from the existing settings.
- YouTube pages: yt/innertube_pages.dart (home shelves, artist,
  playlist, real watch-queue radio); collections now play.
- Romanizer: lyrics/romanizer.dart + Android ICU bridge
  (RomanizerBridge.kt) behind the 'upze/romanizer' channel; lyrics
  sheet shows romanized lines under the originals.
- Updater: update sheet wired at boot (download with progress ->
  'upze/installer' channel: canInstall/openInstallSettings/
  installApk via FileProvider, authority ${applicationId}.updates).
- Widget: NowPlayingWidget (text-only; transport buttons still need
  an audio-service bridge) fed from main on every track change.
- Local files: permission flow (Permission.audio -> storage
  fallback) + scan at boot.
- CrashGuard installed at boot (crash-log.txt, last 50).
- CI: .github/workflows/flutter-build.yml (analyze/test/debug+release
  APK artifacts; release is debug-signed until keystore secrets are
  added). Kotlin side is NOT compile-verified on this VM — the first
  CI run is its real test.
- FINAL: flutter analyze clean, flutter test passes, 20,513 lines
  of Dart in lib/.
- Still impossible in Flutter (unchanged): full parametric DSP
  chain + upscaler (system-EQ approximation only), NewPipeExtractor
  signature deciphering, Media3-style chunked stream cache.
