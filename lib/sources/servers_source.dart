// Port of source/Servers.kt (UpZe v1.0.1): the user's own music servers.
//
//  * SubsonicSource — Subsonic API (Navidrome, Airsonic, Gonic…), salt+token
//    MD5 auth with a fresh random salt on every request. Lossless:
//    stream.view?format=raw sends the original file untouched.
//  * JellyfinSource — username/password login returns an access token;
//    requests carry the X-Emby-Authorization / Authorization headers exactly
//    as the Kotlin builds them. Lossless: /Audio/{id}/stream?static=true.
//
// Config mirrors the Kotlin wiring in App.kt, where each source receives
// `account: () -> Account?` + `enabled: () -> Boolean` lambdas over the
// encrypted AccountStore. Account has no Dart port yet, so the callbacks
// here return the small config records below, carrying exactly the Account
// fields the Kotlin reads:
//   Subsonic: extra = server base URL, name = user, secret = password.
//   Jellyfin: extra = "<server>|<userId>", secret = access token.
// Settings.kt / settings_store.dart hold no server fields (accounts live in
// the separate store), so constructor callbacks are the faithful seam.
//
// Server addresses are HTTPS-only, exactly like the Kotlin serverBase():
// an http:// address is refused, never silently tried.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';
import 'music_source.dart';
import 'source_manager.dart' show QualityEstimate;

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

int? _l(Map<String, dynamic>? o, String k) {
  final v = o?[k];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

List<dynamic> _arr(Map<String, dynamic>? o, String k) {
  final v = o?[k];
  return v is List ? v : const [];
}

Map<String, dynamic>? _asMap(Object? decoded) =>
    decoded is Map ? decoded.cast<String, dynamic>() : null;

/// Normalises a server address (Kotlin: serverBase). HTTPS only — an
/// http:// input throws [ArgumentError], like the Kotlin `require`.
Uri serverBase(String input) {
  var t = input.trim();
  while (t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  if (t.toLowerCase().startsWith('http://')) {
    throw ArgumentError('Only https:// servers are supported');
  }
  final url =
      Uri.parse(t.toLowerCase().startsWith('https://') ? t : 'https://$t');
  if (url.scheme != 'https' || url.host.isEmpty) {
    throw ArgumentError('Only https:// servers are supported');
  }
  return url;
}

/// [base] + extra path [segments] (appended after any path prefix the base
/// already carries, like OkHttp's addPathSegments) + [query].
Uri _build(Uri base, List<String> segments, [Map<String, String>? query]) {
  return base.replace(
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ...segments,
    ],
    queryParameters: query,
  );
}

/// What the Subsonic source needs from the account store (Kotlin Account:
/// name = user, secret = password, extra = server base URL).
class SubsonicConfig {
  const SubsonicConfig({
    required this.baseUrl,
    required this.user,
    required this.password,
  });

  final String baseUrl;
  final String user;
  final String password;
}

/// Subsonic API (Navidrome, Airsonic, Gonic…). Token auth with a fresh
/// random salt on every request.
class SubsonicSource implements MusicSource {
  SubsonicSource({
    required SubsonicConfig? Function() config,
    required bool Function() enabled,
  })  : _config = config,
        _enabled = enabled;

  final SubsonicConfig? Function() _config;
  final bool Function() _enabled;
  final Random _rnd = Random.secure();

  @override
  SourceKind get kind => SourceKind.subsonic;

  @override
  bool available() => _enabled() && _config() != null;

  String _url(SubsonicConfig acct, String method,
      [Map<String, String> params = const {}]) {
    // Kotlin: 8 random bytes as hex salt; token = md5(password + salt) hex.
    final salt = List<int>.generate(8, (_) => _rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final token = md5.convert(utf8.encode('${acct.password}$salt')).toString();
    return _build(serverBase(acct.baseUrl), ['rest', method], {
      'u': acct.user,
      't': token,
      's': salt,
      'v': '1.16.1',
      'c': 'UpZe',
      'f': 'json',
      ...params,
    }).toString();
  }

  Future<Map<String, dynamic>> _call(String method,
      [Map<String, String> params = const {}, SubsonicConfig? acct]) async {
    final a =
        acct ?? _config() ?? (throw SourceUnavailableException('No Subsonic server'));
    final o = _asMap(await getJson(_url(a, method, params)));
    final r = _o(o, 'subsonic-response') ??
        (throw SourceUnavailableException('Not a Subsonic server'));
    if (_s(r, 'status') != 'ok') {
      throw SourceUnavailableException(
          'Subsonic: ${_s(_o(r, 'error'), 'message') ?? 'error'}');
    }
    return r;
  }

  /// Connection test (Kotlin: test). Returns 'OK' on a good ping.
  Future<String> test(SubsonicConfig acct) async {
    await _call('ping', const {}, acct);
    return 'OK';
  }

  @override
  Future<List<Track>> search(String query, [int limit = 20]) async {
    final r = await _call('search3', {
      'query': query,
      'songCount': '$limit',
      'albumCount': '0',
      'artistCount': '0',
    });
    final songs = _arr(_o(r, 'searchResult3'), 'song');
    return songs
        .map((e) => e is Map ? _toTrack(e.cast<String, dynamic>()) : null)
        .whereType<Track>()
        .toList();
  }

  Future<List<Track>> randomSongs([int n = 30]) async {
    final r = await _call('getRandomSongs', {'size': '$n'});
    final songs = _arr(_o(r, 'randomSongs'), 'song');
    return songs
        .map((e) => e is Map ? _toTrack(e.cast<String, dynamic>()) : null)
        .whereType<Track>()
        .toList();
  }

  Track? _toTrack(Map<String, dynamic> o) {
    final id = _s(o, 'id');
    if (id == null) return null;
    final coverArt = _s(o, 'coverArt');
    String? artUrl;
    if (coverArt != null) {
      // The Kotlin wraps this in runCatching: a bad server address just
      // loses the artwork instead of failing the track.
      try {
        final acct = _config();
        if (acct != null) {
          artUrl = _url(acct, 'getCoverArt', {'id': coverArt, 'size': '600'});
        }
      } catch (_) {
        artUrl = null;
      }
    }
    return Track(
      id: 'sub:$id',
      title: _s(o, 'title') ?? '',
      artist: _s(o, 'artist') ?? '',
      album: _s(o, 'album'),
      durationMs: (_l(o, 'duration') ?? 0) * 1000,
      artUrl: artUrl,
      year: _s(o, 'year'),
      format: _s(o, 'suffix'),
      bitrateKbps: _l(o, 'bitRate'),
    );
  }

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final acct =
        _config() ?? (throw SourceUnavailableException('No Subsonic server'));
    final lossless =
        quality == Quality.lossless || (quality == Quality.max && !metered);
    final u = _url(
      acct,
      'stream',
      lossless
          ? {'id': track.nativeId, 'format': 'raw'}
          : {'id': track.nativeId, 'maxBitRate': '320'},
    );
    final codec = lossless
        ? track.format?.toUpperCase()
        : (QualityEstimate.isLosslessFormat(track.format)
            ? 'transcoded'
            : track.format?.toUpperCase());
    return Resolved(
      uri: u,
      info: StreamInfo(
        source: kind,
        codec: codec,
        bitrateKbps:
            lossless ? track.bitrateKbps : min(320, track.bitrateKbps ?? 320),
        sourceTrackId: track.id,
      ),
      cacheKey: 'sub:${track.nativeId}@${lossless ? 'raw' : '320'}',
    );
  }

  @override
  Future<String> probe() async =>
      'ping ${await test(_config() ?? (throw SourceUnavailableException('not configured')))}';
}

/// What the Jellyfin source needs from the account store (Kotlin Account:
/// extra = "<server>|<userId>", secret = access token).
class JellyfinConfig {
  const JellyfinConfig({
    required this.baseUrl,
    required this.userId,
    required this.accessToken,
  });

  final String baseUrl;
  final String userId;
  final String accessToken;
}

/// The (accessToken, userId) pair a successful Jellyfin login returns.
typedef JellyfinLogin = ({String accessToken, String userId});

/// Jellyfin: username/password → access token. Lossless:
/// /Audio/{id}/stream?static=true (the original file).
class JellyfinSource implements MusicSource {
  JellyfinSource({
    required JellyfinConfig? Function() config,
    required bool Function() enabled,
  })  : _config = config,
        _enabled = enabled;

  final JellyfinConfig? Function() _config;
  final bool Function() _enabled;

  @override
  SourceKind get kind => SourceKind.jellyfin;

  @override
  bool available() => _enabled() && _config() != null;

  /// The MediaBrowser auth header, verbatim from the Kotlin.
  static String authHeader([String? token]) =>
      'MediaBrowser Client="UpZe", Device="Android", '
      'DeviceId="musicspot-android", Version="2.0"'
      '${token != null ? ', Token="$token"' : ''}';

  /// Logs in and returns (accessToken, userId). (Kotlin: login)
  Future<JellyfinLogin> login(
      String server, String user, String password) async {
    final http.Response resp;
    try {
      resp = await http
          .post(
            _build(serverBase(server), ['Users', 'AuthenticateByName']),
            headers: {
              'X-Emby-Authorization': authHeader(),
              'Authorization': authHeader(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'Username': user, 'Pw': password}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw SourceUnavailableException('Jellyfin login failed', e);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SourceUnavailableException(
          'Jellyfin login failed (HTTP ${resp.statusCode})');
    }
    // No hard casts: a malformed reply is a clean source error (v2.0.14).
    final o = _asMap(resp.body.isEmpty ? null : _tryJson(resp.body)) ??
        (throw SourceUnavailableException('Unexpected Jellyfin reply'));
    final userObj = _o(o, 'User') ??
        (throw SourceUnavailableException('Unexpected Jellyfin reply'));
    final token = _s(o, 'AccessToken') ??
        (throw SourceUnavailableException('Unexpected Jellyfin reply'));
    final userId = _s(userObj, 'Id') ??
        (throw SourceUnavailableException('Unexpected Jellyfin reply'));
    return (accessToken: token, userId: userId);
  }

  static Object? _tryJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Track>> search(String query, [int limit = 20]) async {
    final a =
        _config() ?? (throw SourceUnavailableException('No Jellyfin server'));
    final base = serverBase(a.baseUrl);
    final u = _build(base, ['Items'], {
      'searchTerm': query,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'UserId': a.userId,
      'Limit': '$limit',
      'Fields': 'MediaSources',
    }).toString();
    final o = _asMap(await getJson(u, headers: {
          'X-Emby-Authorization': authHeader(a.accessToken),
          'Authorization': authHeader(a.accessToken),
        })) ??
        (throw SourceUnavailableException('Unexpected Jellyfin reply'));
    return _arr(o, 'Items').map((e) {
      if (e is! Map) return null;
      final it = e.cast<String, dynamic>();
      final id = _s(it, 'Id');
      if (id == null) return null;
      final artists = _arr(it, 'Artists')
          .map((x) => x is String ? x : null)
          .whereType<String>()
          .toList();
      final mediaSources = _arr(it, 'MediaSources');
      final firstSrc = mediaSources.isEmpty
          ? null
          : (mediaSources.first as Map?)?.cast<String, dynamic>();
      final imgId = _s(it, 'AlbumId') ?? id;
      final art = _build(base, ['Items', imgId, 'Images', 'Primary'],
          {'maxHeight': '600', 'api_key': a.accessToken}).toString();
      final bitrate = firstSrc == null ? null : _l(firstSrc, 'Bitrate');
      return Track(
        id: 'jf:$id',
        title: _s(it, 'Name') ?? '',
        artist: artists.isEmpty
            ? (_s(it, 'AlbumArtist') ?? '')
            : artists.join(', '),
        album: _s(it, 'Album'),
        durationMs: (_l(it, 'RunTimeTicks') ?? 0) ~/ 10000,
        artUrl: art,
        format: (firstSrc == null ? null : _s(firstSrc, 'Container')) ??
            _s(it, 'Container'),
        bitrateKbps: bitrate == null ? null : bitrate ~/ 1000,
      );
    }).whereType<Track>().toList();
  }

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final a =
        _config() ?? (throw SourceUnavailableException('No Jellyfin server'));
    final lossless =
        quality == Quality.lossless || (quality == Quality.max && !metered);
    final u = _build(
      serverBase(a.baseUrl),
      lossless
          ? ['Audio', track.nativeId, 'stream']
          : ['Audio', track.nativeId, 'stream.mp3'],
      {
        if (lossless) 'static': 'true' else 'audioBitRate': '320000',
        'api_key': a.accessToken,
      },
    ).toString();
    return Resolved(
      uri: u,
      info: StreamInfo(
        source: kind,
        codec: lossless ? track.format?.toUpperCase() : 'MP3',
        bitrateKbps: lossless ? track.bitrateKbps : 320,
        sourceTrackId: track.id,
      ),
      cacheKey: 'jf:${track.nativeId}@${lossless ? 'raw' : '320'}',
    );
  }

  @override
  Future<String> probe() async {
    final a =
        _config() ?? (throw SourceUnavailableException('not configured'));
    final o = _asMap(await getJson(
            _build(serverBase(a.baseUrl), ['System', 'Info', 'Public'])
                .toString())) ??
        (throw SourceUnavailableException('Unexpected Jellyfin reply'));
    return 'Jellyfin ${_s(o, 'Version')}';
  }
}
