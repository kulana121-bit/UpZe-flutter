// Port of data/HomeFeed.kt (UpZe v1.0.1, com.ravi.musicspot.data) —
// reduced to what this Flutter port can actually gather.
//
// The Kotlin feed is built from the YT Music home browse (shelves, moods,
// continuation), YT charts / new-releases browses and the JioSaavn launch
// payload. NONE of those browse endpoints are ported in lib/yt/innertube.dart
// (search + player only — InnertubeParser beyond search was out of scope),
// so this repo gathers through ONE injected fan-out `search` instead and
// the substitution is explicit:
//
//  * Regional shelves — EXACTLY the Kotlin's: same titles, same queries,
//    same subtitle, deduped by id, capped at 20. (Kotlin tries YT Music
//    search first, JioSaavn as fallback; the injected search already fans
//    out across sources, so one call replaces the two.)
//  * Quick picks — Kotlin takes YT Music's own "Quick picks" shelf, else a
//    mix of the first home shelves + JioSaavn trending. Substitution: a
//    round-robin mix of the regional results (the only "latest hits" data
//    the injected search can reach), capped at 24, titled "Quick picks"
//    with the Kotlin Home screen's subtitle "Start radio from a song".
//  * "For you · based on your artists" — the Kotlin mixes SeedArtists
//    songs in when the user picked artists, and interleaves them into
//    quick picks while total plays < 15 (LITTLE_HISTORY_PLAYS). Here the
//    seed songs arrive through the injected `seedTracks` callback (the
//    caller runs SeedArtists' fetching / mixSeedSongs) and the play total
//    through `totalPlays` (PlayStatsRepo). The seeding maths is ported
//    verbatim (seedQuick / forYouShelf / refreshSeeds).
//  * Not gathered (no browse layer): moods & genres, charts, new
//    releases, JioSaavn launch shelves/playlists, YT continuation paging.
//
// Cache behaviour is the Kotlin's: home-feed.json, shown instantly on the
// next open, refreshed when older than 20 minutes or forced.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/track.dart';

/// The persisted feed (Kotlin: HomeFeed, trimmed to the gathered fields).
class HomeFeedData {
  const HomeFeedData({
    this.atMs = 0,
    this.quickPicks = const [],
    this.forYou,
    this.regional = const [],
    this.seededQuickIds = const [],
    this.errors = const [],
  });

  final int atMs;
  final List<Track> quickPicks;

  /// The "For you · based on your artists" shelf, when seed songs exist.
  final Shelf? forYou;
  final List<Shelf> regional;

  /// Ids inside [quickPicks] that came from seeds (stripped again before
  /// re-seeding, exactly like the Kotlin).
  final List<String> seededQuickIds;
  final List<String> errors;

  bool get isEmpty =>
      forYou == null && regional.isEmpty && quickPicks.isEmpty;

  HomeFeedData copyWith({
    int? atMs,
    List<Track>? quickPicks,
    Shelf? forYou,
    List<Shelf>? regional,
    List<String>? seededQuickIds,
    List<String>? errors,
  }) =>
      HomeFeedData(
        atMs: atMs ?? this.atMs,
        quickPicks: quickPicks ?? this.quickPicks,
        forYou: forYou ?? this.forYou,
        regional: regional ?? this.regional,
        seededQuickIds: seededQuickIds ?? this.seededQuickIds,
        errors: errors ?? this.errors,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'atMs': atMs,
        'quickPicks': quickPicks.map((t) => t.toJson()).toList(),
        'forYou': forYou?.toJson(),
        'regional': regional.map((s) => s.toJson()).toList(),
        'seededQuickIds': seededQuickIds,
        'errors': errors,
      };

  factory HomeFeedData.fromJson(Map<String, dynamic> json) => HomeFeedData(
        atMs: (json['atMs'] as num?)?.toInt() ?? 0,
        quickPicks: ((json['quickPicks'] as List?) ?? const [])
            .map((e) => Track.fromJson(e as Map<String, dynamic>))
            .toList(),
        forYou: json['forYou'] == null
            ? null
            : Shelf.fromJson(json['forYou'] as Map<String, dynamic>),
        regional: ((json['regional'] as List?) ?? const [])
            .map((e) => Shelf.fromJson(e as Map<String, dynamic>))
            .toList(),
        seededQuickIds:
            ((json['seededQuickIds'] as List?) ?? const []).cast<String>(),
        errors: ((json['errors'] as List?) ?? const []).cast<String>(),
      );
}

/// Everything Home shows from the network, gathered in parallel and cached
/// to disk (home-feed.json) so the next open is instant and
/// offline-friendly. (Kotlin: HomeFeedRepo)
class HomeFeedRepo {
  HomeFeedRepo({
    required this.search,
    required this.seedTracks,
    required this.totalPlays,
    required String dirPath,
  }) : _file = File('$dirPath/home-feed.json');

  /// Fan-out search across the enabled sources (SourceManager.searchAll
  /// in the wired app).
  final Future<List<Track>> Function(String query) search;

  /// Songs from the artists picked in the setup picker, already mixed
  /// (SeedArtists.songsFor / mixSeedSongs on the caller side). Empty when
  /// no artists are picked.
  final List<Track> Function() seedTracks;

  /// Total counted plays (PlayStatsRepo) — seed songs are only mixed into
  /// quick picks while this is below [littleHistoryPlays].
  final int Function() totalPlays;

  final File _file;
  final List<void Function()> _listeners = [];

  HomeFeedData? _feed;
  bool _refreshing = false;
  String? _error;
  bool _cacheRead = false;
  Future<List<Shelf>>? _refreshFuture;

  static const String forYouTitle = 'For you · based on your artists';
  static const int littleHistoryPlays = 15;
  static const Duration maxAge = Duration(minutes: 20);

  /// The Kotlin's regional shelves: (shelf title, search query).
  static const List<(String, String)> regionalQueries = [
    ('Hindi hits', 'latest hindi hit songs'),
    ('Punjabi hits', 'latest punjabi hit songs'),
    ('Haryanvi hits', 'latest haryanvi songs'),
  ];

  HomeFeedData? get feed => _feed;
  bool get refreshing => _refreshing;
  String? get error => _error;

  /// The feed as UI shelves: For You first, then Quick picks, then the
  /// regional shelves — empty shelves are dropped.
  List<Shelf> get shelves {
    final f = _feed;
    if (f == null) return const [];
    return [
      if (f.forYou != null) f.forYou!,
      if (f.quickPicks.isNotEmpty)
        Shelf(
          title: 'Quick picks',
          subtitle: 'Start radio from a song',
          tracks: f.quickPicks,
        ),
      ...f.regional.where((s) => s.tracks.isNotEmpty || s.collections.isNotEmpty),
    ];
  }

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Shows the cached feed immediately, then refreshes when it is older
  /// than [maxAge] (20 min, the Kotlin default) or [force] is set.
  /// (Kotlin: HomeFeedRepo.load)
  Future<List<Shelf>> load({
    bool force = false,
    Duration maxAge = HomeFeedRepo.maxAge,
  }) async {
    if (!_cacheRead) {
      _cacheRead = true;
      try {
        if (await _file.exists()) {
          final decoded = jsonDecode(await _file.readAsString());
          if (decoded is Map<String, dynamic> && _feed == null) {
            _feed = HomeFeedData.fromJson(decoded);
            _notify();
          }
        }
      } catch (_) {}
    }
    final cur = _feed;
    if (!force &&
        cur != null &&
        DateTime.now().millisecondsSinceEpoch - cur.atMs <
            maxAge.inMilliseconds) {
      return shelves;
    }
    return refresh();
  }

  /// Re-gathers the feed; a failed/empty gather keeps the previous feed
  /// (and its cache) untouched, like the Kotlin. Concurrent calls share
  /// one gather (the Kotlin's Mutex).
  Future<List<Shelf>> refresh() {
    return _refreshFuture ??= _doRefresh().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<List<Shelf>> _doRefresh() async {
    _refreshing = true;
    _notify();
    try {
      final fresh = await _gather();
      if (!fresh.isEmpty || _feed == null) {
        _feed = fresh;
        await _writeCache(fresh);
      }
      _error = fresh.isEmpty
          ? (fresh.errors.firstOrNull ?? 'Nothing came back from your sources')
          : null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _refreshing = false;
      _notify();
    }
    return shelves;
  }

  /// Recompute only the seed shelf (and seeded quick picks) after the
  /// artist selection changes. (Kotlin: HomeFeedRepo.refreshSeeds)
  Future<void> refreshSeeds() async {
    // Before the cache is read, load() will run a full gather that
    // already includes seeds.
    if (!_cacheRead) return;
    final cur = _feed;
    if (cur == null) return;
    final seeds = seedTracks();
    if (seeds.isEmpty && cur.forYou == null && cur.seededQuickIds.isEmpty) {
      return;
    }
    // Nothing picked any more → drop the shelf and un-seed quick picks;
    // picked but no songs (offline/failed) → keep what Home shows.
    if (seeds.isEmpty) {
      final removed = cur.seededQuickIds.toSet();
      final base =
          cur.quickPicks.where((t) => !removed.contains(t.id)).toList();
      // Rebuilt directly: copyWith can't clear forYou back to null.
      _feed = HomeFeedData(
        atMs: cur.atMs,
        quickPicks: base,
        regional: cur.regional,
        seededQuickIds: const [],
        errors: cur.errors,
      );
      await _writeCache(_feed!);
      _notify();
      return;
    }
    final removed = cur.seededQuickIds.toSet();
    final base = cur.quickPicks.where((t) => !removed.contains(t.id)).toList();
    final (quick, ids) = seedQuick(base, seeds, littleHistory: _littleHistory);
    _feed = cur.copyWith(
      forYou: _forYouShelf(seeds),
      quickPicks: quick,
      seededQuickIds: ids,
    );
    await _writeCache(_feed!);
    _notify();
  }

  // ---- seeding (Kotlin: seedQuick / forYouShelf / littleHistory) -----------

  bool get _littleHistory => totalPlays() < littleHistoryPlays;

  /// Quick picks with seed songs interleaved when play history is thin;
  /// returns (picks, ids that came from seeds). Ported verbatim.
  static (List<Track>, List<String>) seedQuick(
    List<Track> base,
    List<Track> seedTracks, {
    required bool littleHistory,
  }) {
    if (seedTracks.isEmpty || !littleHistory) return (base, const []);
    final seeds = seedTracks.take(12).toList();
    final out = <Track>[];
    final n = seeds.length > base.length ? seeds.length : base.length;
    for (var i = 0; i < n; i++) {
      if (i < seeds.length) out.add(seeds[i]);
      if (i < base.length) out.add(base[i]);
    }
    final seen = <String>{};
    final picks = out.where((t) => seen.add(t.id)).take(24).toList();
    final seedIds = seeds.map((t) => t.id).toSet();
    final baseIds = base.map((t) => t.id).toSet();
    return (
      picks,
      picks
          .where((t) => seedIds.contains(t.id) && !baseIds.contains(t.id))
          .map((t) => t.id)
          .toList(),
    );
  }

  Shelf? _forYouShelf(List<Track> tracks) => tracks.isEmpty
      ? null
      : Shelf(
          title: forYouTitle,
          subtitle: 'Songs from artists you picked',
          tracks: tracks.take(30).toList(),
        );

  // ---- gather ----------------------------------------------------------------

  Future<T?> _safe<T>(
    String label,
    Future<T> future,
    List<String> errors,
  ) async {
    try {
      return await future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      errors.add('$label timed out');
      return null;
    } catch (e) {
      final msg = e.toString();
      errors.add('$label: ${msg.length > 80 ? msg.substring(0, 80) : msg}');
      return null;
    }
  }

  Future<HomeFeedData> _gather() async {
    final errors = <String>[];

    // Regional shelves, in parallel (Kotlin: async per query).
    final regionalResults = await Future.wait([
      for (final (title, q) in regionalQueries)
        _safe(title, search(q), errors).then((tracks) {
          final list = (tracks ?? const <Track>[])
              .where((t) => t.title.isNotEmpty)
              .toList();
          final seen = <String>{};
          return Shelf(
            title: title,
            subtitle: 'YouTube Music',
            tracks:
                list.where((t) => seen.add(t.id)).take(20).toList(),
          );
        }),
    ]);
    final regional = regionalResults
        .where((s) => s.tracks.isNotEmpty || s.collections.isNotEmpty)
        .toList();

    // Quick-picks base (substitution, see header): round-robin mix of the
    // regional results, deduped, capped at 24 like the Kotlin.
    final base = _roundRobin([for (final s in regional) s.tracks]);

    final seeds = seedTracks();
    final (quick, seededIds) =
        seedQuick(base, seeds, littleHistory: _littleHistory);

    return HomeFeedData(
      atMs: DateTime.now().millisecondsSinceEpoch,
      quickPicks: quick,
      forYou: _forYouShelf(seeds),
      regional: regional,
      seededQuickIds: seededIds,
      errors: errors,
    );
  }

  static List<Track> _roundRobin(List<List<Track>> lists) {
    final out = <Track>[];
    final seen = <String>{};
    var maxLen = 0;
    for (final l in lists) {
      if (l.length > maxLen) maxLen = l.length;
    }
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length && seen.add(l[i].id)) out.add(l[i]);
      }
    }
    return out.take(24).toList();
  }

  Future<void> _writeCache(HomeFeedData data) async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(data.toJson()));
    } catch (_) {}
  }
}
