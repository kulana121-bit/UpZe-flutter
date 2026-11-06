// UpZe (Flutter rewrite) — app entry, fully wired.
//
// All layers joined here: repos + accounts -> SourceManager (settings
// priority, accounts-backed configs) -> PlayerController -> AppShell,
// plus HomeFeed shelves, the first-run SetupScreen gate, the update
// sheet (with the native installer channel), the home-screen widget
// feed, the local-files permission flow and CrashGuard.
//
// See REWRITE_MAP.md for the full ported-vs-remaining map.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/crash_guard.dart';
import 'data/accounts_store.dart';
import 'data/downloads.dart';
import 'data/home_feed.dart';
import 'data/library.dart';
import 'data/play_stats.dart';
import 'data/seed_artists.dart';
import 'data/settings_store.dart';
import 'dsp/eq_controller.dart';
import 'lyrics/lyrics_repository.dart';
import 'lyrics/romanizer.dart';
import 'models/track.dart';
import 'playback/audio_handler.dart';
import 'playback/player_controller.dart';
import 'sources/jiosaavn_source.dart';
import 'sources/local_source.dart';
import 'sources/music_source.dart';
import 'sources/open_sources.dart';
import 'sources/servers_source.dart';
import 'sources/source_manager.dart';
import 'sources/spotify_source.dart';
import 'sources/youtube_source.dart';
import 'ui/app_shell.dart';
import 'ui/screens/accounts_screen.dart';
import 'ui/screens/downloads_screen.dart';
import 'ui/screens/eq_screen.dart';
import 'ui/screens/setup_screen.dart';
import 'ui/theme.dart';
import 'ui/update_sheet.dart';
import 'update/updater.dart';
import 'yt/innertube_pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initBackgroundAudio();
  runApp(const UpZeApp());
}

const _installerChannel = MethodChannel('upze/installer');

/// Everything the app needs, created once at boot.
class AppCore {
  AppCore._(
      this.dir,
      this.settings,
      this.library,
      this.stats,
      this.downloads,
      this.accounts,
      this.manager,
      this.player,
      this.lyrics,
      this.updater,
      this.eqA,
      this.eqB,
      this.homeFeed,
      this.pages,
      this.localSource,
      this.startCheck);

  final String dir;
  final SettingsStore settings;
  final LibraryRepo library;
  final PlayStatsRepo stats;
  final DownloadsRepo downloads;
  final AccountsStore accounts;
  final SourceManager manager;
  final PlayerController player;
  final LyricsRepository lyrics;
  final Updater updater;
  final EqController eqA;
  final EqController eqB;
  final HomeFeedRepo homeFeed;
  final InnertubePages pages;
  final LocalSource localSource;

  /// The gated start-of-day update check started at boot.
  final Future<UpdateCheckOutcome?> startCheck;

  bool _localPermission = false;
  List<Track> _seedTracks = const [];

  List<Track> get seedTracks => _seedTracks;

  /// Push the current EQ setting into both players' system equalizers.
  /// Approximation bridge — see lib/dsp/eq_controller.dart header.
  Future<void> applyEq() async {
    try {
      await eqA.apply(settings.value.eq);
    } catch (_) {}
    try {
      await eqB.apply(settings.value.eq);
    } catch (_) {}
  }

  /// Ask for the media permission and scan the device library once
  /// granted (LocalSource itself stays permission-agnostic).
  Future<void> enableLocal() async {
    try {
      var status = await Permission.audio.request();
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      _localPermission = status.isGranted;
      if (_localPermission) {
        await localSource.scan();
      }
    } catch (_) {
      // Plugin unavailable (tests/desktop) — local stays off.
    }
  }

  /// Fetch seed artists' songs for the HomeFeed "For you" shelf.
  Future<void> refreshSeedTracks() async {
    final names = accounts.seedArtistIds;
    if (names.isEmpty) {
      _seedTracks = const [];
      return;
    }
    final yt = manager.source(SourceKind.youtube);
    if (yt == null) return;
    final perArtist = <List<Track>>[];
    for (final name in names) {
      try {
        perArtist.add(await yt.search(name, 12));
      } catch (_) {
        perArtist.add(const []);
      }
    }
    _seedTracks = mixSeedSongs(perArtist);
    unawaited(homeFeed.refreshSeeds());
  }

  static Future<AppCore> boot() async {
    final dir = (await getApplicationSupportDirectory()).path;
    CrashGuard.install(dir);
    final settings = SettingsStore(dir);
    final library = LibraryRepo(dir);
    final stats = PlayStatsRepo(dir);
    final queueStore = QueueStore(dir);
    final downloads = DownloadsRepo(dir);
    final accounts = AccountsStore(dir);
    await settings.load();
    await library.load();
    await stats.load();
    await downloads.load();
    await accounts.load();

    bool kindOn(SourceKind k) =>
        settings.value.enabledSources.contains(k) ||
        settings.value.enabledSources.isEmpty;
    late AppCore core;
    final ytSource = YouTubeSource(enabled: () => kindOn(SourceKind.youtube));
    final localSource = LocalSource(
      enabled: () => kindOn(SourceKind.local),
      hasPermission: () => core._localPermission,
    );
    final sources = <SourceKind, MusicSource>{
      SourceKind.youtube: ytSource,
      SourceKind.jiosaavn:
          JioSaavnSource(enabled: () => kindOn(SourceKind.jiosaavn)),
      SourceKind.audius: AudiusSource(enabled: () => kindOn(SourceKind.audius)),
      SourceKind.jamendo: JamendoSource(
        clientId: () =>
            accounts.jamendoClientId ?? settings.value.jamendoClientId,
        enabled: () => kindOn(SourceKind.jamendo),
      ),
      SourceKind.archive:
          ArchiveSource(enabled: () => kindOn(SourceKind.archive)),
      SourceKind.subsonic: SubsonicSource(
        config: () => accounts.subsonic,
        enabled: () => kindOn(SourceKind.subsonic),
      ),
      SourceKind.jellyfin: JellyfinSource(
        config: () => accounts.jellyfin,
        enabled: () => kindOn(SourceKind.jellyfin),
      ),
      SourceKind.spotify: SpotifySource(
        cookie: () => accounts.spotifyCookie,
        enabled: () => kindOn(SourceKind.spotify),
      ),
      SourceKind.local: localSource,
    };
    final manager = SourceManager(
      sources: sources,
      priority: () => settings.value.sourcePriority,
      enabled: () => sources.keys.where(kindOn).toSet(),
      premium: () => false,
      downloaded: downloads.downloaded,
    );
    final eqA = EqController();
    final eqB = EqController();
    final player = PlayerController(
      manager: manager,
      settings: () => settings.value,
      library: library,
      playStats: stats,
      queueStore: queueStore,
      player:
          AudioPlayer(audioPipeline: eqA.buildPipeline(settings.value.eq)),
      fadePlayer:
          AudioPlayer(audioPipeline: eqB.buildPipeline(settings.value.eq)),
    );
    final savedQueue = await queueStore.read();
    if (savedQueue != null) {
      unawaited(player.restoreSnapshot(savedQueue));
    }
    final updater = Updater(
      skippedUpdateProvider: () => settings.value.skippedUpdate,
      cacheFile: File('$dir/update-check.json'),
    );
    final startCheck = () async {
      try {
        if (await updater.isStartCheckDue(
            autoUpdateCheckEnabled: settings.value.autoUpdateCheck)) {
          return await updater.check();
        }
      } catch (_) {}
      return null;
    }();
    final homeFeed = HomeFeedRepo(
      search: (q) async {
        try {
          return await ytSource.search(q, 20);
        } catch (_) {
          return const [];
        }
      },
      seedTracks: () => core._seedTracks,
      totalPlays: () =>
          stats.stats.values.fold(0, (sum, s) => sum + s.plays),
      dirPath: dir,
    );
    core = AppCore._(
      dir,
      settings,
      library,
      stats,
      downloads,
      accounts,
      manager,
      player,
      LyricsRepository(),
      updater,
      eqA,
      eqB,
      homeFeed,
      InnertubePages(ytSource.music.tube),
      localSource,
      startCheck,
    );
    unawaited(homeFeed.load());
    unawaited(core.refreshSeedTracks());
    accounts.addListener(() => unawaited(core.refreshSeedTracks()));
    return core;
  }

  /// Fan-out search across all registered sources (one failing source
  /// never sinks the search — same rule as the Kotlin app).
  Future<List<Track>> searchAll(String query) async {
    final found = <Track>[];
    final seen = <String>{};
    await Future.wait(manager.sources.values.map((s) async {
      if (!s.available()) return;
      try {
        for (final t in await s.search(query)) {
          if (seen.add('${t.source}:${t.title}:${t.artist}')) found.add(t);
        }
      } catch (_) {}
    }));
    return found;
  }
}

class UpZeApp extends StatefulWidget {
  const UpZeApp({super.key});

  @override
  State<UpZeApp> createState() => _UpZeAppState();
}

class _UpZeAppState extends State<UpZeApp> {
  final Future<AppCore> _boot = AppCore.boot();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppCore>(
      future: _boot,
      builder: (context, snap) {
        if (snap.hasError) {
          return MaterialApp(
            home: Scaffold(
              body: Center(child: Text('UpZe failed to start: ${snap.error}')),
            ),
          );
        }
        final core = snap.data;
        if (core == null) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        return _WiredApp(core: core);
      },
    );
  }
}

/// Bridges PlayerController (ChangeNotifier) to AppShell (streams) and
/// hosts the setup gate, the update sheet and all sub-page navigation.
class _WiredApp extends StatefulWidget {
  const _WiredApp({required this.core});

  final AppCore core;

  @override
  State<_WiredApp> createState() => _WiredAppState();
}

class _WiredAppState extends State<_WiredApp> {
  final _navKey = GlobalKey<NavigatorState>();
  final _trackOut = StreamController<Track?>.broadcast();
  final _indexOut = StreamController<int?>.broadcast();
  final _queueOut = StreamController<List<Track>>.broadcast();
  final _infoOut = StreamController<StreamInfo?>.broadcast();
  bool _updateSheetShown = false;

  AppCore get core => widget.core;
  PlayerController get player => core.player;
  NavigatorState? get _nav => _navKey.currentState;

  @override
  void initState() {
    super.initState();
    player.addListener(_push);
    core.library.addListener(_onChange);
    core.settings.addListener(_onChange);
    core.accounts.addListener(_onChange);
    core.homeFeed.addListener(_onChange);
    _push();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(core.enableLocal());
      unawaited(_maybeShowUpdate());
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _maybeShowUpdate() async {
    if (_updateSheetShown) return;
    final outcome = await core.startCheck;
    if (outcome == null || !mounted) return;
    if (outcome.status != UpdateCheckStatus.update || outcome.info == null) {
      return;
    }
    final info = outcome.info!;
    if (!core.updater.shouldPrompt(info)) return;
    _updateSheetShown = true;
    final ctx = _nav?.context;
    if (ctx == null || !ctx.mounted) return;
    await showUpdateSheet(
      ctx,
      info: info,
      onDownload: (onProgress) async {
        final dlDir = Directory('${core.dir}/updates');
        return core.updater.downloadApk(info, dlDir,
            onProgress: (done, total) =>
                onProgress(total > 0 ? done / total : 0));
      },
      onSkip: () => core.settings.update(
          (s) => s.copyWith(skippedUpdate: info.version)),
      onLater: () => core.updater.later(),
      onInstall: (apk) => unawaited(_install(apk)),
    );
  }

  Future<void> _install(File apk) async {
    try {
      final can =
          await _installerChannel.invokeMethod<bool>('canInstall') ?? false;
      if (!can) {
        await _installerChannel.invokeMethod<bool>('openInstallSettings');
        return;
      }
      await _installerChannel.invokeMethod<bool>(
          'installApk', apk.absolute.path);
    } catch (_) {
      // Channel missing (non-Android) — nothing to do.
    }
  }

  String? _lastTrackId;
  int? _lastIndex;
  int _lastQueueLen = -1;
  String? _lastInfoLabel;

  void _push() {
    final t = player.currentTrack;
    if (t?.id != _lastTrackId) {
      _lastTrackId = t?.id;
      _trackOut.add(t);
      unawaited(core.applyEq());
      if (t != null) unawaited(_updateWidget(t));
    }
    if (player.currentIndex != _lastIndex) {
      _lastIndex = player.currentIndex;
      _indexOut.add(player.currentIndex);
    }
    if (player.queue.length != _lastQueueLen) {
      _lastQueueLen = player.queue.length;
      _queueOut.add(List.of(player.queue));
    }
    final label = player.currentStreamInfo?.label;
    if (label != _lastInfoLabel) {
      _lastInfoLabel = label;
      _infoOut.add(player.currentStreamInfo);
    }
  }

  Future<void> _updateWidget(Track t) async {
    try {
      await HomeWidget.saveWidgetData<String>('title', t.title);
      await HomeWidget.saveWidgetData<String>('artist', t.artist);
      await HomeWidget.updateWidget(
        name: 'NowPlayingWidget',
        androidName: 'NowPlayingWidget',
        qualifiedAndroidName: 'com.ravi.musicspot.NowPlayingWidget',
      );
    } catch (_) {
      // home_widget unavailable (tests/desktop) — ignore.
    }
  }

  @override
  void dispose() {
    player.removeListener(_push);
    _trackOut.close();
    _indexOut.close();
    _queueOut.close();
    _infoOut.close();
    super.dispose();
  }

  List<Shelf> get _homeShelves {
    final lib = core.library;
    return [
      ...core.homeFeed.shelves,
      if (lib.recentlyPlayed.isNotEmpty)
        Shelf(title: 'Recently played', tracks: lib.recentlyPlayed),
      if (lib.liked.isNotEmpty) Shelf(title: 'Liked songs', tracks: lib.liked),
    ];
  }

  void _toast(String msg) {
    final ctx = _nav?.context;
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openAccounts() {
    _nav?.push(MaterialPageRoute<void>(
      builder: (_) => AccountsScreen(
        accounts: core.accounts,
        testSubsonic: () async {
          try {
            await SubsonicSource(
              config: () => core.accounts.subsonic,
              enabled: () => true,
            ).probe();
            return true;
          } catch (_) {
            return false;
          }
        },
        testJellyfin: () async {
          try {
            await JellyfinSource(
              config: () => core.accounts.jellyfin,
              enabled: () => true,
            ).probe();
            return true;
          } catch (_) {
            return false;
          }
        },
        jellyfinLogin: (server, user, password) async {
          final login = await JellyfinSource(
            config: () => null,
            enabled: () => true,
          ).login(server, user, password);
          return JellyfinConfig(
            baseUrl: server,
            userId: login.userId,
            accessToken: login.accessToken,
          );
        },
      ),
    ));
  }

  void _openEq() {
    _nav?.push(MaterialPageRoute<void>(
      builder: (_) => EqScreen(
        settings: core.settings,
        onEqChanged: () => unawaited(core.applyEq()),
      ),
    ));
  }

  void _openDownloads() {
    _nav?.push(MaterialPageRoute<void>(
      builder: (_) => DownloadsScreen(
        repo: core.downloads,
        onPlay: (t) async => player.playTrack([t], 0),
        resolveFor: (t) =>
            core.manager.resolve(t, core.settings.value.downloadQuality, false),
      ),
    ));
  }

  Future<void> _downloadTrack(Track t) async {
    _toast('Downloading ${t.title}…');
    try {
      final entry = await core.downloads.download(
        t,
        (track) => core.manager
            .resolve(track, core.settings.value.downloadQuality, false),
      );
      _toast(entry.state == DownloadState.done
          ? 'Downloaded: ${t.title}'
          : 'Download failed: ${t.title}');
    } catch (_) {
      _toast('Download failed: ${t.title}');
    }
  }

  void _showLyrics(BuildContext context, Track track) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        builder: (context, scroll) => FutureBuilder<LyricsResult?>(
          future: core.lyrics.lyricsForQuery(LyricsQuery.forTrack(track)),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final r = snap.data;
            if (r == null) {
              return const Center(child: Text('No lyrics found.'));
            }
            final lines = switch (r) {
              SyncedLyrics s => [for (final l in s.lines) l.text],
              PlainLyrics p => p.text.split('\n'),
            };
            return FutureBuilder<List<String?>>(
              future: Romanizer.lines(lines),
              builder: (context, roman) {
                final romanized = roman.data ?? const <String?>[];
                return ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(20),
                  itemCount: lines.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                            '${track.title} — lyrics (${r.source})',
                            style:
                                Theme.of(context).textTheme.titleMedium),
                      );
                    }
                    final idx = i - 1;
                    final sub = idx < romanized.length ? romanized[idx] : null;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(lines[idx]),
                        if (sub != null && sub != lines[idx])
                          Text(sub,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontStyle: FontStyle.italic)),
                      ],
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UpZe',
      navigatorKey: _navKey,
      theme: buildUpZeTheme(core.settings.value),
      home: !core.accounts.setupDone
          ? SetupScreen(
              accounts: core.accounts,
              onDone: _onChange,
            )
          : AppShell(
              settings: core.settings,
              library: core.library,
              currentTrackStream: _trackOut.stream,
              streamInfoStream: _infoOut.stream,
              positionStream: player.positionStream,
              durationStream: player.durationStream,
              playingStream: player.playingStream,
              queueStream: _queueOut.stream,
              currentIndexStream: _indexOut.stream,
              onTogglePlay: player.toggle,
              onNext: player.next,
              onPrev: player.previous,
              onSeek: player.seek,
              onJumpTo: player.skipTo,
              onToggleLike: (t) => player.toggleLike(t),
              onSearch: core.searchAll,
              onPlay: (track, queue) {
                final q = queue.isEmpty ? [track] : queue;
                player.playTrack(q, q.indexOf(track).clamp(0, q.length - 1));
              },
              homeShelves: _homeShelves,
              onRefreshHome: () => core.homeFeed.refresh(),
              onLoadCharts: () async {
                try {
                  final shelves = await core.pages.homeShelves();
                  if (shelves.isNotEmpty) return shelves;
                } catch (_) {}
                final tube = await core.manager
                        .source(SourceKind.youtube)
                        ?.search('top songs', 20) ??
                    const <Track>[];
                return [Shelf(title: 'Trending search — YouTube', tracks: tube)];
              },
              onLoadSourceSuggestions: (kind) async {
                final s = core.manager.source(kind);
                if (s == null || !s.available()) return const [];
                try {
                  return await s.search('new music', 15);
                } catch (_) {
                  return const [];
                }
              },
              onOpenCollection: (collection) {
                unawaited(() async {
                  try {
                    final page =
                        await core.pages.playlistPage(collection.id);
                    if (page.tracks.isNotEmpty) {
                      player.playTrack(page.tracks, 0);
                    }
                  } catch (_) {}
                }());
              },
              onShowLyrics: (t) => _showLyrics(context, t),
              onSleepTimer: (minutes) {
                if (minutes <= 0) {
                  player.cancelSleepTimer();
                } else {
                  player.startSleepTimer(minutes);
                }
              },
              onOpenAccounts: _openAccounts,
              onOpenEq: _openEq,
              onOpenDownloads: _openDownloads,
              onDownloadTrack: (t) => unawaited(_downloadTrack(t)),
              userName: 'Ravi',
            ),
    );
  }
}
