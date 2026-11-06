// Ported from UpZe (Kotlin) lyrics/LyricsRepository.kt + lyrics/Lyrics.kt
// essentials + the HTTP providers of lyrics/LyricsPlus.kt, lyrics/KuGou.kt
// and lyrics/NetEase.kt, and lyrics/Support.kt (LyricsQuality / Ttml).
// Originals derive from OpenTune 1.0.4, GPL-3.0-or-later.
// Modified for UpZe (C) 2026 Ravi, GPL-3.0-or-later.
//
// NOT ported, deliberately:
//  * Romanizer.kt — romanisation of CJK lyrics; a separate feature, not
//    part of the lookup chain.
//  * The Kotlin disk cache used dart:io files + kotlinx.serialization;
//    [LyricsCache] below keeps the same behaviour (SHA-1 file names,
//    bounded LRU eviction, a cached miss expires after a day) on dart:io.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';
import 'lrc_parser.dart';

// ---------------------------------------------------------------------------
// Result type (Kotlin: sealed interface Lyrics)
// ---------------------------------------------------------------------------

/// What a lyrics lookup returns: either time-synced lines or plain text.
sealed class LyricsResult {
  const LyricsResult();

  /// Provider credit, e.g. "LRCLIB", "KuGou", "YouTube Music · …".
  String get source;

  bool get isSynced => this is SyncedLyrics;

  /// The synced lines, or null when this is a plain result.
  List<LyricLine>? get syncedLines =>
      this is SyncedLyrics ? (this as SyncedLyrics).lines : null;

  /// The plain text, or null when this is a synced result.
  String? get plainText => this is PlainLyrics ? (this as PlainLyrics).text : null;

  Map<String, dynamic> toJson();

  static LyricsResult? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    switch (j['kind']) {
      case 'synced':
        return SyncedLyrics(
          ((j['lines'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LyricLine.fromJson)
              .toList(),
          j['source'] as String? ?? '',
          parts: ((j['parts'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(SongPart.fromJson)
              .toList(),
          recordingMs: (j['recordingMs'] as num?)?.toInt() ?? 0,
          autoOffsetMs: (j['autoOffsetMs'] as num?)?.toInt() ?? 0,
        );
      case 'plain':
        return PlainLyrics(j['text'] as String? ?? '', j['source'] as String? ?? '');
      default:
        return null;
    }
  }
}

/// Time-synced lyrics (Kotlin: Lyrics.Synced).
class SyncedLyrics extends LyricsResult {
  final List<LyricLine> lines;

  @override
  final String source;

  /// The song's verse, chorus and so on, when the source marks them.
  final List<SongPart> parts;

  /// How long the recording the source timed these to is, in ms; 0 when it doesn't say.
  final int recordingMs;

  /// A shift found by comparing the sources' timing, added to the position
  /// as the per-song offset is; that offset, once set, is used instead.
  final int autoOffsetMs;

  const SyncedLyrics(
    this.lines,
    this.source, {
    this.parts = const [],
    this.recordingMs = 0,
    this.autoOffsetMs = 0,
  });

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'synced',
        'source': source,
        'lines': lines.map((l) => l.toJson()).toList(),
        'parts': parts.map((p) => p.toJson()).toList(),
        'recordingMs': recordingMs,
        'autoOffsetMs': autoOffsetMs,
      };
}

/// Unsynced lyrics text (Kotlin: Lyrics.Plain).
class PlainLyrics extends LyricsResult {
  final String text;

  @override
  final String source;

  const PlainLyrics(this.text, this.source);

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'plain', 'source': source, 'text': text};
}

/// What to add to the playback position for [lyrics]: the listener's own
/// offset for the song ([manual]), else the one found automatically.
int lyricsOffset(int? manual, LyricsResult? lyrics) =>
    manual ?? (lyrics is SyncedLyrics ? lyrics.autoOffsetMs : 0);

// ---------------------------------------------------------------------------
// Query (Kotlin: LyricsQuery)
// ---------------------------------------------------------------------------

/// What a provider is asked for.
class LyricsQuery {
  final String title;
  final String artist;
  final String? album;
  final int durationMs;

  /// YouTube video id, when the track came from YouTube (the YTM provider
  /// needs it; the database providers ignore it).
  final String? videoId;

  const LyricsQuery({
    required this.title,
    required this.artist,
    this.album,
    this.durationMs = 0,
    this.videoId,
  });

  /// The query [App.lyricsFor] builds in the Kotlin app: the video id is
  /// only carried for YouTube tracks.
  factory LyricsQuery.forTrack(Track t) => LyricsQuery(
        title: t.title,
        artist: t.artist,
        album: t.album,
        durationMs: t.durationMs,
        videoId: t.id.startsWith('yt:') ? t.id.substring(3) : null,
      );
}

// ---------------------------------------------------------------------------
// Track name cleaning (Kotlin: TrackNameCleaner, in Lyrics.kt)
// ---------------------------------------------------------------------------

class CleanedName {
  final String title;
  final String artist;
  const CleanedName(this.title, this.artist);
}

/// Turns a YouTube upload's title and channel into something a lyrics
/// database will match: "The Weeknd - Blinding Lights (Official Video)" by
/// "TheWeekndVEVO" becomes "Blinding Lights" by "The Weeknd".
class TrackNameCleaner {
  TrackNameCleaner._();

  static final RegExp _noise = RegExp(
    r'\s*[(\[](?:[^)\]]*\b(?:official|lyrics?|lyric video|audio|video|visuali[sz]er|mv|m/v|hd|hq|4k|remaster(?:ed)?|explicit|clean|color coded|deluxe|bonus|mono|stereo|radio edit|(?:single|album) version)\b[^)\]]*)[)\]]',
    caseSensitive: false,
  );
  static final RegExp _feat =
      RegExp(r'\s*[(\[]?\s*\b(?:feat\.?|ft\.?|featuring)\s.*$', caseSensitive: false);
  static final RegExp _releaseSuffix = RegExp(
    r'\s+[-–—]\s+(?:(?:\d{4}\s+)?remaster(?:ed)?(?:\s+(?:version|\d{4}))?|radio edit|(?:single|album|mono|stereo) version|mono|stereo|bonus track|deluxe(?:\s+edition)?)\s*$',
    caseSensitive: false,
  );
  static final RegExp _channelSuffix =
      RegExp(r'\s*(?:VEVO|- Topic|Official|Music)$', caseSensitive: false);

  static CleanedName clean(String title, String artist) {
    var t = title.replaceAll(_noise, '').replaceAll(_releaseSuffix, '');
    var a = artist.trim().replaceAll(_channelSuffix, '').trim();
    // "Artist - Title" uploads: take the artist from the title when it
    // agrees with the channel (which is often the same name, unspaced).
    final dash = RegExp(r'\s+[-–—]\s+').firstMatch(t);
    if (dash != null) {
      final left = t.substring(0, dash.start).trim();
      final right = t.substring(dash.end).trim();
      final leftKey = left.toLowerCase().replaceAll(' ', '');
      final artistKey = a.toLowerCase().replaceAll(' ', '');
      if (a.isEmpty || leftKey.contains(artistKey) || artistKey.contains(leftKey)) {
        a = left;
        t = right;
      }
    }
    t = t.replaceAll(_feat, '');
    a = a.replaceAll(_feat, '').split(',').first.split(' & ').first.trim();
    t = t.replaceAll(RegExp(r'\s*["“”]\s*'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return CleanedName(t.isEmpty ? title.trim() : t, a.isEmpty ? artist.trim() : a);
  }
}

// ---------------------------------------------------------------------------
// Loose matching (Kotlin: LyricsQuality, in Support.kt)
// ---------------------------------------------------------------------------

/// Loose title/artist comparison used to reject lyrics that belong to
/// another song.
///
/// Dart core has no Unicode normaliser, so [_looseText] folds the common
/// precomposed Latin accents through [_deaccent] and drops combining marks
/// in U+0300–U+036F — the practical subset of the Kotlin NFD strip.
class LyricsQuality {
  LyricsQuality._();

  static bool sameTitle(String want, String? got) {
    if (got == null) return true;
    final a = _titleKey(want);
    final b = _titleKey(got);
    if (a.isEmpty || b.isEmpty || a.contains(b) || b.contains(a)) return true;
    if (_latinText(a) != _latinText(b)) return true;
    final wa = _words(want);
    final wb = _words(got);
    if (wa.isEmpty || wb.isEmpty) return true;
    return overlap(wa, wb) >= 0.5;
  }

  static bool sameArtist(String want, String? got) {
    if (got == null) return true;
    final a = _looseKey(want);
    if (a.length < 2) return true;
    final parts = got
        .split(RegExp(r'\s*(?:,|&|/|;|\bfeat\.?|\bft\.?|\bx\b|\band\b|、)\s*',
            caseSensitive: false))
        .map(_looseKey)
        .where((p) => p.length >= 2)
        .toList();
    if (parts.isEmpty) return true;
    if (parts.any((p) => p.contains(a) || a.contains(p))) return true;
    return parts.every((p) => _latinText(p) != _latinText(a));
  }

  static double overlap(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final small = a.length <= b.length ? a : b;
    final large = a.length <= b.length ? b : a;
    return small.where(large.contains).length / small.length;
  }

  static String _titleKey(String s) => _looseKey(s
      .replaceAll(RegExp(r'\s*[(\[][^)\]]*[)\]]'), '')
      .replaceAll(
          RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\s.*$', caseSensitive: false), ''));

  static Set<String> _words(String s) =>
      _looseText(s).split(' ').where((w) => w.length >= 2).toSet();

  static String _looseText(String s) {
    final buf = StringBuffer();
    for (final rune in s.toLowerCase().runes) {
      if (rune >= 0x0300 && rune <= 0x036F) continue; // combining mark
      final ch = _deaccent[rune] ?? String.fromCharCode(rune);
      buf.write(_isLetterOrDigitRune(ch) ? ch : ' ');
    }
    return buf.toString().trim();
  }

  static String _looseKey(String s) =>
      _looseText(s).replaceAll(RegExp(r'[^a-z0-9\p{L}\p{N}]', unicode: true), '');

  static bool _latinText(String s) =>
      s.runes.where((r) => r < 0x250).length * 2 >= s.length;

  static bool _isLetterOrDigitRune(String ch) =>
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch);

  /// Precomposed Latin letter → base letter (the subset NFD + mark-strip
  /// would produce for the names lyrics databases actually carry).
  static const Map<int, String> _deaccent = {
    0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a',
    0xE6: 'ae', 0xE7: 'c',
    0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e',
    0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i',
    0xF0: 'd', 0xF1: 'n',
    0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o', 0xF8: 'o',
    0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u',
    0xFD: 'y', 0xFE: 'th', 0xFF: 'y',
    0xDF: 'ss',
    0x100: 'a', 0x101: 'a', 0x102: 'a', 0x103: 'a', 0x104: 'a', 0x105: 'a',
    0x106: 'c', 0x107: 'c', 0x108: 'c', 0x109: 'c', 0x10A: 'c', 0x10B: 'c',
    0x10C: 'c', 0x10D: 'c', 0x10E: 'd', 0x10F: 'd', 0x110: 'd', 0x111: 'd',
    0x112: 'e', 0x113: 'e', 0x114: 'e', 0x115: 'e', 0x116: 'e', 0x117: 'e',
    0x118: 'e', 0x119: 'e', 0x11A: 'e', 0x11B: 'e',
    0x11C: 'g', 0x11D: 'g', 0x11E: 'g', 0x11F: 'g', 0x120: 'g', 0x121: 'g',
    0x122: 'g', 0x123: 'g', 0x124: 'h', 0x125: 'h', 0x126: 'h', 0x127: 'h',
    0x128: 'i', 0x129: 'i', 0x12A: 'i', 0x12B: 'i', 0x12C: 'i', 0x12D: 'i',
    0x12E: 'i', 0x12F: 'i', 0x130: 'i', 0x131: 'i',
    0x134: 'j', 0x135: 'j', 0x136: 'k', 0x137: 'k', 0x139: 'l', 0x13A: 'l',
    0x13B: 'l', 0x13C: 'l', 0x13D: 'l', 0x13E: 'l', 0x13F: 'l', 0x140: 'l',
    0x141: 'l', 0x142: 'l', 0x143: 'n', 0x144: 'n', 0x145: 'n', 0x146: 'n',
    0x147: 'n', 0x148: 'n', 0x149: 'n', 0x14A: 'n', 0x14B: 'n', 0x14C: 'o',
    0x14D: 'o', 0x14E: 'o', 0x14F: 'o', 0x150: 'o', 0x151: 'o',
    0x152: 'oe', 0x153: 'oe', 0x154: 'r', 0x155: 'r', 0x156: 'r', 0x157: 'r',
    0x158: 'r', 0x159: 'r', 0x15A: 's', 0x15B: 's', 0x15C: 's', 0x15D: 's',
    0x15E: 's', 0x15F: 's', 0x160: 's', 0x161: 's', 0x162: 't', 0x163: 't',
    0x164: 't', 0x165: 't', 0x166: 't', 0x167: 't',
    0x168: 'u', 0x169: 'u', 0x16A: 'u', 0x16B: 'u', 0x16C: 'u', 0x16D: 'u',
    0x16E: 'u', 0x16F: 'u', 0x170: 'u', 0x171: 'u', 0x172: 'u', 0x173: 'u',
    0x174: 'w', 0x175: 'w', 0x176: 'y', 0x177: 'y', 0x178: 'y',
    0x179: 'z', 0x17A: 'z', 0x17B: 'z', 0x17C: 'z', 0x17D: 'z', 0x17E: 'z',
    0x17F: 's',
  };
}

/// TTML-style time strings (Kotlin: Ttml.time, in Support.kt).
class Ttml {
  Ttml._();

  static int? time(String? t) {
    if (t == null) return null;
    if (t.endsWith('ms')) {
      return double.tryParse(t.substring(0, t.length - 2))?.toInt();
    }
    if (t.endsWith('s')) {
      final v = double.tryParse(t.substring(0, t.length - 1));
      return v == null ? null : (v * 1000).toInt();
    }
    final parts = t.split(':');
    final sec = double.tryParse(parts.last);
    if (sec == null) return null;
    final min = parts.length >= 2 ? int.tryParse(parts[parts.length - 2]) ?? 0 : 0;
    final hr = parts.length >= 3 ? int.tryParse(parts[parts.length - 3]) ?? 0 : 0;
    return ((hr * 3600 + min * 60) * 1000) + (sec * 1000).toInt();
  }
}

// ---------------------------------------------------------------------------
// Providers (Kotlin: LyricsProvider + implementations)
// ---------------------------------------------------------------------------

abstract class LyricsProvider {
  String get id;
  String get label;
  Future<LyricsResult?> lookup(LyricsQuery q);
}

Map<String, dynamic>? _asMap(dynamic v) =>
    v is Map<String, dynamic> ? v : (v is Map ? v.cast<String, dynamic>() : null);

List<dynamic> _asList(dynamic v) => v is List ? v : const [];

String? _asString(dynamic v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

double? _asDouble(dynamic v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

int? _asInt(dynamic v) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

/// LRCLIB: open, free, synced LRC (and plain). (Kotlin: object LrcLib.)
class LrcLibProvider implements LyricsProvider {
  @override
  String get id => 'lrclib';
  @override
  String get label => 'LRCLIB (synced)';

  static const String userAgent =
      'UpZe/2.0 (https://github.com/ ; GPL-3.0, based on OpenTune)';

  final http.Client _client;
  LrcLibProvider([http.Client? client]) : _client = client ?? http.Client();

  @override
  Future<LyricsResult?> lookup(LyricsQuery q) async {
    final c = TrackNameCleaner.clean(q.title, q.artist);
    final getUri = Uri.https('lrclib.net', '/api/get', {
      'track_name': c.title,
      'artist_name': c.artist,
      if (q.album != null && q.album!.isNotEmpty) 'album_name': q.album!,
      if (q.durationMs > 0) 'duration': (q.durationMs ~/ 1000).toString(),
    });
    final directBody = await _get(getUri);
    final direct = directBody == null ? null : _decodeObject(directBody);
    if (direct != null) {
      final parsed = parse(direct, q.durationMs);
      if (parsed != null) return parsed;
    }
    final searchUri = Uri.https('lrclib.net', '/api/search', {
      'track_name': c.title,
      'artist_name': c.artist,
    });
    final searchBody = await _get(searchUri);
    if (searchBody == null) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(searchBody);
    } catch (_) {
      return null;
    }
    if (decoded is! List) return null;
    final candidates = decoded.whereType<Map<String, dynamic>>().where((o) {
      final d = (_asDouble(o['duration']) ?? 0) * 1000;
      return (q.durationMs <= 0 ||
              d <= 0 ||
              (d - q.durationMs).abs() <= 5000) &&
          LyricsQuality.sameTitle(c.title, _asString(o['trackName']));
    }).toList();
    // Synced candidates first (Kotlin: sortedByDescending syncedLyrics != null).
    candidates.sort((a, b) {
      final as = _asString(a['syncedLyrics']) != null ? 1 : 0;
      final bs = _asString(b['syncedLyrics']) != null ? 1 : 0;
      return bs.compareTo(as);
    });
    for (final o in candidates) {
      final parsed = parse(o, q.durationMs);
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// One LRCLIB record → lyrics (Kotlin: LrcLib.parse).
  static LyricsResult? parse(Map<String, dynamic> o, int durationMs) {
    if (o['instrumental'] == true || _asString(o['instrumental']) == 'true') {
      return null;
    }
    final lrc = _asString(o['syncedLyrics']);
    if (lrc != null && lrc.isNotEmpty) {
      final lines = LrcParser.parse(lrc, durationMs: durationMs);
      if (lines.isNotEmpty) return SyncedLyrics(lines, 'LRCLIB');
    }
    final plain = _asString(o['plainLyrics']);
    if (plain != null && plain.isNotEmpty) return PlainLyrics(plain, 'LRCLIB');
    return null;
  }

  Future<String?> _get(Uri uri) async {
    try {
      final r = await _client.get(uri, headers: {'User-Agent': userAgent});
      return r.statusCode == 200 ? r.body : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _decodeObject(String body) {
    try {
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }
}

/// LyricsPlus, the open lyrics backend behind the YouLyPlus extension:
/// community-run servers that answer with lines timed word by word where
/// the catalogue has them. No key or account. (Kotlin: LyricsPlus.kt.)
///
/// The server that answered last is asked first, alone for a moment; if it
/// is slow or has nothing, the others are asked together and the first
/// usable answer wins.
class LyricsPlusProvider implements LyricsProvider {
  @override
  String get id => 'lyricsplus';
  @override
  String get label => 'LyricsPlus (word-by-word)';

  static const List<String> servers = [
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.prjktla.my.id',
    'https://lyricsplus.prjktla.workers.dev',
    'https://lyricsplus-seven.vercel.app',
    'https://lyrics-plus-backend.vercel.app',
  ];
  static const String userAgent = 'UpZe/2.0 (GPL-3.0; based on OpenTune)';

  /// How long the last good server has before the rest are asked too.
  static const int headStartMs = 2500;
  static const int budgetMs = 9000;

  /// An answer further than this from the track's length is another recording.
  static const int toleranceMs = 8000;

  final http.Client _client;
  LyricsPlusProvider([http.Client? client]) : _client = client ?? http.Client();

  String? _lastGood;

  @override
  Future<LyricsResult?> lookup(LyricsQuery q) async {
    final cleaned = TrackNameCleaner.clean(q.title, q.artist);
    final first = _lastGood;
    if (first != null) {
      try {
        final r = await _ask(first, cleaned, q.durationMs, q.album)
            .timeout(const Duration(milliseconds: headStartMs));
        if (r != null) return r;
      } catch (_) {
        // Slow or failed: fall through to the race.
      }
    }
    final rest = servers.where((s) => s != first).toList();
    if (rest.isEmpty) return null;
    final winner = Completer<LyricsResult?>();
    var left = rest.length;
    for (final server in rest) {
      _ask(server, cleaned, q.durationMs, q.album).then((found) {
        if (found != null) {
          if (!winner.isCompleted) winner.complete(found);
        } else {
          left--;
          if (left == 0 && !winner.isCompleted) winner.complete(null);
        }
      }).catchError((_) {
        left--;
        if (left == 0 && !winner.isCompleted) winner.complete(null);
      });
    }
    try {
      return await winner.future
          .timeout(const Duration(milliseconds: budgetMs), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  Future<LyricsResult?> _ask(
      String server, CleanedName cleaned, int durationMs, String? album) async {
    final uri = Uri.parse('$server/v2/lyrics/get').replace(queryParameters: {
      'title': cleaned.title,
      'artist': cleaned.artist,
      if (durationMs > 0) 'duration': (durationMs ~/ 1000).toString(),
      if (album != null && album.isNotEmpty) 'album': album,
    });
    try {
      final r = await _client.get(uri, headers: {'User-Agent': userAgent});
      if (r.statusCode != 200) return null;
      return parse(r.body, durationMs, cleaned.title)?.also((_) => _lastGood = server);
    } catch (_) {
      return null;
    }
  }

  /// Parses one server's answer (Kotlin: LyricsPlus.parse).
  static LyricsResult? parse(String body, int durationMs, [String? title]) {
    Map<String, dynamic> root;
    try {
      final d = jsonDecode(body);
      if (d is! Map<String, dynamic>) return null;
      root = d;
    } catch (_) {
      return null;
    }
    final meta = _asMap(root['metadata']);
    final total = Ttml.time(_asString(meta?['totalDuration']));
    if (durationMs > 0 &&
        total != null &&
        total > 0 &&
        (total - durationMs).abs() > toleranceMs) {
      return null;
    }
    // The servers fall back to a fuzzy search; a hit under another title is another song.
    if (title != null &&
        !LyricsQuality.sameTitle(title, _asString(meta?['title']))) {
      return null;
    }
    final items = _asList(root['lyrics']).whereType<Map<String, dynamic>>().toList();
    final wordType =
        (_asString(root['type']) ?? '').toLowerCase() == 'word';
    final voices = voicesOf(_asMap(meta?['agents']));
    final lines = <LyricLine>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final start = _asInt(item['time']);
      if (start == null) continue;
      final next = i + 1 < items.length ? _asInt(items[i + 1]['time']) : null;
      final dur = _asInt(item['duration']);
      final end = dur != null ? start + dur : (next ?? start + 4000);
      final syllables =
          _asList(item['syllabus']).whereType<Map<String, dynamic>>().toList();
      final backing =
          syllables.where((s) => s['isBackground'] == true).toList();
      final lead = syllables.where((s) => s['isBackground'] != true).toList();
      final words = <LyricWord>[];
      for (final s in lead) {
        final text = _asString(s['text']);
        final b = _asInt(s['time']);
        if (text == null || b == null) continue;
        words.add(LyricWord(text, b, b + (_asInt(s['duration']) ?? 0)));
      }
      words.removeWhere((w) => w.text.trim().isEmpty);
      var text = words.isNotEmpty
          ? words.map((w) => w.text).join()
          : (_asString(item['text']) ?? '');
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      // Backing vocals go under the line rather than into its sweep.
      final background = backing
          .map((s) => _asString(s['text']) ?? '')
          .join()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final singer = _asString(_asMap(item['element'])?['singer']);
      final voice = voices[singer] ?? voiceLead;
      if (wordType && words.length >= 2) {
        lines.add(LyricLine(
            startMs: start,
            endMs: end,
            text: text,
            words: words,
            wordSynced: true,
            voice: voice,
            background: background.isEmpty ? null : background));
      } else {
        lines.add(LyricLine(
            startMs: start,
            endMs: end,
            text: text,
            words: LrcParser.spreadWords(text, start, end),
            wordSynced: false,
            voice: voice,
            background: background.isEmpty ? null : background));
      }
    }
    if (lines.isEmpty) return null;
    final parts = <SongPart>[];
    for (final p in _asList(meta?['songParts']).whereType<Map<String, dynamic>>()) {
      final at = _asInt(p['time']);
      if (at == null) continue;
      parts.add(SongPart(
          _asString(p['name']) ?? '', at, at + (_asInt(p['duration']) ?? 0)));
    }
    return SyncedLyrics(lines, 'LyricsPlus',
        parts: parts, recordingMs: (total != null && total > 0) ? total : 0);
  }

  /// Singers by id: a group sings together; of the people, the first listed
  /// is the lead and the next a second voice, and so on in turn.
  static Map<String, int> voicesOf(Map<String, dynamic>? agents) {
    if (agents == null) return const {};
    var person = 0;
    final out = <String, int>{};
    agents.forEach((key, v) {
      final type = _asString(_asMap(v)?['type']);
      if (type == 'group') {
        out[key] = voiceTogether;
      } else {
        out[key] = (person++ % 2 == 0) ? voiceLead : voiceSecond;
      }
    });
    return out;
  }
}

extension _Also<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

/// Drops what KuGou puts before the song: a "Title - Artist" line and
/// credit lines (lyricist, composer, producer, mixing and the rest), which
/// would otherwise show as lyrics. Shared with NetEase, as in Kotlin
/// (KuGou.clean). Later in the song only the known credit labels are
/// dropped, so a lyric with a colon in it stays.
List<LyricLine> kugouClean(List<LyricLine> lines, String title, String artist) {
  final t = title.toLowerCase();
  final a = artist.toLowerCase();
  bool isHeader(String text) =>
      text.contains(' - ') &&
      (text.toLowerCase().contains(t) || text.toLowerCase().contains(a));
  bool isCredit(String text) =>
      _kugouCredit.hasMatch(text) || text.contains('：');
  final firstLyric = lines.indexWhere(
      (l) => l.text.isNotEmpty && !isHeader(l.text) && !isCredit(l.text));
  if (firstLyric < 0) return const [];
  return lines
      .sublist(firstLyric)
      .where((l) => !_kugouCredit.hasMatch(l.text))
      .toList();
}

final RegExp _kugouCredit = RegExp(
  r'^\s*(作词|作曲|编曲|制作人|监制|混音|和声|吉他|贝斯|鼓|录音|母带|出品|发行|OP|SP|(lyrics|words|music|composed|composer|written|arranged|produced|producer|mixed|mastered|recorded|engineered|vocals?)( by| at)?)\s*[:：]',
  caseSensitive: false,
);

final RegExp _versionWords = RegExp(
  r'\b(remix|live|instrumental|karaoke|acoustic|cover|sped up|slowed|dj)\b|伴奏|翻唱|现场',
  caseSensitive: false,
);

/// Line-synced lyrics from KuGou's public lyrics service, which needs no
/// account or key. Strong on Chinese, Japanese and Korean songs.
/// Only the plain LRC format is used — KuGou's word-by-word KRC format is
/// encrypted. (Kotlin: KuGou.kt.)
class KuGouProvider implements LyricsProvider {
  @override
  String get id => 'kugou';
  @override
  String get label => 'KuGou (synced, strong for Asian music)';

  static const String base = 'https://lyrics.kugou.com';

  /// A candidate further than this from the track's length is a different recording.
  static const double toleranceMs = 8000;

  /// Searching by title alone finds other songs too, so the length has to agree closely.
  static const double titleOnlyToleranceMs = 2000;

  final http.Client _client;
  KuGouProvider([http.Client? client]) : _client = client ?? http.Client();

  @override
  Future<LyricsResult?> lookup(LyricsQuery q) async {
    final cleaned = TrackNameCleaner.clean(q.title, q.artist);
    Future<dynamic> search(String keyword) => _get(Uri.parse('$base/search')
        .replace(queryParameters: {
      'ver': '1',
      'man': 'yes',
      'client': 'mobi',
      'keyword': keyword,
      if (q.durationMs > 0) 'duration': q.durationMs.toString(),
    }));
    // The artist is often filed in its own script, so a miss on
    // "artist - title" tries the title alone, with a tighter length match.
    var hit = best(await search('${cleaned.artist} - ${cleaned.title}'),
        q.durationMs, cleaned.title);
    hit ??= q.durationMs > 0
        ? best(await search(cleaned.title), q.durationMs, cleaned.title,
            titleOnlyToleranceMs)
        : null;
    if (hit == null) return null;
    final id = _asString(hit['id']);
    final key = _asString(hit['accesskey']);
    if (id == null || key == null) return null;
    final downloadUri = Uri.parse('$base/download').replace(queryParameters: {
      'ver': '1',
      'client': 'pc',
      'id': id,
      'accesskey': key,
      'fmt': 'lrc',
      'charset': 'utf8',
    });
    final lrc = lrcOf(await _get(downloadUri));
    if (lrc == null) return null;
    final lines =
        kugouClean(LrcParser.parse(lrc, durationMs: q.durationMs), cleaned.title, cleaned.artist);
    if (lines.isEmpty) return null;
    return SyncedLyrics(lines, 'KuGou',
        recordingMs: (_asDouble(hit['duration']) ?? 0).toInt());
  }

  /// The candidate closest to [durationMs], or null if none is close. A
  /// remix, live or instrumental version only counts when [title] is one
  /// too. (Kotlin: KuGou.best.)
  static Map<String, dynamic>? best(
      dynamic search, int durationMs, String title,
      [double tolerance = toleranceMs]) {
    final candidates = _asList(_asMap(search)?['candidates'])
        .whereType<Map<String, dynamic>>()
        .toList();
    double gap(Map<String, dynamic> o) => durationMs <= 0
        ? 0
        : ((_asDouble(o['duration']) ?? double.maxFinite) - durationMs).abs();
    final wantsVersion = _versionWords.hasMatch(title);
    final fitting = candidates.where((o) {
      if (gap(o) > tolerance) return false;
      if (!wantsVersion &&
          _versionWords.hasMatch(_asString(o['song']) ?? '')) {
        return false;
      }
      if (title.isNotEmpty &&
          !LyricsQuality.sameTitle(title, _asString(o['song']))) {
        return false;
      }
      return true;
    }).toList();
    if (fitting.isEmpty) return null;
    fitting.sort((a, b) => gap(a).compareTo(gap(b)));
    return fitting.first;
  }

  /// The LRC text inside a download answer (base64 in "content").
  static String? lrcOf(dynamic download) {
    final content = _asString(_asMap(download)?['content']);
    if (content == null || content.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(content));
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _get(Uri uri) async {
    final r = await _client.get(uri, headers: {'User-Agent': 'UpZe'});
    if (r.statusCode != 200) {
      throw HttpException('KuGou answered ${r.statusCode}', uri: uri);
    }
    return jsonDecode(r.body);
  }
}

/// Line-synced lyrics from NetEase Cloud Music's public web endpoints, with
/// no account or key. (Kotlin: NetEase.kt.)
class NetEaseProvider implements LyricsProvider {
  @override
  String get id => 'netease';
  @override
  String get label => 'NetEase Cloud Music (synced)';

  static const String base = 'https://music.163.com/api';

  /// A song further than this from the track's length is a different recording.
  static const int toleranceMs = 5000;

  static final RegExp _version = RegExp(
    r'\b(remix|live|instrumental|karaoke|acoustic|cover|sped up|slowed|nightcore|8d)\b|伴奏|翻唱|现场',
    caseSensitive: false,
  );

  final http.Client _client;
  NetEaseProvider([http.Client? client]) : _client = client ?? http.Client();

  @override
  Future<LyricsResult?> lookup(LyricsQuery q) async {
    final cleaned = TrackNameCleaner.clean(q.title, q.artist);
    final search = await _get(Uri.parse('$base/search/get').replace(queryParameters: {
      's': '${cleaned.title} ${cleaned.artist}',
      'type': '1',
      'limit': '10',
    }));
    final song = best(search, cleaned.title, q.durationMs, cleaned.artist);
    if (song == null) return null;
    final id = _asInt(song['id']);
    if (id == null) return null;
    final answer = await _get(Uri.parse('$base/song/lyric').replace(queryParameters: {
      'id': id.toString(),
      'lv': '1',
    }));
    final lrc = lrcOf(answer);
    if (lrc == null) return null;
    final lines =
        kugouClean(LrcParser.parse(lrc, durationMs: q.durationMs), cleaned.title, cleaned.artist);
    if (lines.isEmpty) return null;
    return SyncedLyrics(lines, 'NetEase',
        recordingMs: _asInt(song['duration']) ?? 0);
  }

  /// The song whose title matches and whose length is closest to
  /// [durationMs], leaving out remixes, live cuts and sped-up edits unless
  /// [title] is one; one by [artist] wins over a same-titled song by
  /// someone else. (Kotlin: NetEase.best.)
  static Map<String, dynamic>? best(
      dynamic search, String title, int durationMs, String artist) {
    final songs = _asList(_asMap(_asMap(search)?['result'])?['songs'])
        .whereType<Map<String, dynamic>>()
        .toList();
    String key(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final want = key(title);
    final wantsVersion = _version.hasMatch(title);
    int gap(Map<String, dynamic> o) => durationMs <= 0
        ? 0
        : ((_asInt(o['duration']) ?? 0x3fffffffffffffff) - durationMs).abs();
    final fitting = songs.where((o) {
      final name = _asString(o['name']) ?? '';
      final k = key(name);
      if (!(k == want || k.startsWith(want))) return false;
      if (!wantsVersion && _version.hasMatch(name)) return false;
      return gap(o) <= toleranceMs;
    }).toList();
    if (fitting.isEmpty) return null;
    var pool = fitting;
    if (artist.isNotEmpty) {
      final byArtist = fitting.where((o) {
        final names = _asList(o['artists'])
            .whereType<Map<String, dynamic>>()
            .map((a) => _asString(a['name']))
            .whereType<String>();
        return names.any((n) =>
            LyricsQuality.sameArtist(artist, n) &&
            LyricsQuality.sameArtist(n, artist));
      }).toList();
      if (byArtist.isNotEmpty) pool = byArtist;
    }
    pool.sort((a, b) => gap(a).compareTo(gap(b)));
    return pool.first;
  }

  /// The LRC text in a lyric answer; null when the song has none or only
  /// "instrumental" (fewer than 3 non-empty timed lines).
  static String? lrcOf(dynamic answer) {
    final lyric = _asString(_asMap(_asMap(answer)?['lrc'])?['lyric']);
    if (lyric == null || !lyric.contains('[')) return null;
    final timed = lyric
        .split('\n')
        .where((l) =>
            l.contains(']') && l.substring(l.indexOf(']') + 1).trim().isNotEmpty)
        .length;
    return timed >= 3 ? lyric : null;
  }

  Future<dynamic> _get(Uri uri) async {
    final r = await _client.get(uri, headers: {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36',
      'Referer': 'https://music.163.com/',
    });
    if (r.statusCode != 200) {
      throw HttpException('NetEase answered ${r.statusCode}', uri: uri);
    }
    return jsonDecode(r.body);
  }
}

/// YouTube Music's own lyrics tab (plain text, licensed provider credit
/// shown). The fetch itself is injected, exactly as in Kotlin, so this
/// layer stays free of a hard dependency on the Innertube client:
/// `(videoId) async => (text: ..., source: ...)` or null.
class YtLyricsProvider implements LyricsProvider {
  @override
  String get id => 'ytmusic';
  @override
  String get label => 'YouTube Music (plain)';

  final Future<({String text, String? source})?> Function(String videoId) fetch;

  YtLyricsProvider(this.fetch);

  @override
  Future<LyricsResult?> lookup(LyricsQuery q) async {
    final vid = q.videoId;
    if (vid == null) return null;
    final got = await fetch(vid);
    if (got == null) return null;
    return PlainLyrics(
        got.text, got.source != null ? 'YouTube Music · ${got.source}' : 'YouTube Music');
  }
}

// ---------------------------------------------------------------------------
// The chain (Kotlin: LyricsChain) + repository facade (Kotlin: App.lyricsFor)
// ---------------------------------------------------------------------------

/// Walks providers in the user's order. A synced result wins immediately;
/// the first plain result is kept as a fallback while later providers are
/// asked for synced lines. Each provider gets its own time budget, and one
/// failing never stops the chain.
///
/// NOTE: Dart's Future.timeout does not cancel the underlying HTTP request
/// (Kotlin's withTimeoutOrNull cancels the coroutine); a timed-out provider
/// may finish in the background, but its result is discarded.
class LyricsChain {
  LyricsChain._();

  static Future<LyricsResult?> find(
    List<LyricsProvider> providers,
    LyricsQuery q, {
    int perProviderMs = 8000,
    void Function(String providerId, String outcome)? onTried,
  }) async {
    LyricsResult? plain;
    for (final p in providers) {
      LyricsResult? r;
      try {
        r = await p
            .lookup(q)
            .timeout(Duration(milliseconds: perProviderMs), onTimeout: () => null);
      } catch (e) {
        onTried?.call(p.id, 'error: $e');
        continue;
      }
      onTried?.call(
          p.id,
          r == null
              ? 'none'
              : (r is SyncedLyrics ? 'synced' : 'plain'));
      if (r is SyncedLyrics) return r;
      if (r is PlainLyrics) plain ??= r;
    }
    return plain;
  }
}

/// The app's lyrics entry point: cache first, then the chain in the
/// Kotlin app's default provider order (App.kt `providers`):
/// LRCLIB → LyricsPlus → KuGou → NetEase → YouTube Music.
/// (In Kotlin the order/enabled set comes from user settings; here it is a
/// constructor parameter with that same default.)
class LyricsRepository {
  final List<LyricsProvider> providers;
  final LyricsCache? cache;

  LyricsRepository({List<LyricsProvider>? providers, this.cache})
      : providers = providers ?? defaultProviders();

  static List<LyricsProvider> defaultProviders({
    Future<({String text, String? source})?> Function(String videoId)?
        ytLyricsFetch,
  }) =>
      [
        LrcLibProvider(),
        LyricsPlusProvider(),
        KuGouProvider(),
        NetEaseProvider(),
        if (ytLyricsFetch != null) YtLyricsProvider(ytLyricsFetch),
      ];

  Future<LyricsResult?> lyricsForQuery(LyricsQuery q,
      {bool force = false}) async {
    final key = '${q.title}|${q.artist}|${q.durationMs ~/ 2000}';
    if (!force && cache != null) {
      final hit = await cache!.get(key);
      if (hit != null) return hit.lyrics;
    }
    final found = await LyricsChain.find(providers, q);
    if (cache != null) await cache!.put(key, found);
    return found;
  }

  Future<LyricsResult?> lyricsForTrack(Track t, {bool force = false}) =>
      lyricsForQuery(LyricsQuery.forTrack(t), force: force);
}

// ---------------------------------------------------------------------------
// Disk cache (Kotlin: LyricsCache)
// ---------------------------------------------------------------------------

class CacheHit {
  final LyricsResult? lyrics;
  const CacheHit(this.lyrics);
}

class _CachedLyrics {
  final LyricsResult? lyrics;
  final int atMs;
  const _CachedLyrics(this.lyrics, this.atMs);
}

/// Disk cache (bounded to [maxFiles]); a miss is cached for a day so a song
/// without lyrics isn't re-asked on every play.
class LyricsCache {
  final Directory dir;
  final int maxFiles;

  LyricsCache(this.dir, {this.maxFiles = 400});

  File _file(String key) {
    final name = sha1.convert(utf8.encode(key)).toString();
    return File('${dir.path}/$name.json');
  }

  Future<int> sizeBytes() async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// Null = no usable entry; a hit wraps the (possibly null) cached lyrics.
  Future<CacheHit?> get(String key) async {
    final f = _file(key);
    if (!await f.exists()) return null;
    _CachedLyrics cached;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      cached = _CachedLyrics(
        LyricsResult.fromJson(j['lyrics'] as Map<String, dynamic>?),
        (j['atMs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
    if (cached.lyrics == null &&
        DateTime.now().millisecondsSinceEpoch - cached.atMs > 86400000) {
      return null;
    }
    try {
      await f.setLastModified(DateTime.now());
    } catch (_) {}
    return CacheHit(cached.lyrics);
  }

  Future<void> put(String key, LyricsResult? lyrics) async {
    try {
      await dir.create(recursive: true);
      await _file(key).writeAsString(jsonEncode({
        'lyrics': lyrics?.toJson(),
        'atMs': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {
      return;
    }
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File) files.add(e);
    }
    if (files.length <= maxFiles) return;
    final stats = <File, DateTime>{};
    for (final f in files) {
      stats[f] = await f.lastModified();
    }
    files.sort((a, b) => stats[a]!.compareTo(stats[b]!));
    for (final f in files.take(files.length - maxFiles)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  Future<void> clear() async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }
}
