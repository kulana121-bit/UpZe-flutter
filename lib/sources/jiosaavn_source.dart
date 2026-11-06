// Port of source/JioSaavn.kt (UpZe v1.0.1).
//
// JioSaavn public catalog/CDN protocol. Endpoints and the media-URL decoding
// follow OpenTune 1.0.4 data/lossless/JioSaavnSource.kt (itself adapted from
// BitChord), GPL-3.0-or-later. 320 kbps AAC, not lossless.
//
// DES choice: the Kotlin original uses javax.crypto DES/ECB/PKCS5Padding.
// The Dart `encrypt` package (already in pubspec) does not expose DES
// through its public Encrypter API, so the decrypt is implemented here in
// pure Dart (_Des below, FIPS 46-3) — no native code, no extra dependency,
// and verifiable against the standard DES test vectors. Key handling,
// base64 input and PKCS#5 unpadding mirror the Kotlin exactly.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/track.dart';
import 'music_source.dart';
import 'source_manager.dart' show TrackMatcher;

String? _jstr(Map<String, dynamic>? o, String k) {
  final v = o?[k];
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

Map<String, dynamic>? _jobj(Map<String, dynamic>? o, String k) {
  final v = o?[k];
  return v is Map ? v.cast<String, dynamic>() : null;
}

List<dynamic> _jarr(Map<String, dynamic>? o, String k) {
  final v = o?[k];
  return v is List ? v : const [];
}

class JioSaavnSource implements MusicSource {
  JioSaavnSource({required bool Function() enabled}) : _enabled = enabled;

  final bool Function() _enabled;

  @override
  SourceKind get kind => SourceKind.jiosaavn;

  @override
  bool available() => _enabled();

  /// Every call runs with a 10 s whole-call budget (the Kotlin client is
  /// tuned connect 5 s / read 8 s / call 10 s) and optionally logs its
  /// status + latency (search/reco only, to keep the log short).
  Future<Object?> _call(
    String method, {
    Map<String, String> params = const {},
    String ctx = 'android',
    bool log = false,
  }) async {
    final uri = Uri.parse(api).replace(queryParameters: {
      '__call': method,
      '_format': 'json',
      '_marker': '0',
      'ctx': ctx,
      'api_version': '4',
      ...params,
    });
    final sw = Stopwatch()..start();
    final String body;
    try {
      final resp = await http
          .get(uri, headers: {'User-Agent': browserUa})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        throw SourceUnavailableException(
            'JioSaavn $method: HTTP ${resp.statusCode}');
      }
      body = resp.body;
    } catch (e) {
      if (log) {
        logSource('JioSaavn $method: ${e.runtimeType} '
            'after ${sw.elapsedMilliseconds} ms');
      }
      rethrow;
    }
    if (log) {
      final q = params['q'] ?? params['query'];
      logSource('JioSaavn $method${q != null ? ' "${q.length > 40 ? q.substring(0, 40) : q}"' : ''}: '
          'HTTP 200 in ${sw.elapsedMilliseconds} ms');
    }
    // JioSaavn sometimes answers 200 with an HTML/garbage page; surface it
    // as a SourceUnavailableException, not a FormatException.
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SourceUnavailableException('JioSaavn $method: invalid JSON', e);
    }
  }

  /// search.getResults; when it has not answered within [fallbackAfter]
  /// (or fails), autocomplete.get (web context) is raced against it and the
  /// first non-empty answer wins.
  @override
  Future<List<Track>> search(String query, [int limit = 20]) async {
    List<Track>? pRes;
    Object? pErr;
    var pDone = false;
    final pFuture = () async {
      try {
        pRes = await _searchResults(query, limit);
      } catch (e) {
        pErr = e;
      } finally {
        pDone = true;
      }
    }();
    final sw = Stopwatch()..start();
    while (!pDone && sw.elapsed < fallbackAfter) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (pDone && pErr == null && (pRes?.isNotEmpty ?? false)) return pRes!;
    List<Track>? fRes;
    Object? fErr;
    var fDone = false;
    final fFuture = () async {
      try {
        fRes = await autocomplete(query, limit);
      } catch (e) {
        fErr = e;
      } finally {
        fDone = true;
      }
    }();
    while (true) {
      if (pDone && (pRes?.isNotEmpty ?? false)) {
        unawaited(fFuture);
        return pRes!;
      }
      if (fDone && (fRes?.isNotEmpty ?? false)) {
        unawaited(pFuture);
        return fRes!;
      }
      if (pDone && fDone) {
        final r = pRes ?? fRes;
        if (r != null) return r;
        throw (pErr ?? fErr)!;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<List<Track>> _searchResults(String query, int limit) async {
    final root = await _call(
      'search.getResults',
      params: {'q': query, 'n': '$limit', 'p': '1'},
      log: true,
    );
    if (root is! Map) return const [];
    return _jarr(root.cast<String, dynamic>(), 'results')
        .whereType<Map>()
        .map((e) => toTrack(e.cast<String, dynamic>()))
        .whereType<Track>()
        .toList();
  }

  /// autocomplete.get (ctx web6dot0): songs.data with id/title/album/image
  /// and more_info.primary_artists as text.
  Future<List<Track>> autocomplete(String query, int limit) async {
    final root = await _call(
      'autocomplete.get',
      params: {'query': query},
      ctx: 'web6dot0',
      log: true,
    );
    if (root is! Map) return const [];
    return parseAutocomplete(root.cast<String, dynamic>()).take(limit).toList();
  }

  List<Track> parseAutocomplete(Map<String, dynamic> root) {
    final data = _jarr(_jobj(root, 'songs'), 'data');
    final out = <Track>[];
    for (final e in data) {
      if (e is! Map) continue;
      final o = e.cast<String, dynamic>();
      final id = _jstr(o, 'id');
      if (id == null || !_idRe.hasMatch(id)) continue;
      final type = _jstr(o, 'type');
      if (type != null && type != 'song') continue;
      var artists = _jstr(_jobj(o, 'more_info'), 'primary_artists');
      if (artists == null || artists.isEmpty) {
        final desc = _jstr(o, 'description') ?? '';
        final idx = desc.indexOf(' · ');
        artists = idx >= 0 ? desc.substring(idx + 3) : '';
      }
      out.add(Track(
        id: 'js:$id',
        title: unescapeHtml(_jstr(o, 'title')),
        artist: unescapeHtml(artists),
        album: _jstr(o, 'album')?.let(unescapeHtml),
        durationMs: 0,
        artUrl: hiRes(_jstr(o, 'image')),
      ));
    }
    return out;
  }

  /// Autoplay fallback: JioSaavn's song recommendations (reco.getreco) for
  /// [seed]. A non-JioSaavn seed is first matched on JioSaavn by title +
  /// artist.
  Future<List<Track>> recommendationsFor(Track seed) async {
    final String pid;
    if (seed.source == SourceKind.jiosaavn) {
      pid = seed.nativeId;
    } else {
      final q = TrackMatcher.searchQueries(seed).firstOrNull ??
          '${seed.title} ${seed.artist}';
      final match = TrackMatcher.best(seed, await search(q, 10),
          threshold: TrackMatcher.lenientThreshold, lenient: true);
      if (match == null) return const [];
      pid = match.nativeId;
    }
    final root = await _call('reco.getreco', params: {'pid': pid}, log: true);
    final List<dynamic> arr;
    if (root is Map) {
      final byPid = root.cast<String, dynamic>()[pid];
      arr = byPid is List ? byPid : const [];
    } else if (root is List) {
      arr = root;
    } else {
      return const [];
    }
    return arr
        .whereType<Map>()
        .map((e) => toTrack(e.cast<String, dynamic>()))
        .whereType<Track>()
        .toList();
  }

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final id = track.nativeId;
    final root = await _call('song.getDetails', params: {'pids': id});
    if (root is! Map) throw SourceUnavailableException('JioSaavn: no details');
    final details = root.cast<String, dynamic>();
    var song = _jobj(details, id);
    if (song == null) {
      final songs = _jarr(details, 'songs');
      if (songs.isNotEmpty && songs.first is Map) {
        song = (songs.first as Map).cast<String, dynamic>();
      }
    }
    if (song == null) {
      throw SourceUnavailableException('JioSaavn: track not found');
    }
    final info = _jobj(song, 'more_info');
    if (info == null) {
      throw SourceUnavailableException('JioSaavn: no media info');
    }
    final enc = _jstr(info, 'encrypted_media_url');
    if (enc == null) {
      throw SourceUnavailableException('JioSaavn: no media url');
    }
    // Bad base64 / DES padding must surface as SourceUnavailableException,
    // not leak past the IO-style handlers.
    final String decoded;
    try {
      decoded = decodeMediaUrl(enc);
    } catch (e) {
      throw SourceUnavailableException('JioSaavn: undecodable media url', e);
    }
    final has320 = (_jstr(info, '320kbps') ?? '').toLowerCase() == 'true';
    // Always the 320 kbps rendition when the catalogue has one; 160
    // otherwise.
    final kbps = has320 ? 320 : 160;
    final url = rendition(decoded, kbps);
    if (url == null) {
      throw SourceUnavailableException('JioSaavn: unexpected media url');
    }
    return Resolved(
      uri: url,
      info: StreamInfo(
        source: kind,
        codec: 'AAC',
        bitrateKbps: kbps,
        sampleRateHz: 44100,
        sourceTrackId: track.id,
      ),
      headers: const {'User-Agent': browserUa},
      cacheKey: 'js:$id@$kbps',
    );
  }

  @override
  Future<String> probe() async => '${(await search('arijit', 3)).length} results';

  Track? toTrack(Map<String, dynamic> o) {
    final id = _jstr(o, 'id');
    if (id == null || !_idRe.hasMatch(id)) return null;
    final type = _jstr(o, 'type');
    if (type != null && type != 'song') return null;
    final info = _jobj(o, 'more_info');
    final primary = _jarr(_jobj(info, 'artistMap'), 'primary_artists')
        .whereType<Map>()
        .map((a) => _jstr(a.cast<String, dynamic>(), 'name'))
        .whereType<String>()
        .map(unescapeHtml)
        .toList();
    var artist = primary.join(', ');
    if (artist.isEmpty) {
      final sub = _jstr(o, 'subtitle') ?? '';
      final cut = sub.indexOf(' - ');
      artist = unescapeHtml(cut >= 0 ? sub.substring(0, cut) : sub);
    }
    return Track(
      id: 'js:$id',
      title: unescapeHtml(_jstr(o, 'title')),
      artist: artist,
      album: _jstr(info, 'album')?.let(unescapeHtml),
      durationMs: (int.tryParse(_jstr(info, 'duration') ?? '') ?? 0) * 1000,
      artUrl: hiRes(_jstr(o, 'image')),
      albumId: _jstr(info, 'album_id')?.let((a) => 'js:al:$a'),
      explicit: _jstr(o, 'explicit_content') == '1',
      year: _jstr(o, 'year'),
      bitrateKbps:
          (_jstr(info, '320kbps') ?? '').toLowerCase() == 'true' ? 320 : 160,
    );
  }

  static const String api = 'https://www.jiosaavn.com/api.php';

  /// Race autocomplete.get against search.getResults after this long.
  static const Duration fallbackAfter = Duration(milliseconds: 4000);

  static final RegExp _idRe = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _renditionRe =
      RegExp(r'_(12|48|96|160|320)\.mp4$', caseSensitive: false);

  static String? hiRes(String? url) => url
      ?.replaceFirst('http://', 'https://')
      .replaceAll(RegExp(r'(\d+)x(\d+)'), '500x500');

  /// DES-ECB with JioSaavn's public key, as their web player does.
  static String decodeMediaUrl(String enc) {
    final key = Uint8List.fromList(utf8.encode('38346591'));
    final cipherBytes = base64Decode(enc.trim());
    final plain = _Des.decryptEcb(key, cipherBytes);
    return utf8.decode(_pkcs5Unpad(plain)).trim();
  }

  /// Only https saavncdn.com URLs; swaps in the requested rendition
  /// (the `_320.mp4` / `_160.mp4` upgrade).
  static String? rendition(String decoded, int kbps) {
    final url = decoded.replaceFirst(RegExp(r'^http://'), 'https://');
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      return null;
    }
    if (uri.scheme != 'https') return null;
    if (uri.host != 'saavncdn.com' && !uri.host.endsWith('.saavncdn.com')) {
      return null;
    }
    if (!_renditionRe.hasMatch(uri.path)) return null;
    return url.replaceFirst(_renditionRe, '_$kbps.mp4');
  }

  static Uint8List _pkcs5Unpad(Uint8List data) {
    if (data.isEmpty || data.length % 8 != 0) {
      throw const FormatException('DES: bad padded length');
    }
    final pad = data.last;
    if (pad < 1 || pad > 8) {
      throw const FormatException('DES: bad PKCS5 padding');
    }
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) {
        throw const FormatException('DES: bad PKCS5 padding');
      }
    }
    return Uint8List.sublistView(data, 0, data.length - pad);
  }
}

extension<T> on T {
  R let<R>(R Function(T value) f) => f(this);
}

// ---------------------------------------------------------------------------
// DES (FIPS 46-3), ECB decrypt only — pure Dart port of the
// javax.crypto "DES/ECB/PKCS5Padding" decrypt JioSaavn.kt relies on.
// ---------------------------------------------------------------------------

class _Des {
  static const List<int> _ip = [
    58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
  ];
  static const List<int> _fp = [
    40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
  ];
  static const List<int> _e = [
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9,
    8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
  ];
  static const List<int> _p = [
    16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
    2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
  ];
  static const List<int> _pc1 = [
    57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
    10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
    14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
  ];
  static const List<int> _pc2 = [
    14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10,
    23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
    41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
  ];
  static const List<int> _rotations = [
    1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1,
  ];
  static const List<List<int>> _sBoxes = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
  ];

  static int _permute(int value, List<int> table, int inBits) {
    var out = 0;
    for (final pos in table) {
      out = (out << 1) | ((value >> (inBits - pos)) & 1);
    }
    return out;
  }

  static List<int> _subkeys(int key) {
    final cd = _permute(key, _pc1, 64);
    var c = (cd >> 28) & 0x0FFFFFFF;
    var d = cd & 0x0FFFFFFF;
    final keys = <int>[];
    for (final rot in _rotations) {
      c = ((c << rot) | (c >> (28 - rot))) & 0x0FFFFFFF;
      d = ((d << rot) | (d >> (28 - rot))) & 0x0FFFFFFF;
      keys.add(_permute((c << 28) | d, _pc2, 56));
    }
    return keys;
  }

  static int _f(int r, int k) {
    final x = _permute(r, _e, 32) ^ k;
    var out = 0;
    for (var i = 0; i < 8; i++) {
      final six = (x >> (42 - 6 * i)) & 0x3F;
      final row = ((six & 0x20) >> 4) | (six & 0x01);
      final col = (six >> 1) & 0x0F;
      out = (out << 4) | _sBoxes[i][row * 16 + col];
    }
    return _permute(out, _p, 32);
  }

  static int _cryptBlock(int block, List<int> subkeys) {
    final v = _permute(block, _ip, 64);
    var l = (v >> 32) & 0xFFFFFFFF;
    var r = v & 0xFFFFFFFF;
    for (final k in subkeys) {
      final next = l ^ _f(r, k);
      l = r;
      r = next;
    }
    // Final swap, then the inverse initial permutation.
    return _permute((r << 32) | l, _fp, 64);
  }

  static int _bytesToInt(Uint8List b, int offset) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[offset + i];
    }
    return v;
  }

  static void _intToBytes(int v, Uint8List out, int offset) {
    for (var i = 7; i >= 0; i--) {
      out[offset + i] = v & 0xFF;
      v >>= 8;
    }
  }

  /// ECB decrypt of [data] (length must be a multiple of 8) under the
  /// 8-byte [key]. Padding is the caller's job (PKCS#5).
  static Uint8List decryptEcb(Uint8List key, Uint8List data) {
    if (key.length != 8 || data.length % 8 != 0) {
      throw const FormatException('DES: bad key or data length');
    }
    final subkeys = _subkeys(_bytesToInt(key, 0)).reversed.toList();
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += 8) {
      _intToBytes(_cryptBlock(_bytesToInt(data, off), subkeys), out, off);
    }
    return out;
  }
}
