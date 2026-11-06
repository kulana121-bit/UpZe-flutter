// Port of source/SourceManager.kt + source/Routing.kt (UpZe v1.0.1).
//
// Routing.kt  -> TrackMatcher (same-recording matching), QualityEstimate,
//                SourceRouter (pure plan / sources-to-search decisions).
// SourceManager.kt -> SourceManager: downloads first, then the ordered plan
//                with failover, a YouTube-vs-fallback race, and per-step
//                time budgets.
//
// Dart notes vs the Kotlin coroutines original:
//  * `withTimeoutOrNull` becomes [_timeoutOrNull]; a timed-out future keeps
//    running in the background (Dart futures are not cancellable), it is
//    simply no longer awaited — the observable behaviour (budgets, failover
//    order, results) is the same.
//  * PlaybackLog is replaced by the [logSource] sink in music_source.dart.

import 'dart:async';
import 'dart:math' as math;

import '../models/track.dart';
import 'music_source.dart';

Future<T?> _timeoutOrNull<T>(Future<T> future, Duration budget) async {
  try {
    return await future.timeout(budget);
  } on TimeoutException {
    return null;
  }
}

/// Stable sort (Kotlin's sortedWith is stable; Dart's List.sort is not).
List<T> _stableSorted<T>(List<T> items, int Function(T a, T b) compare) {
  final decorated = <(int, T)>[
    for (var i = 0; i < items.length; i++) (i, items[i]),
  ];
  decorated.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final d in decorated) d.$2];
}

// ---------------------------------------------------------------------------
// TrackMatcher (Routing.kt)
// ---------------------------------------------------------------------------

/// Pure matching of the same recording across sources (Spotify import,
/// cross-source upgrades, failover).
abstract final class TrackMatcher {
  static final RegExp _brackets = RegExp(r'\s*[(\[][^)\]]*[)\]]');
  static final RegExp _feat =
      RegExp(r'\s+(?:feat\.?|ft\.?|featuring|with)\s.*$', caseSensitive: false);
  static final RegExp _dashNote = RegExp(
      r'\s+[-–—]\s+.*(?:remaster|version|edit|mix|live|mono|stereo).*$',
      caseSensitive: false);
  static final RegExp _version = RegExp(
      r'\b(remix|live|instrumental|karaoke|acoustic|cover|sped up|slowed|reverb|8d|nightcore|lofi|lo-fi)\b',
      caseSensitive: false);

  /// YouTube title junk: "| Artist | Label", "Official Video", "Lyrical",
  /// "Full Song", "HD", "4K"…
  static final RegExp _pipeTail = RegExp(r'\s*[|｜•].*$');
  static final RegExp _junk = RegExp(
      r'\b(official\s+(music\s+)?(video|audio|song|lyric(al)?\s*video)|lyrical(\s+video)?|lyrics?(\s+video)?|full\s+(video\s+)?song|video\s+song|audio\s+song|new\s+\w+\s+song|hd|4k|1080p|720p|mv|m\/v|visualizer)\b',
      caseSensitive: false);
  static final RegExp _channelJunk = RegExp(
      r'\s*(-\s*topic|vevo|official|music|records|films|entertainment|channel)\s*$',
      caseSensitive: false);

  /// Precomposed Latin letter -> base letter (the NFD + strip-combining-marks
  /// step of the Kotlin original, for Latin only: Indic vowel signs are
  /// combining marks too and must stay).
  static final Map<int, String> _latinBase = _buildLatinBase();

  static Map<int, String> _buildLatinBase() {
    const groups = <String, String>{
      'a': 'àáâãäåāăąǎȁȃạảấầẩẫậắằẳẵặæ',
      'c': 'çćĉċč',
      'd': 'ďđð',
      'e': 'èéêëēĕėęěȅȇẹẻẽếềểễệ',
      'g': 'ĝğġģ',
      'h': 'ĥħ',
      'i': 'ìíîïĩīĭįıǐȉȋịỉ',
      'j': 'ĵ',
      'k': 'ķ',
      'l': 'ĺļľŀł',
      'n': 'ñńņňŉŋ',
      'o': 'òóôõöøōŏőǒȍȏọỏốồổỗộớờởỡợơ',
      'r': 'ŕŗř',
      's': 'śŝşšș',
      't': 'ţťŧț',
      'u': 'ùúûüũūŭůűųǔȕȗụủứừửữựư',
      'y': 'ýÿŷ',
      'z': 'źżž',
    };
    final out = <int, String>{};
    groups.forEach((base, variants) {
      for (final r in variants.runes) {
        out[r] = base;
      }
    });
    // Uppercase variants map to the same (already lowercased later) base.
    groups.forEach((base, variants) {
      for (final r in variants.toUpperCase().runes) {
        out[r] = base;
      }
    });
    return out;
  }

  static bool _isCombiningMark(int r) =>
      (r >= 0x0300 && r <= 0x036F) ||
      (r >= 0x1AB0 && r <= 0x1AFF) ||
      (r >= 0x1DC0 && r <= 0x1DFF) ||
      (r >= 0x20D0 && r <= 0x20FF) ||
      (r >= 0xFE20 && r <= 0xFE2F);

  static String norm(String s) {
    final buf = StringBuffer();
    var lastWasLatinLetter = false;
    for (final r in s.runes) {
      final base = _latinBase[r];
      if (base != null) {
        buf.write(base);
        lastWasLatinLetter = true;
        continue;
      }
      // Drop a combining mark only after a Latin letter (Kotlin LATIN_MARKS).
      if (_isCombiningMark(r) && lastWasLatinLetter) continue;
      buf.writeCharCode(r);
      lastWasLatinLetter =
          (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
    }
    var out = buf.toString().toLowerCase().replaceAll('&', ' and ');
    // [^\p{L}\p{M}\p{N} ] -> ' ' : approximated as ASCII punctuation -> ' '
    // (every non-ASCII letter/mark/number is kept, as in the original).
    out = out.runes
        .map((r) => (r < 0x80 &&
                !((r >= 0x61 && r <= 0x7A) ||
                    (r >= 0x30 && r <= 0x39) ||
                    r == 0x20))
            ? 0x20
            : r)
        .map(String.fromCharCode)
        .join();
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String coreTitle(String t) {
    final stripped =
        t.replaceAll(_brackets, '').replaceAll(_feat, '').replaceAll(_dashNote, '');
    final s = norm(stripped);
    return s.isEmpty ? norm(t) : s;
  }

  /// [coreTitle] that also drops "| …" tails and YouTube upload junk
  /// ("Official Video", "Lyrical"…).
  static String cleanTitle(String t) {
    var noPipe = t.replaceAll(_pipeTail, '');
    if (noPipe.trim().isEmpty) noPipe = t;
    final stripped = noPipe
        .replaceAll(_brackets, '')
        .replaceAll(_feat, '')
        .replaceAll(_dashNote, '')
        .replaceAll(_junk, ' ');
    final s = norm(stripped);
    return s.isEmpty ? coreTitle(t) : s;
  }

  static Set<String> artists(String a) {
    return a
        .split(RegExp(
            r'\s*(?:,|&|/|;|\bfeat\.?|\bft\.?|\bx\b|\band\b|\bwith\b)\s*',
            caseSensitive: false))
        .map((part) => norm(part.trim().replaceAll(_channelJunk, '')))
        .where((x) => x.isNotEmpty)
        .toSet();
  }

  /// Search queries for finding [t] on another source: clean title + primary
  /// artist, then the clean title alone.
  static List<String> searchQueries(Track t) {
    var title = t.title.replaceAll(_brackets, '').replaceAll(_pipeTail, '');
    title = title.replaceAll(_junk, ' ');
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.isEmpty) title = t.title;
    var artist = t.artist.split(',').first.split('&').first.trim();
    artist = artist.replaceAll(_channelJunk, '').trim();
    final out = <String>[];
    final withArtist = '$title $artist'.trim();
    if (withArtist.isNotEmpty) out.add(withArtist);
    if (artist.isNotEmpty && title != withArtist) out.add(title);
    return out;
  }

  static Set<String> _tokens(String s) =>
      s.split(' ').where((x) => x.isNotEmpty).toSet();

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    return a.intersection(b).length / a.union(b).length;
  }

  /// 0..1: how likely [b] is the same recording as [a]. [lenient]
  /// (YouTube -> other-source fallback) cleans YouTube title junk, accepts
  /// the artist when it appears in the other title, and turns a long
  /// duration mismatch (video intros/outros) into a penalty instead of a
  /// veto.
  static double score(Track a, Track b, {bool lenient = false}) {
    if (a.isrc != null && b.isrc != null) {
      return a.isrc!.toLowerCase() == b.isrc!.toLowerCase() ? 1.0 : 0.0;
    }
    final ta = lenient ? cleanTitle(a.title) : coreTitle(a.title);
    final tb = lenient ? cleanTitle(b.title) : coreTitle(b.title);
    final double title;
    if (ta == tb) {
      title = 1.0;
    } else if (ta.isNotEmpty &&
        tb.isNotEmpty &&
        (ta.startsWith(tb) || tb.startsWith(ta))) {
      title = 0.85;
    } else if (lenient &&
        ta.isNotEmpty &&
        tb.isNotEmpty &&
        (_tokens(tb).every(_tokens(ta).contains) ||
            _tokens(ta).every(_tokens(tb).contains))) {
      title = 0.8;
    } else {
      title = _jaccard(_tokens(ta), _tokens(tb));
    }
    // A remix/live/cover only matches a remix/live/cover.
    if (_version.hasMatch(a.title) != _version.hasMatch(b.title)) {
      return title * 0.4;
    }
    final aa = artists(a.artist);
    final ab = artists(b.artist);
    final fullA = norm('${a.title} ${a.artist}');
    final fullB = norm('${b.title} ${b.artist}');
    final double artist;
    if (aa.isEmpty || ab.isEmpty) {
      artist = 0.5;
    } else if (aa.intersection(ab).isNotEmpty) {
      artist = 1.0;
    } else if (aa.any((x) => ab.any((y) => x.contains(y) || y.contains(x)))) {
      artist = 0.85;
    } else if (lenient &&
        (ab.any((it) => it.length >= 3 && fullA.contains(it)) ||
            aa.any((it) => it.length >= 3 && fullB.contains(it)))) {
      artist = 0.85;
    } else {
      final j = _jaccard(
        aa.expand(_tokens).toSet(),
        ab.expand(_tokens).toSet(),
      );
      artist = lenient ? math.max(j, 0.2) : j;
    }
    final double dur;
    if (a.durationMs <= 0 || b.durationMs <= 0) {
      dur = 0.75;
    } else {
      final d = (a.durationMs - b.durationMs).abs();
      if (d <= 3000) {
        dur = 1.0;
      } else if (d <= 7000) {
        dur = 0.8;
      } else if (d <= 15000) {
        dur = 0.4;
      } else if (lenient && d <= 90000) {
        dur = 0.2;
      } else {
        dur = 0.0;
      }
    }
    if (dur == 0.0) return 0.0;
    return title * 0.5 + artist * 0.3 + dur * 0.2;
  }

  static const double threshold = 0.72;

  /// Fallback threshold: an exact clean title with a matching artist passes
  /// even with a long video intro.
  static const double lenientThreshold = 0.66;

  static Track? best(
    Track target,
    List<Track> candidates, {
    double threshold = TrackMatcher.threshold,
    bool lenient = false,
  }) {
    Track? bestTrack;
    var bestScore = double.negativeInfinity;
    for (final c in candidates) {
      final s = score(target, c, lenient: lenient);
      if (s >= threshold && s > bestScore) {
        bestScore = s;
        bestTrack = c;
      }
    }
    return bestTrack;
  }
}

// ---------------------------------------------------------------------------
// QualityEstimate (Routing.kt)
// ---------------------------------------------------------------------------

/// Expected quality of a source/track before playback, used to order
/// cross-source candidates. Higher is better.
abstract final class QualityEstimate {
  static const Set<String> _lossless = {
    'flac', 'alac', 'wav', 'aiff', 'aif', 'ape', 'wv',
  };

  static bool isLosslessFormat(String? f) =>
      f != null && _lossless.contains(f.toLowerCase());

  /// Rough rank in "kbps-equivalent": lossless 1000+, else the
  /// known/expected bitrate.
  static int rank(Track t, Quality quality, bool premium) {
    if (isLosslessFormat(t.format)) {
      return (quality == Quality.lossless ||
              quality == Quality.max ||
              t.source == SourceKind.local)
          ? 1411
          : 300;
    }
    final kbps = t.bitrateKbps;
    if (kbps != null) return kbps;
    return switch (t.source) {
      SourceKind.jiosaavn => 320,
      SourceKind.youtube => premium ? 256 : 160,
      SourceKind.audius => 320,
      SourceKind.jamendo => 200,
      SourceKind.archive => 192,
      SourceKind.soundcloud => 128,
      SourceKind.local ||
      SourceKind.subsonic ||
      SourceKind.jellyfin =>
        256,
      SourceKind.spotify => 0,
    };
  }
}

// ---------------------------------------------------------------------------
// SourceRouter (Routing.kt)
// ---------------------------------------------------------------------------

/// Pure routing: given the track the user picked and same-recording matches
/// from other sources, the ordered list to try. Disabled and metadata-only
/// sources are dropped. In Auto/High the user's source priority decides;
/// in Max/Lossless the highest expected quality wins and priority breaks
/// ties. On failure the player walks on to the next entry (failover).
abstract final class SourceRouter {
  static List<Track> plan(
    Track original,
    List<Track> matches,
    List<SourceKind> priority,
    Set<SourceKind> enabled,
    Quality quality, {
    bool premium = false,
  }) {
    final seen = <String>{};
    final all = <Track>[];
    for (final t in [original, ...matches]) {
      if (!seen.add(t.id)) continue;
      if (!t.source.playable) continue;
      if (enabled.contains(t.source) ||
          (t.id == original.id && t.source == SourceKind.local)) {
        all.add(t);
      }
    }
    int prio(Track t) {
      final i = priority.indexOf(t.source);
      return i < 0 ? 0x7fffffff : i;
    }

    return switch (quality) {
      Quality.auto || Quality.high => _stableSorted(all, (a, b) => prio(a).compareTo(prio(b))),
      Quality.max || Quality.lossless => _stableSorted(all, (a, b) {
          final byRank =
              QualityEstimate.rank(b, quality, premium).compareTo(QualityEstimate.rank(a, quality, premium));
          return byRank != 0 ? byRank : prio(a).compareTo(prio(b));
        }),
    };
  }

  /// Which other sources are worth searching for a match of [original]
  /// (cost control: only ones that could win).
  static List<SourceKind> sourcesToSearch(
    Track original,
    List<SourceKind> priority,
    Set<SourceKind> enabled,
    Quality quality,
    bool premium,
  ) {
    const searchable = {
      SourceKind.youtube,
      SourceKind.jiosaavn,
      SourceKind.audius,
      SourceKind.jamendo,
      SourceKind.subsonic,
      SourceKind.jellyfin,
      SourceKind.local,
    };
    final candidates = priority
        .where((k) =>
            enabled.contains(k) &&
            searchable.contains(k) &&
            k != original.source)
        .toList();
    if (!original.source.playable) {
      return candidates; // Spotify metadata: must find something
    }
    return switch (quality) {
      Quality.auto || Quality.high => candidates
          .where((k) =>
              priority.indexOf(k) < priority.indexOf(original.source))
          .toList(),
      Quality.max || Quality.lossless => () {
          final mine = QualityEstimate.rank(original, quality, premium);
          return candidates.where((k) {
            final dummy = Track(
              id: '${k.prefix}:x',
              title: '',
              artist: '',
              format: const {
                    SourceKind.subsonic,
                    SourceKind.jellyfin,
                    SourceKind.local,
                  }.contains(k)
                  ? 'flac'
                  : null,
            );
            return QualityEstimate.rank(dummy, quality, premium) > mine;
          }).toList();
        }(),
    };
  }
}

// ---------------------------------------------------------------------------
// SourceManager (SourceManager.kt)
// ---------------------------------------------------------------------------

/// Picks where a track actually plays from: downloads first, then the
/// ordered plan from [SourceRouter] (user priority or best quality), with
/// failover to the next candidate when one fails.
class SourceManager {
  SourceManager({
    required this.sources,
    required List<SourceKind> Function() priority,
    required Set<SourceKind> Function() enabled,
    required bool Function() premium,
    required Resolved? Function(String trackId) downloaded,
    Future<int?> Function(Resolved resolved)? streamProbe,
  })  : _priority = priority,
        _enabled = enabled,
        _premium = premium,
        _downloaded = downloaded,
        _streamProbe = streamProbe;

  final Map<SourceKind, MusicSource> sources;
  final List<SourceKind> Function() _priority;
  final Set<SourceKind> Function() _enabled;
  final bool Function() _premium;
  final Resolved? Function(String trackId) _downloaded;

  /// HTTP status of a tiny ranged GET of a fallback stream (null = not
  /// probed). Diagnostics + early 4xx detection.
  final Future<int?> Function(Resolved resolved)? _streamProbe;

  /// Bounded LRU of cross-source matches (never grows without limit; fixes
  /// OpenTune B3-style leaks). Dart maps are insertion-ordered; a hit
  /// re-inserts its key, and the eldest entry is evicted past 300.
  final Map<String, List<Track>> _matchCache = {};

  List<Track>? _cacheGet(String key) {
    final v = _matchCache.remove(key);
    if (v != null) _matchCache[key] = v;
    return v;
  }

  void _cachePut(String key, List<Track> value) {
    _matchCache.remove(key);
    _matchCache[key] = value;
    while (_matchCache.length > 300) {
      _matchCache.remove(_matchCache.keys.first);
    }
  }

  MusicSource? source(SourceKind kind) => sources[kind];

  Set<SourceKind> enabledKinds() {
    final out = _enabled()
        .where((k) => sources[k]?.available() == true)
        .toSet();
    if (sources[SourceKind.local]?.available() == true) {
      out.add(SourceKind.local);
    }
    return out;
  }

  /// Same-recording matches on other sources (only where they could improve
  /// on or replace the original). Each source search gets a 4 s budget.
  Future<List<Track>> matchesFor(Track t, Quality quality) async {
    final kinds = SourceRouter.sourcesToSearch(
        t, _priority(), enabledKinds(), quality, _premium());
    if (kinds.isEmpty) return const [];
    final key = '${t.id}|${kinds.join(',')}';
    final cached = _cacheGet(key);
    if (cached != null) return cached;
    final q = '${t.title} ${t.artist.split(',').first}';
    final lists = await Future.wait(kinds.map((k) async {
      try {
        final r = await _timeoutOrNull(
          sources[k]?.search(q, 8) ?? Future.value(const <Track>[]),
          searchBudget,
        );
        return r ?? const <Track>[];
      } catch (_) {
        return const <Track>[];
      }
    }));
    final found = <Track>[];
    for (final list in lists) {
      final hit = TrackMatcher.best(t, list);
      if (hit != null) found.add(hit);
    }
    _cachePut(key, found);
    return found;
  }

  /// Resolve with failover. [onFailure] gets each candidate that failed
  /// (shown in the player as a source switch). [exclude] drops sources for
  /// this track (playback excludes YouTube after repeated 403s). When
  /// YouTube failed or is excluded, every other enabled source is searched
  /// via [TrackMatcher] (lenient) regardless of priority (JioSaavn first),
  /// and the result carries `fallbackFrom = SourceKind.youtube`.
  ///
  /// YouTube gets its own budget ([ytBudget]); the fallback then gets a
  /// fresh one (search [fallbackSearchBudget] + resolve
  /// [fallbackResolveBudget] per candidate), so a slow YouTube walk can no
  /// longer eat the fallback's time.
  Future<Resolved> resolve(
    Track t,
    Quality quality,
    bool metered, {
    Set<SourceKind> exclude = const {},
    void Function(Track track, Object error) onFailure = _ignoreFailure,
  }) async {
    final dl = _downloaded(t.id);
    if (dl != null) return dl;
    final usable = enabledKinds().difference(exclude);
    logSource('Sources: enabled=${usable.map((k) => k.label).join(', ')}'
        '${exclude.isNotEmpty ? ' excluded=${exclude.map((k) => k.label).join(', ')}' : ''} '
        '(metered=$metered)');
    var matches = const <Track>[];
    if (!(t.source.playable &&
        quality == Quality.high &&
        usable.contains(t.source))) {
      try {
        matches = await matchesFor(t, quality);
      } catch (_) {
        matches = const [];
      }
    }
    final plan =
        SourceRouter.plan(t, matches, _priority(), usable, quality, premium: _premium());
    final ytOut = exclude.contains(SourceKind.youtube) &&
        (t.source == SourceKind.youtube || plan.isEmpty);
    if (ytOut) logSource('YouTube excluded for this track');
    if (plan.isEmpty && !ytOut) {
      throw SourceUnavailableException(t.source == SourceKind.spotify
          ? 'No playable match for this Spotify song on your enabled sources'
          : '${t.source.label} is turned off in Settings → Sources');
    }
    logSource('Plan: ${plan.map((c) => c.source.label).join(', ')}');
    Object? last;
    var ytFailed = ytOut;
    final tried = <SourceKind>{};
    final fbKinds = _fallbackKinds(
      t,
      usable,
      {
        ...tried,
        for (final c in plan)
          if (c.source != SourceKind.youtube) c.source,
      },
    );
    if (usable.contains(SourceKind.soundcloud)) {
      logSource('Fallback: SoundCloud left out of the automatic fallback '
          '(NewPipe client id discovery is unreliable)');
    }
    if (!usable.contains(SourceKind.jiosaavn)) {
      logSource('Fallback: JioSaavn is disabled in Settings → Sources');
    }
    // v2.0.5 race: the fallback search starts together with YouTube, so its
    // answer is ready when YouTube is slow or fails.
    Future<List<Track>>? fallbackFuture;
    Future<List<Track>> startFallback(List<SourceKind> kinds) =>
        fallbackFuture ??= _fallbackSearch(t, kinds);

    for (final cand in plan) {
      final dlc = _downloaded(cand.id);
      if (dlc != null) return dlc;
      final src = sources[cand.source];
      if (src == null) continue;
      tried.add(cand.source);
      final budget =
          cand.source == SourceKind.youtube ? ytBudget : otherBudget;
      try {
        final r = (cand.source == SourceKind.youtube && fbKinds.isNotEmpty)
            ? await _raceYouTube(
                cand, src, quality, metered, budget, startFallback(fbKinds))
            : await _timeoutOrNull(
                src.resolve(cand, quality, metered), budget);
        if (r == null) {
          throw SourceUnavailableException(
              '${cand.source.label} timed out after ${budget.inSeconds} s');
        }
        logSource('${r.info.source.label}: resolved (${r.info.codec ?? '?'})');
        return r;
      } catch (e) {
        last = e;
        onFailure(cand, e);
        logSource('${cand.source.label} failed: ${e.runtimeType}: $e');
        if (cand.source == SourceKind.youtube) ytFailed = true;
      }
    }
    if (ytFailed) {
      // YouTube exhausted: every other enabled source, priority
      // notwithstanding, with a fresh time budget.
      final kinds = _fallbackKinds(t, usable, tried);
      final Future<List<Track>>? f =
          fallbackFuture ?? (kinds.isNotEmpty ? startFallback(kinds) : null);
      final found = (f != null ? await f : const <Track>[])
          .where((c) =>
              !tried.contains(c.source) || c.source == SourceKind.jiosaavn)
          .toList();
      for (final cand in found) {
        try {
          return await _resolveFallback(cand, quality, metered);
        } catch (e) {
          last = e;
          onFailure(cand, e);
          logSource('Fallback ${cand.source.label} failed: ${e.runtimeType}: $e');
        }
      }
      last ??= SourceUnavailableException(
          "YouTube can't play this track and no other enabled source has it");
    }
    throw last ?? SourceUnavailableException('No source could play this track');
  }

  static void _ignoreFailure(Track track, Object error) {}

  List<SourceKind> _fallbackKinds(
      Track t, Set<SourceKind> usable, Set<SourceKind> tried) {
    final seen = <SourceKind>{};
    return [
      SourceKind.jiosaavn,
      ..._priority(),
      ...sources.keys,
    ]
        .where(seen.add)
        .where((k) =>
            k != SourceKind.youtube &&
            usable.contains(k) &&
            !tried.contains(k) &&
            _fallbackSearchable.contains(k) &&
            k != t.source)
        .toList();
  }

  /// YouTube against the head-start fallback: YouTube alone for
  /// [raceAfter]; after that, a fallback match that resolves first wins
  /// (YouTube is abandoned), otherwise YouTube keeps its full [budget]. A
  /// YouTube failure is rethrown so the caller's failover logs it and uses
  /// the fallback.
  Future<Resolved?> _raceYouTube(
    Track cand,
    MusicSource src,
    Quality quality,
    bool metered,
    Duration budget,
    Future<List<Track>> fb,
  ) async {
    final started = DateTime.now();
    Resolved? ytResult;
    Object? ytError;
    var ytDone = false;
    final ytFuture = () async {
      try {
        ytResult =
            await _timeoutOrNull(src.resolve(cand, quality, metered), budget);
      } catch (e) {
        ytError = e;
      } finally {
        ytDone = true;
      }
    }();
    final sw = Stopwatch()..start();
    while (!ytDone && sw.elapsed < raceAfter) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (ytDone) {
      if (ytError != null) throw ytError!;
      return ytResult;
    }
    // YouTube is slow: resolve the fallback match (if any) while YouTube
    // keeps going; first stream wins.
    Resolved? altResult;
    var altDone = false;
    () async {
      List<Track> found;
      try {
        found = await fb;
      } catch (_) {
        found = const [];
      }
      for (final c in found) {
        try {
          altResult = await _resolveFallback(c, quality, metered);
          break;
        } catch (_) {
          // try the next fallback candidate
        }
      }
      altDone = true;
    }();
    while (true) {
      if (ytDone) {
        if (ytError != null) throw ytError!;
        return ytResult; // may be null: YouTube timed out
      }
      if (altDone) {
        final r = altResult;
        if (r != null) {
          logSource('Race: YouTube had no stream after '
              '${DateTime.now().difference(started).inSeconds} s; '
              '${r.info.source.label} was ready first');
          return r;
        }
        await ytFuture;
        if (ytError != null) throw ytError!;
        return ytResult;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Searches [kinds] in parallel, each with every query in parallel,
  /// within [fallbackSearchBudget]; returns the best lenient match per
  /// source (JioSaavn first).
  Future<List<Track>> _fallbackSearch(
      Track t, List<SourceKind> kinds) async {
    final queries = TrackMatcher.searchQueries(t);
    logSource('Fallback: searching ${kinds.map((k) => k.label).join(', ')} '
        'for ${queries.map((q) => '"$q"').join(' | ')}');
    final perKind = await Future.wait(kinds.map((k) async {
      try {
        return await _timeoutOrNull(() async {
          final results = await Future.wait(queries.map((q) async {
            try {
              return await sources[k]?.search(q, 10) ?? const <Track>[];
            } catch (e) {
              logSource('Fallback ${k.label}: "$q" failed ${e.runtimeType}: $e');
              return const <Track>[];
            }
          }));
          for (final list in results) {
            final hit = TrackMatcher.best(t, list,
                threshold: TrackMatcher.lenientThreshold, lenient: true);
            if (hit != null) return hit;
          }
          return null;
        }(), fallbackSearchBudget);
      } catch (_) {
        return null;
      }
    }));
    return perKind.whereType<Track>().toList();
  }

  Future<Resolved> _resolveFallback(
      Track cand, Quality quality, bool metered) async {
    final dl = _downloaded(cand.id);
    if (dl != null) {
      return dl.copyWith(fallbackFrom: SourceKind.youtube);
    }
    final src = sources[cand.source];
    if (src == null) {
      throw SourceUnavailableException('${cand.source.label} unavailable');
    }
    final r = await _timeoutOrNull(
        src.resolve(cand, quality, metered), fallbackResolveBudget);
    if (r == null) {
      throw SourceUnavailableException('${cand.source.label} timed out');
    }
    int? code;
    try {
      code = await _streamProbe?.call(r);
    } catch (_) {
      code = null;
    }
    logSource('Fallback ${cand.source.label}: stream '
        '${code != null ? 'HTTP $code' : 'not probed'} ${r.uri}');
    if (code != null && code >= 400) {
      throw SourceUnavailableException(
          '${cand.source.label} stream HTTP $code');
    }
    return r.copyWith(fallbackFrom: SourceKind.youtube);
  }

  // Budgets (SourceManager.kt companion object).
  static const Duration ytBudget = Duration(milliseconds: 22000);
  static const Duration otherBudget = Duration(milliseconds: 15000);

  /// v2.0.5: was 9 s (JioSaavn "search timed out" on Ravi's mobile network).
  static const Duration fallbackSearchBudget = Duration(milliseconds: 20000);

  /// YouTube runs alone this long before a ready fallback stream may win
  /// the race.
  static const Duration raceAfter = Duration(milliseconds: 6000);
  static const Duration fallbackResolveBudget = Duration(milliseconds: 12000);

  /// Per-source budget for the cross-source match search (matchesFor).
  static const Duration searchBudget = Duration(milliseconds: 4000);

  static const Set<SourceKind> _fallbackSearchable = {
    SourceKind.jiosaavn,
    SourceKind.audius,
    SourceKind.jamendo,
    SourceKind.subsonic,
    SourceKind.jellyfin,
    SourceKind.local,
    SourceKind.archive,
  };
}
