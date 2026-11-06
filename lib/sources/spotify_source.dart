// Port of spotify/Spotify.kt (UpZe v1.0.1): Spotify, METADATA ONLY.
//
// Spotify audio cannot be streamed by third-party apps, so exactly like the
// Kotlin this file only reads metadata — playlists and Liked Songs as
// "sp:<id>" tracks — and imported songs play through UpZe's other sources
// via cross-source matching. There is no Spotify MusicSource in the Kotlin
// at all (Settings even filters SPOTIFY out of the source-priority list);
// [SpotifySource] below is a thin adapter in the same spirit:
//   * search() runs the Web API search the Kotlin already uses inside its
//     matcher (findTrackIdWebApi), returning tracks that DO carry their
//     ISRC (external_ids) — the strongest cross-source match key;
//   * resolve() always throws [SourceUnavailableException], mirroring the
//     router's "No playable match for this Spotify song" outcome.
//
// AUTH — verified against the Kotlin: there are NO embedded client
// credentials and no client-credentials flow. The Kotlin (trimmed from
// OpenTune, GPL-3.0) signs in with the user's sp_dc cookie from the
// open.spotify.com web player: it scrapes the web-player bundle for the
// rotating TOTP secret + persisted-query hashes, exchanges cookie + TOTP
// for a web-player access token at /api/token, fetches a client token, and
// talks to the Pathfinder GraphQL endpoint. All of that is ported below,
// including the known-secret / known-hash fallbacks dated 2026-10-24.
//
// Limits forced by Dart's stdlib (same ones the lyrics port records): no
// Unicode Normalizer, so the title/artist folding used for Canvas matching
// keeps accented letters instead of decomposing them; matching is
// unaffected for unaccented text.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';
import 'music_source.dart';

String? _s(Map<String, dynamic>? o, String k) {
  final v = o?[k];
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

Map<String, dynamic>? _o(Map<String, dynamic>? o, String k) {
  final v = o?[k];
  return v is Map ? v.cast<String, dynamic>() : null;
}

Map<String, dynamic>? _asMap(Object? decoded) =>
    decoded is Map ? decoded.cast<String, dynamic>() : null;

Object? _tryJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

Object? _at(Object? e, List<String> keys) {
  var cur = e;
  for (final k in keys) {
    if (cur is Map) {
      cur = cur[k];
    } else {
      return null;
    }
  }
  return cur;
}

List<dynamic> _arrOf(Object? v) => v is List ? v : const [];

int? _msOf(Map<String, dynamic> data) {
  final dur = _o(data, 'trackDuration') ?? _o(data, 'duration');
  final v = dur?['totalMilliseconds'];
  if (v is num) return v.toInt();
  return null;
}

/// The largest image URL from a Spotify "sources"/"images" array.
String? _largest(Object? sources) {
  String? best;
  var bestWidth = -1;
  for (final s in _arrOf(sources)) {
    if (s is! Map) continue;
    final url = s['url'];
    final w = s['width'];
    final width = w is num ? w.toInt() : 0;
    if (url is String && width > bestWidth) {
      best = url;
      bestWidth = width;
    }
  }
  return best;
}

/// Thrown when the sp_dc cookie is not a (longer) signed-in session.
/// Kotlin: SpotifyClient.SignedOut (an IOException).
class SpotifySignedOutException extends SourceUnavailableException {
  SpotifySignedOutException(super.message);
}

/// The web player's rotating TOTP secret (Kotlin: SpotifyClient.Secret).
class SpotifySecret {
  const SpotifySecret({required this.version, required this.codes});

  final int version;
  final List<int> codes;
}

/// A scraped web-player bundle snapshot (Kotlin: SpotifyClient.WebPlayer).
class SpotifyWebPlayerInfo {
  const SpotifyWebPlayerInfo({
    required this.clientVersion,
    required this.secret,
    required this.hashes,
    required this.complete,
    required this.atMs,
  });

  final String clientVersion;
  final SpotifySecret secret;
  final Map<String, String> hashes;
  final bool complete;
  final int atMs;

  Map<String, dynamic> toJson() => {
        'clientVersion': clientVersion,
        'secret': {'version': secret.version, 'codes': secret.codes},
        'hashes': hashes,
        'complete': complete,
        'at': atMs,
      };

  static SpotifyWebPlayerInfo? fromJson(Object? decoded) {
    final m = _asMap(decoded);
    if (m == null) return null;
    final sec = _o(m, 'secret');
    final hashesRaw = _o(m, 'hashes');
    if (sec == null || hashesRaw == null) return null;
    final codes = _arrOf(sec['codes'])
        .map((e) => e is num ? e.toInt() : null)
        .whereType<int>()
        .toList();
    final at = m['at'];
    return SpotifyWebPlayerInfo(
      clientVersion: _s(m, 'clientVersion') ?? '1.2.77.0',
      secret: SpotifySecret(
        version: (sec['version'] as num?)?.toInt() ?? 0,
        codes: codes,
      ),
      hashes: hashesRaw.map(
          (k, v) => MapEntry(k, v is String ? v : '')),
      complete: m['complete'] == true,
      atMs: at is num ? at.toInt() : 0,
    );
  }
}

/// A Spotify playlist row (Kotlin: SpotifyClient.Playlist).
class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    this.owner,
    this.imageUrl,
  });

  final String id;
  final String name;
  final String? owner;
  final String? imageUrl;
}

/// Display name + avatar from /v1/me (Kotlin: SpotifyClient.Profile).
class SpotifyProfile {
  const SpotifyProfile(this.name, this.imageUrl);

  final String? name;
  final String? imageUrl;
}

typedef SpotifyPlaylistPage = ({
  List<SpotifyPlaylist> items,
  int total,
  int raw
});
typedef SpotifyTrackPage = ({List<Track> items, int total, int raw});

class _Access {
  _Access(this.token, this.expiresAtMs, this.clientId, this.cookie);
  final String token;
  final int expiresAtMs;
  final String? clientId;
  final String cookie;
}

class _ClientTok {
  _ClientTok(this.token, this.expiresAtMs);
  final String token;
  final int expiresAtMs;
}

/// A minimal future-chain mutex (the Kotlin uses two Mutexes: one guarding
/// token/web-player state, one serialising every HTTP send).
class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) => fn()).whenComplete(() => done.complete());
  }
}

/// The Spotify metadata client (Kotlin: SpotifyClient). [cacheDir] holds
/// the web-player cache and the persistent device id; null keeps both
/// in-memory only, like the Kotlin's nullable File dir.
class SpotifyClient {
  SpotifyClient({Directory? cacheDir}) : _dir = cacheDir;

  final Directory? _dir;
  final http.Client _http = http.Client();
  final _Mutex _lock = _Mutex();
  final _Mutex _lane = _Mutex();

  SpotifyWebPlayerInfo? _webPlayer;
  _Access? _access;
  _ClientTok? _client;
  final Map<String, String> _canvasCache = {};
  String? _deviceIdCache;

  static const String likedId = 'liked';
  static const String _likedCover =
      'https://misc.scdn.co/liked-songs/liked-songs-640.png';
  static const int _maxItems = 10000;
  static const String _web = 'https://open.spotify.com';
  static const String _pathfinder =
      'https://api-partner.spotify.com/pathfinder/v2/query';
  static const String _clientTokenUrl =
      'https://clienttoken.spotify.com/v1/clienttoken';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Safari/537.36';
  static const int _ttlMs = 12 * 60 * 60 * 1000;

  /// Last hashes known to work (OpenTune, web player script of 2026-10-24);
  /// refreshed from the live script.
  static const Map<String, String> knownHashes = {
    'libraryV3':
        '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455',
    'fetchPlaylist':
        '21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf',
    'fetchLibraryTracks':
        '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240',
    'canvas':
        '575138ab27cd5c1b3e54da54d0a7cc8d85485402de26340c2145f0f6bb5e7a9f',
    'searchTracks':
        'b02683192a98dde7966b5e6655a79eeb62713eab703eda9902c932818dd52751',
  };
  static const SpotifySecret _knownSecret = SpotifySecret(version: 12, codes: [
    107, 81, 49, 57, 67, 93, 87, 81, 69, 67, 40, 93, 48, 50, 46, 91, 94, 113,
    41, 47
  ]);

  void signedOut() {
    _access = null;
    _client = null;
  }

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  // ---- profile ----------------------------------------------------------------

  /// Validates an sp_dc cookie by fetching a web-player token (throws
  /// [SpotifySignedOutException] when the cookie is not a signed-in
  /// session), then best-effort reads the display name and avatar.
  Future<SpotifyProfile> profile(String cookie) async {
    final bearer = await _accessToken(cookie);
    try {
      final r = await _send(() => http.Request(
            'GET',
            Uri.parse('https://api.spotify.com/v1/me'),
          )..headers.addAll({
              'Authorization': 'Bearer ${bearer.token}',
              'Accept': 'application/json',
              'User-Agent': _ua,
            }));
      if (r.code < 200 || r.code >= 300) {
        return const SpotifyProfile(null, null);
      }
      final o = _asMap(_tryJson(r.text));
      if (o == null) return const SpotifyProfile(null, null);
      String? img;
      for (final e in _arrOf(o['images'])) {
        if (e is Map && e['url'] is String) {
          img = e['url'] as String;
          break;
        }
      }
      return SpotifyProfile(_s(o, 'display_name') ?? _s(o, 'id'), img);
    } catch (_) {
      return const SpotifyProfile(null, null);
    }
  }

  // ---- library ------------------------------------------------------------------

  Future<List<SpotifyPlaylist>> playlists(String cookie) async {
    final all = <SpotifyPlaylist>[
      const SpotifyPlaylist(
          id: likedId, name: 'Liked Songs', imageUrl: _likedCover),
    ];
    var offset = 0;
    while (offset < _maxItems) {
      final root = await _query('libraryV3', cookie, {
        'filters': ['Playlists'],
        'order': null,
        'textFilter': '',
        'features': ['LIKED_SONGS', 'YOUR_EPISODES_V2', 'PRERELEASES', 'EVENTS'],
        'limit': 50,
        'offset': offset,
        'flatten': true,
        'expandedFolders': <dynamic>[],
        'folderUri': null,
        'includeFoldersWhenFlattening': false,
      });
      final page = playlistPage(root);
      all.addAll(page.items);
      offset += page.raw;
      if (page.raw == 0 || offset >= page.total) break;
    }
    final seen = <String>{};
    return all.where((p) => seen.add(p.id)).toList();
  }

  /// All songs of a playlist (or Liked Songs) as metadata-only tracks.
  Future<List<Track>> tracks(String cookie, String playlistId) async {
    final all = <Track>[];
    var offset = 0;
    while (offset < _maxItems) {
      final SpotifyTrackPage page;
      if (playlistId == likedId) {
        page = likedPage(await _query('fetchLibraryTracks', cookie,
            {'offset': offset, 'limit': 100}));
      } else {
        page = trackPage(await _query('fetchPlaylist', cookie, {
          'uri': 'spotify:playlist:$playlistId',
          'offset': offset,
          'limit': 100,
          'enableWatchFeedEntrypoint': false,
        }));
      }
      all.addAll(page.items);
      offset += page.raw;
      if (page.raw == 0 || offset >= page.total) break;
    }
    return all;
  }

  // ---- Web API search (the Kotlin's matcher search, promoted for the source) ---

  /// GET /v1/search?type=track with the web-player token. Unlike the
  /// Pathfinder results, these tracks carry their ISRC.
  Future<List<Track>> searchTracks(String cookie, String query,
      {int limit = 20}) async {
    final items = await _webApiSearchItems(cookie, query, limit);
    return items.map(_webApiTrack).whereType<Track>().toList();
  }

  Future<List<Map<String, dynamic>>> _webApiSearchItems(
      String cookie, String query, int limit) async {
    final bearer = await _accessToken(cookie);
    final url = Uri.https('api.spotify.com', '/v1/search',
        {'q': query, 'type': 'track', 'limit': '$limit'});
    final r = await _send(() => http.Request('GET', url)
      ..headers.addAll({
        'Authorization': 'Bearer ${bearer.token}',
        'Accept': 'application/json',
        'User-Agent': _ua,
      }));
    if (r.code < 200 || r.code >= 300) {
      throw SourceUnavailableException('Spotify search answered ${r.code}');
    }
    final o = _asMap(_tryJson(r.text));
    if (o == null) throw SourceUnavailableException('Spotify search: not JSON');
    return _arrOf(_o(o, 'tracks')?['items'])
        .map((e) => e is Map ? e.cast<String, dynamic>() : null)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static Track? _webApiTrack(Map<String, dynamic> o) {
    final id = _s(o, 'id');
    if (id == null) return null;
    final artists = _arrOf(o['artists'])
        .map((a) => a is Map ? _s(a.cast<String, dynamic>(), 'name') : null)
        .whereType<String>()
        .toList();
    final albumObj = _o(o, 'album');
    final dur = o['duration_ms'];
    return Track(
      id: 'sp:$id',
      title: _s(o, 'name') ?? '',
      artist: artists.join(', '),
      album: albumObj == null ? null : _s(albumObj, 'name'),
      durationMs: dur is num ? dur.toInt() : 0,
      artUrl: _largest(albumObj?['images']),
      explicit: o['explicit'] == true,
      isrc: _s(_o(o, 'external_ids'), 'isrc'),
    );
  }

  // ---- Canvas -------------------------------------------------------------------

  /// The Canvas video (mp4 URL) for [t], or null when the song has none.
  /// Spotify songs are looked up directly; any other song is matched first
  /// through the web player's search (then the Web API).
  Future<String?> canvasUrl(String cookie, Track t) async {
    final key = t.id;
    final cached = _canvasCache[key];
    if (cached != null) return cached.isEmpty ? null : cached;
    final id = t.id.startsWith('sp:')
        ? t.nativeId
        : await _findTrackId(cookie, t);
    if (id == null) {
      _canvasCache[key] = '';
      return null;
    }
    // A network/token failure is not "no Canvas": only a real answer is
    // cached, so it retries next time (v2.0.8).
    Map<String, dynamic>? root;
    try {
      root = await _query('canvas', cookie, {'trackUri': 'spotify:track:$id'});
    } catch (_) {
      return null;
    }
    final raw = _at(root, ['data', 'trackUnion', 'canvas', 'url']);
    final url = (raw is String &&
            raw.startsWith('https://') &&
            raw.split('?').first.endsWith('.mp4'))
        ? raw
        : null;
    _canvasCache[key] = url ?? '';
    return url;
  }

  /// OpenTune's matcher: the web player's searchTracks — same title +
  /// artist, length within 4 s — with the Web API search as fallback.
  Future<String?> _findTrackId(String cookie, Track t) async {
    String fold(String x) => x
        .toLowerCase()
        .replaceAll(
            RegExp(r'\(.*?\)|\[.*?]|\s(feat|ft)\..*|\s-\s.*'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final artist0 = t.artist.split(',').first.split('&').first.trim();
    final wantT = fold(t.title);
    final wantA = fold(artist0);
    if (wantT.isNotEmpty) {
      try {
        final root = await _query('searchTracks', cookie, {
          'searchTerm': '${t.title} $artist0',
          'offset': 0,
          'limit': 10,
          'numberOfTopResults': 5,
          'includeAudiobooks': false,
          'includePreReleases': false,
          'includeAuthors': false,
        });
        final items =
            _arrOf(_at(root, ['data', 'searchV2', 'tracksV2', 'items']));
        for (final e in items) {
          final d = _o(_o(e is Map ? e.cast<String, dynamic>() : null, 'item'),
              'data');
          if (d == null) continue;
          final name = fold(_s(d, 'name') ?? '');
          final artists = _arrOf(_o(d, 'artists')?['items'])
              .map((a) => a is Map
                  ? fold(_s(
                          _o(a.cast<String, dynamic>(), 'profile'), 'name') ??
                      '')
                  : '')
              .toList();
          final ms = _msOf(d) ?? 0;
          if (name.isNotEmpty &&
              (name == wantT ||
                  name.startsWith(wantT) ||
                  wantT.startsWith(name)) &&
              (wantA.isEmpty ||
                  artists.any(
                      (a) => a == wantA || a.contains(wantA) || wantA.contains(a))) &&
              (t.durationMs <= 0 ||
                  ms <= 0 ||
                  (ms - t.durationMs).abs() <= 4000)) {
            final uri = _s(d, 'uri');
            if (uri != null && uri.startsWith('spotify:track:')) {
              return uri.split(':').last;
            }
          }
        }
      } catch (_) {
        // fall through to the Web API matcher
      }
    }
    return _findTrackIdWebApi(cookie, t);
  }

  Future<String?> _findTrackIdWebApi(String cookie, Track t) async {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'\(.*?\)|\[.*?]|feat\..*|ft\..*'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    final artist0 = t.artist.split(',').first;
    final queries = <String>[
      if (t.isrc != null) 'isrc:${t.isrc}',
      'track:${t.title} artist:$artist0',
      '${t.title} $artist0',
    ];
    for (final q in queries) {
      final List<Map<String, dynamic>> items;
      try {
        items = await _webApiSearchItems(cookie, q, 5);
      } catch (_) {
        continue;
      }
      final want = norm(t.title);
      final artist = norm(artist0);
      for (final o in items) {
        final name = norm(_s(o, 'name') ?? '');
        final artists = _arrOf(o['artists'])
            .map((a) =>
                a is Map ? norm(_s(a.cast<String, dynamic>(), 'name') ?? '') : '')
            .toList();
        final durRaw = o['duration_ms'];
        final dur = durRaw is num ? durRaw.toInt() : 0;
        final hit = (q.startsWith('isrc:') ||
                ((name.contains(want) || want.contains(name)) &&
                    artists.any(
                        (a) => a.contains(artist) || artist.contains(a)))) &&
            (t.durationMs <= 0 ||
                dur <= 0 ||
                (dur - t.durationMs).abs() < 15000);
        if (hit) return _s(o, 'id');
      }
    }
    return null;
  }

  // ---- parsing (pure) -------------------------------------------------------------

  static SpotifyPlaylistPage playlistPage(Map<String, dynamic> root) {
    final lib = _asMap(_at(root, ['data', 'me', 'libraryV3'])) ??
        (throw SourceUnavailableException("Spotify's library answer was empty"));
    final raw = _arrOf(lib['items']);
    final items = <SpotifyPlaylist>[];
    for (final e in raw) {
      final w = e is Map ? _o(e.cast<String, dynamic>(), 'item') : null;
      final data = _o(w, 'data');
      if (w == null || data == null) continue;
      if (_s(data, '__typename') != 'Playlist') continue;
      final uri = _s(w, '_uri');
      final name = _s(data, 'name');
      if (uri == null || name == null || name.trim().isEmpty) continue;
      final imageItems = _arrOf(_o(data, 'images')?['items']);
      final firstSources = (imageItems.isNotEmpty && imageItems.first is Map)
          ? (imageItems.first as Map)['sources']
          : null;
      items.add(SpotifyPlaylist(
        id: uri.split(':').last,
        name: name,
        owner: _s(_o(_o(data, 'ownerV2'), 'data'), 'name'),
        imageUrl: _largest(firstSources),
      ));
    }
    final total = lib['totalCount'];
    return (
      items: items,
      total: total is num ? total.toInt() : raw.length,
      raw: raw.length
    );
  }

  static SpotifyTrackPage trackPage(Map<String, dynamic> root) {
    final pl = _asMap(_at(root, ['data', 'playlistV2'])) ??
        (throw SourceUnavailableException("Spotify's playlist answer was empty"));
    final content = _o(pl, 'content') ??
        (throw SourceUnavailableException("Spotify's playlist answer had no songs"));
    final raw = _arrOf(content['items']);
    final items = <Track>[];
    for (final e in raw) {
      final data =
          _asMap(_at(e, ['itemV2', 'data']));
      if (data == null) continue;
      final t = _item(data, _s(data, 'uri') ?? _s(data, '_uri'));
      if (t != null) items.add(t);
    }
    final total = content['totalCount'];
    return (
      items: items,
      total: total is num ? total.toInt() : raw.length,
      raw: raw.length
    );
  }

  static SpotifyTrackPage likedPage(Map<String, dynamic> root) {
    final tracks = _asMap(_at(root, ['data', 'me', 'library', 'tracks'])) ??
        (throw SourceUnavailableException("Spotify's liked songs answer was empty"));
    final raw = _arrOf(tracks['items']);
    final items = <Track>[];
    for (final e in raw) {
      final w = (e is Map ? _o(e.cast<String, dynamic>(), 'track') : null);
      if (w == null) continue;
      final data = _o(w, 'data');
      if (data == null) continue;
      final t = _item(data, _s(w, '_uri') ?? _s(data, 'uri'));
      if (t != null) items.add(t);
    }
    final total = tracks['totalCount'];
    return (
      items: items,
      total: total is num ? total.toInt() : raw.length,
      raw: raw.length
    );
  }

  static Track? _item(Map<String, dynamic> data, String? uri) {
    if (uri == null || !uri.startsWith('spotify:track:')) return null;
    final title = _s(data, 'name')?.trim();
    if (title == null || title.isEmpty) return null;
    final artists = <String>[];
    for (final a in _arrOf(_o(data, 'artists')?['items'])) {
      final n = a is Map
          ? _s(_o(a.cast<String, dynamic>(), 'profile'), 'name')?.trim()
          : null;
      if (n != null && n.isNotEmpty) artists.add(n);
    }
    return Track(
      id: 'sp:${uri.split(':').last}',
      title: title,
      artist: artists.join(', '),
      album: _s(_o(data, 'albumOfTrack'), 'name'),
      durationMs: _msOf(data) ?? 0,
      artUrl: _largest(_at(data, ['albumOfTrack', 'coverArt', 'sources'])),
    );
  }

  static List<SpotifySecret> secretsIn(String script) {
    final re =
        RegExp(r"""\{secret:(['"])((?:\\.|(?!\1).)*)\1,version:(\d+)\}""");
    final out = <SpotifySecret>[];
    for (final m in re.allMatches(script)) {
      out.add(SpotifySecret(
        version: int.parse(m.group(3)!),
        codes: unescapeJs(m.group(2)!).codeUnits,
      ));
    }
    out.sort((a, b) => b.version.compareTo(a.version));
    return out;
  }

  static String? queryHashIn(String script, String op) {
    final re = RegExp(
        '["\']${RegExp.escape(op)}["\']\\s*,\\s*["\'](?:query|mutation)["\']\\s*,\\s*["\']([0-9a-f]{64})["\']');
    return re.firstMatch(script)?.group(1);
  }

  static String unescapeJs(String body) {
    return body.replaceAllMapped(
      RegExp(r'\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|[\s\S])'),
      (m) {
        final e = m.group(1)!;
        if (e.startsWith('u') && e.length > 1) {
          final hex = e.substring(1).replaceAll('{', '').replaceAll('}', '');
          return String.fromCharCode(int.parse(hex, radix: 16));
        }
        if (e.startsWith('x') && e.length == 3) {
          return String.fromCharCode(int.parse(e.substring(1), radix: 16));
        }
        return switch (e) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          '0' => '\u0000',
          _ => e,
        };
      },
    );
  }

  /// TOTP over SHA-1, 30 s steps, key = secret codes XOR their position
  /// (the web player's scheme).
  static String totp(List<int> codes, int epochMs) {
    final key = codes
        .asMap()
        .entries
        .map((e) => e.value ^ ((e.key % 33) + 9))
        .join('')
        .codeUnits;
    final counter = ByteData(8)..setInt64(0, epochMs ~/ 1000 ~/ 30);
    final h = Hmac(sha1, key).convert(counter.buffer.asUint8List()).bytes;
    final o = h.last & 0x0f;
    final bin = ((h[o] & 0x7f) << 24) |
        ((h[o + 1] & 0xff) << 16) |
        ((h[o + 2] & 0xff) << 8) |
        (h[o + 3] & 0xff);
    return (bin % 1000000).toString().padLeft(6, '0');
  }

  // ---- network --------------------------------------------------------------------

  /// Every send goes through one lane (the Kotlin's `lane` Mutex), with up
  /// to 2 retries on 429 honouring Retry-After (clamped 1–30 s).
  Future<({int code, String text, String? retryAfter})> _send(
      http.Request Function() make) {
    return _lane.run(() async {
      var tries = 0;
      while (true) {
        final resp =
            await http.Response.fromStream(await _http.send(make()));
        if (resp.statusCode != 429 || tries++ >= 2) {
          return (
            code: resp.statusCode,
            text: resp.body,
            retryAfter: resp.headers['retry-after']
          );
        }
        final secs = int.tryParse(resp.headers['retry-after'] ?? '') ?? 5;
        await Future<void>.delayed(
            Duration(milliseconds: (secs * 1000).clamp(1000, 30000)));
      }
    });
  }

  Future<Map<String, dynamic>> _query(
      String op, String cookie, Map<String, dynamic> variables,
      {bool retried = false}) async {
    final bearer = await _accessToken(cookie);
    final player = await _lock.run(() => _readWebPlayer(false));
    final ct = await _clientToken(bearer, player);
    final hash = player.hashes[op] ?? knownHashes[op] ??
        (throw SourceUnavailableException('No persisted-query hash for $op'));
    final body = jsonEncode({
      'variables': variables,
      'operationName': op,
      'extensions': {
        'persistedQuery': {'version': 1, 'sha256Hash': hash}
      },
    });
    final r = await _send(() => http.Request('POST', Uri.parse(_pathfinder))
      ..headers.addAll({
        'Authorization': 'Bearer ${bearer.token}',
        'Accept': 'application/json',
        'App-Platform': 'WebPlayer',
        'Origin': _web,
        'Referer': '$_web/',
        'User-Agent': _ua,
        if (ct != null) 'Client-Token': ct,
        'Content-Type': 'application/json;charset=UTF-8',
      })
      ..body = body);
    if (r.code == 401 && !retried) {
      _access = null;
      _client = null;
      return _query(op, cookie, variables, retried: true);
    }
    final root = _asMap(_tryJson(r.text));
    final errors = _arrOf(root?['errors'])
        .map((e) => e is Map ? _s(e.cast<String, dynamic>(), 'message') : null)
        .whereType<String>()
        .toList();
    if (errors.any((e) => e.toLowerCase().contains('persistedquerynotfound')) &&
        !retried) {
      await _lock.run(() {
        _webPlayer = null;
        return _readWebPlayer(true);
      });
      return _query(op, cookie, variables, retried: true);
    }
    if (r.code < 200 || r.code >= 300) {
      throw SourceUnavailableException('Spotify $op answered ${r.code}');
    }
    return root ?? (throw SourceUnavailableException('Spotify $op: not JSON'));
  }

  Future<_Access> _accessToken(String cookie) {
    return _lock.run(() async {
      final cached = _access;
      if (cached != null &&
          cached.cookie == cookie &&
          _nowMs < cached.expiresAtMs - 30000) {
        return cached;
      }
      for (final force in [false, true]) {
        final player = await _readWebPlayer(force);
        final totpCode = totp(player.secret.codes, _nowMs);
        final url = Uri.parse('$_web/api/token').replace(queryParameters: {
          'reason': 'init',
          'productType': 'web-player',
          'totp': totpCode,
          'totpServer': totpCode,
          'totpVer': '${player.secret.version}',
        });
        final r = await _send(() => http.Request('GET', url)
          ..headers.addAll({
            'Cookie': 'sp_dc=$cookie',
            'User-Agent': _ua,
            'Accept': 'application/json',
            'Referer': '$_web/',
          }));
        final body = _asMap(_tryJson(r.text));
        if (body != null && body.containsKey('totpVerExpired') && !force) {
          continue;
        }
        if (r.code == 401) {
          throw SpotifySignedOutException('Your Spotify sign-in has expired');
        }
        if (body?['isAnonymous'] == true) {
          throw SpotifySignedOutException('Not signed in to Spotify');
        }
        final token = body == null ? null : _s(body, 'accessToken');
        if (token != null) {
          final expRaw = body?['accessTokenExpirationTimestampMs'];
          final access = _Access(
            token,
            expRaw is num ? expRaw.toInt() : _nowMs + 3600000,
            _s(body, 'clientId'),
            cookie,
          );
          _access = access;
          return access;
        }
      }
      throw SourceUnavailableException("Spotify wouldn't give a token");
    });
  }

  Future<String?> _clientToken(
      _Access bearer, SpotifyWebPlayerInfo player) async {
    final cached = _client;
    if (cached != null && _nowMs < cached.expiresAtMs - 30000) {
      return cached.token;
    }
    final clientId = bearer.clientId;
    if (clientId == null) return null;
    final body = jsonEncode({
      'client_data': {
        'client_version': player.clientVersion,
        'client_id': clientId,
        'js_sdk_data': {
          'device_brand': 'unknown',
          'device_model': 'unknown',
          'os': 'windows',
          'os_version': 'unknown',
          'device_id': await _deviceId(),
          'device_type': 'computer',
        },
      },
    });
    try {
      final r = await _send(() =>
          http.Request('POST', Uri.parse(_clientTokenUrl))
            ..headers.addAll({
              'Accept': 'application/json',
              'User-Agent': _ua,
              'Content-Type': 'application/json',
            })
            ..body = body);
      final root = _asMap(_tryJson(r.text));
      if (root == null || _s(root, 'response_type') != 'RESPONSE_GRANTED_TOKEN_RESPONSE') {
        return null;
      }
      final g = _o(root, 'granted_token');
      final t = g == null ? null : _s(g, 'token');
      if (t == null) return null;
      final expRaw = g?['expires_after_seconds'];
      _client = _ClientTok(
          t, _nowMs + (expRaw is num ? expRaw.toInt() : 3600) * 1000);
      return t;
    } catch (_) {
      return null;
    }
  }

  Future<String> _deviceId() async {
    final cachedId = _deviceIdCache;
    if (cachedId != null) return cachedId;
    final dir = _dir;
    final f = dir == null ? null : File('${dir.path}/spotify-device-id');
    if (f != null && await f.exists()) {
      final v = (await f.readAsString()).trim();
      if (v.length == 32) return _deviceIdCache = v;
    }
    final rnd = Random.secure();
    final id = List<int>.generate(16, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    _deviceIdCache = id;
    if (f != null) {
      try {
        await f.writeAsString(id);
      } catch (_) {
        // best effort, like the Kotlin's runCatching
      }
    }
    return id;
  }

  Future<String?> _text(String url) async {
    try {
      final r = await _send(() => http.Request('GET', Uri.parse(url))
        ..headers['User-Agent'] = _ua);
      return (r.code >= 200 && r.code < 300) ? r.text : null;
    } catch (_) {
      return null;
    }
  }

  /// Reads (or refreshes) the web-player snapshot. Callers hold [_lock] on
  /// the paths where the Kotlin did.
  Future<SpotifyWebPlayerInfo> _readWebPlayer(bool force) async {
    final dir = _dir;
    final file =
        dir == null ? null : File('${dir.path}/spotify-web-player.json');
    if (!force) {
      var cached = _webPlayer;
      if (cached == null && file != null && await file.exists()) {
        try {
          cached =
              SpotifyWebPlayerInfo.fromJson(_tryJson(await file.readAsString()));
        } catch (_) {
          cached = null;
        }
      }
      if (cached != null && _nowMs - cached.atMs < _ttlMs) {
        _webPlayer = cached;
        return cached;
      }
    }
    final html = await _text('$_web/') ?? '';
    String? version;
    final cfg = RegExp(r'<script id="appServerConfig" type="text/plain">([^<]+)</script>')
        .firstMatch(html)
        ?.group(1);
    if (cfg != null) {
      try {
        version =
            _s(_asMap(_tryJson(utf8.decode(base64Decode(cfg)))),
                'clientVersion');
      } catch (_) {
        version = null;
      }
    }
    final bundleUrl = RegExp(
            r'https://open\.spotifycdn\.com/cdn/build/web-player/web-player\.[0-9a-f]+\.js')
        .firstMatch(html)
        ?.group(0);
    final bundle = bundleUrl == null ? '' : await _text(bundleUrl) ?? '';
    final secrets = secretsIn(bundle);
    final secret = secrets.isEmpty ? null : secrets.first;
    final found = <String, String?>{
      for (final op in knownHashes.keys) op: queryHashIn(bundle, op),
    };
    final read = SpotifyWebPlayerInfo(
      clientVersion: version ?? '1.2.77.0',
      secret: secret ?? _knownSecret,
      hashes: {
        for (final op in knownHashes.keys)
          op: found[op] ?? knownHashes[op]!,
      },
      complete:
          secret != null && version != null && found.values.every((v) => v != null),
      atMs: _nowMs,
    );
    _webPlayer = read;
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode(read.toJson()));
      } catch (_) {
        // best effort
      }
    }
    return read;
  }
}

/// The MusicSource-shaped adapter over [SpotifyClient] (see the file
/// header for why the Kotlin has no such class and what is mirrored).
/// Config is the sp_dc cookie + enabled flag via callbacks — the cookie
/// lives in the account store (Account service SPOTIFY, secret = sp_dc),
/// exactly where Sessions.kt/Sync.kt read it in the Kotlin.
class SpotifySource implements MusicSource {
  SpotifySource({
    required String? Function() cookie,
    required bool Function() enabled,
    SpotifyClient? client,
  })  : _cookie = cookie,
        _enabled = enabled,
        client = client ?? SpotifyClient();

  final String? Function() _cookie;
  final bool Function() _enabled;

  /// The metadata client, exposed for the library-import (Sync) wiring.
  final SpotifyClient client;

  @override
  SourceKind get kind => SourceKind.spotify;

  @override
  bool available() {
    final c = _cookie();
    return _enabled() && c != null && c.isNotEmpty;
  }

  String _requireCookie() =>
      _cookie() ?? (throw SourceUnavailableException('Not signed in to Spotify'));

  /// Web API search; results carry ISRC for cross-source matching.
  @override
  Future<List<Track>> search(String query, [int limit = 20]) =>
      client.searchTracks(_requireCookie(), query, limit: limit);

  /// Spotify cannot be streamed by third-party apps — the Kotlin router
  /// answers an unmatched Spotify track with "No playable match for this
  /// Spotify song on your enabled sources"; this mirrors that outcome.
  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) {
    throw SourceUnavailableException(
        'No playable match for this Spotify song on your enabled sources');
  }

  @override
  Future<String> probe() async {
    final c = _cookie() ??
        (throw SourceUnavailableException('not configured'));
    final p = await client.profile(c);
    return p.name != null ? 'Signed in as ${p.name}' : 'Signed in to Spotify';
  }

  // ---- library import surface (account/Sync.kt's calls) ----------------------

  Future<List<SpotifyPlaylist>> playlists() => client.playlists(_requireCookie());

  Future<List<Track>> playlistTracks(String playlistId) =>
      client.tracks(_requireCookie(), playlistId);

  /// Canvas lookup for any track (ui/player/Canvas.kt's call); null when
  /// signed out or the song has no Canvas.
  Future<String?> canvasUrl(Track t) async {
    final c = _cookie();
    if (c == null) return null;
    return client.canvasUrl(c, t);
  }

  void signedOut() => client.signedOut();
}
