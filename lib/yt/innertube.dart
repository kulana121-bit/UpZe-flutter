// Ported from UpZe (Kotlin) yt/Innertube.kt + yt/PlayerClient.kt +
// yt/YtMusic.kt (search + lyrics essentials) + yt/YtStreams.kt (format
// parsing/ranking essentials) + the search half of yt/InnertubeParser.kt.
// Request shapes follow OpenTune 1.0.4, GPL-3.0-or-later.
// Modified for UpZe (C) 2026 Ravi, GPL-3.0-or-later.
//
// HONEST PORTING NOTE — NewPipeExtractor:
// The Kotlin app's stream resolver has a NewPipeExtractor fallback
// (yt/NewPipeBridge.kt, yt/YtStreams.kt `NewPipeJsPlayer`/`newPipe`).
// NewPipeExtractor is a Java library; there is no Dart port and it cannot
// run in Flutter. It is therefore NOT ported here. Consequences, kept
// visible rather than papered over:
//  * Signature-ciphered formats (`signatureCipher` without a plain `url`)
//    cannot be unlocked in Dart — solving them needs YouTube's player
//    JavaScript, which NewPipe ran on the JVM. Formats that arrive
//    ciphered are skipped by [YtStreamResolver].
//  * The `n` throttling parameter is left as-is for the same reason.
// What IS ported is the Kotlin code's own direct Innertube path: the
// client walk over plain-URL clients (ANDROID_MUSIC first — it returns
// unciphered URLs), playability classification, format ranking, the
// `cver` patch and the ranged byte probe.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';

// ---------------------------------------------------------------------------
// Client identities (Kotlin: PlayerClient.kt)
// ---------------------------------------------------------------------------

/// One client identity for the `player` endpoint.
///
/// YouTube hands out stream URLs per client, and which clients are answered
/// changes without notice, so this is a list to walk rather than a constant.
/// Three things travel together and must not be separated: [userAgent]
/// (the media fetch has to repeat it), [origin] (browser-shaped clients
/// only) and [needsSignatureTimestamp] (the clients that answer with
/// ciphered formats). Versions are load-bearing; these are the Kotlin
/// values, checked against the live endpoint as of July 2026.
class PlayerClient {
  final String clientName;
  final String clientVersion;

  /// Numeric client id sent as `X-YouTube-Client-Name` (a number, despite
  /// the header's name).
  final String clientId;
  final String userAgent;
  final String? osName;
  final String? osVersion;
  final String? deviceMake;
  final String? deviceModel;
  final int? androidSdkVersion;

  /// The host this client runs on, for browser-shaped clients only.
  final String? origin;

  /// Ciphered formats can't be unlocked without one.
  final bool needsSignatureTimestamp;

  const PlayerClient({
    required this.clientName,
    required this.clientVersion,
    required this.clientId,
    required this.userAgent,
    this.osName,
    this.osVersion,
    this.deviceMake,
    this.deviceModel,
    this.androidSdkVersion,
    this.origin,
    this.needsSignatureTimestamp = false,
  });

  PlayerClient copyWith({String? clientVersion, String? userAgent, String? osVersion}) =>
      PlayerClient(
        clientName: clientName,
        clientVersion: clientVersion ?? this.clientVersion,
        clientId: clientId,
        userAgent: userAgent ?? this.userAgent,
        osName: osName,
        osVersion: osVersion ?? this.osVersion,
        deviceMake: deviceMake,
        deviceModel: deviceModel,
        androidSdkVersion: androidSdkVersion,
        origin: origin,
        needsSignatureTimestamp: needsSignatureTimestamp,
      );

  String? get referer => origin == null ? null : '$origin/';

  /// Browser-shaped clients are served from their own host; app clients
  /// from YouTube proper.
  bool get usesMusicHost => origin == Innertube.musicOrigin;

  /// Headers the *media* request must carry for a URL this client minted:
  /// googlevideo treats a mismatch as reason enough to throttle or 403.
  Map<String, String> mediaHeaders() => {
        'User-Agent': userAgent,
        if (origin != null) 'Origin': origin!,
        if (referer != null) 'Referer': referer!,
      };

  static const String _webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

  /// iPhone YouTube: answered without login, PO token or signature
  /// timestamp, and returns plain `url` fields.
  static const PlayerClient ios = PlayerClient(
    clientName: 'IOS',
    clientVersion: '21.26.4',
    clientId: '5',
    userAgent:
        'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    osName: 'iPhone',
    osVersion: '18.3.2.22D82',
    deviceMake: 'Apple',
    deviceModel: 'iPhone16,2',
  );

  /// A newer build of the same app: refused on a different schedule.
  static final PlayerClient iosRecent = ios.copyWith(
    clientVersion: '21.29.1',
    userAgent:
        'com.google.ios.youtube/21.29.1 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X;)',
    osVersion: '18.5.22F70',
  );

  /// The phone YouTube app. Answers OK where others are turned away, but
  /// every format comes back ciphered — kept in the walk for completeness;
  /// in Dart its formats are unusable without a JS solver (see header).
  static const PlayerClient android = PlayerClient(
    clientName: 'ANDROID',
    clientVersion: '21.26.364',
    clientId: '3',
    userAgent: 'com.google.android.youtube/21.26.364 '
        '(Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002; Cronet/132.0.6834.79) gzip',
    osName: 'Android',
    osVersion: '15',
    deviceMake: 'Google',
    deviceModel: 'Pixel 9 Pro',
    androidSdkVersion: 35,
    needsSignatureTimestamp: true,
  );

  /// YouTube Music Android app. Returns plain URLs without ciphering, and
  /// (mid-2026) is not subject to the PO-token enforcement that blocks
  /// stream fetches from other clients.
  static const PlayerClient androidMusic = PlayerClient(
    clientName: 'ANDROID_MUSIC',
    clientVersion: '8.39.42',
    clientId: '21',
    userAgent: 'com.google.android.apps.youtube.music/8.39.42 '
        '(Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002) gzip',
    osName: 'Android',
    osVersion: '15',
    deviceMake: 'Google',
    deviceModel: 'Pixel 9 Pro',
    androidSdkVersion: 35,
  );

  /// The Quest's YouTube app: unciphered, login-free, no PO token, no
  /// signature timestamp. Version MUST be ≤1.65.10 — later versions trigger
  /// SABR-only streaming (no HTTPS URLs returned).
  static const PlayerClient androidVr = PlayerClient(
    clientName: 'ANDROID_VR',
    clientVersion: '1.65.10',
    clientId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
        '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    osName: 'Android',
    osVersion: '12L',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    androidSdkVersion: 32,
  );

  /// An older build of the same app; refused on a different schedule.
  static final PlayerClient androidVrLegacy = androidVr.copyWith(
    clientVersion: '1.43.32',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.43.32 '
        '(Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)',
  );

  /// The browser identity music.youtube.com itself runs as. Not part of
  /// the anonymous stream walk (ciphered, and refused as often as it
  /// works) — but it is the identity every WEB_REMIX browse/search/next
  /// call in this file is made as.
  static const PlayerClient webRemix = PlayerClient(
    clientName: 'WEB_REMIX',
    clientVersion: '1.20260707.12.00',
    clientId: '67',
    userAgent: _webUserAgent,
    origin: Innertube.musicOrigin,
    needsSignatureTimestamp: true,
  );

  static const PlayerClient _web = PlayerClient(
    clientName: 'WEB',
    clientVersion: '2.20260708.00.00',
    clientId: '1',
    userAgent: _webUserAgent,
    origin: Innertube.ytOrigin,
  );

  /// TV Cobalt v7 — a reliable client for flagged IPs. No PO token, no login.
  static const PlayerClient tvHtml5 = PlayerClient(
    clientName: 'TVHTML5',
    clientVersion: '7.20260707.07.00',
    clientId: '7',
    userAgent: 'Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 '
        '(KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15',
    origin: Innertube.ytOrigin,
  );

  /// The client a googlevideo URL says minted it, so a media fetch can be
  /// dressed as that client. Falls back to [ios] when the URL names a
  /// client we don't model.
  static PlayerClient forStreamUrl(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return ios;
    final name = parsed.queryParameters['c']?.toUpperCase();
    if (name == null) return ios;
    final version = parsed.queryParameters['cver'];
    if (name.startsWith('IOS')) {
      return version == iosRecent.clientVersion ? iosRecent : ios;
    }
    if (name == 'ANDROID_VR') {
      return version == androidVrLegacy.clientVersion
          ? androidVrLegacy
          : androidVr;
    }
    if (name == 'ANDROID_MUSIC') return androidMusic;
    if (name.startsWith('ANDROID')) return android;
    if (name.startsWith('TVHTML5')) return tvHtml5;
    if (name == 'WEB_REMIX') return webRemix;
    if (name.startsWith('WEB') || name == 'MWEB') return _web;
    return ios;
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerClient &&
      other.clientName == clientName &&
      other.clientVersion == clientVersion;

  @override
  int get hashCode => Object.hash(clientName, clientVersion);
}

/// Search tabs (Kotlin: SearchFilter, in yt/Models.kt).
enum SearchFilter {
  all(null),
  songs('EgWKAQIIAWoKEAkQChAFEAMQBA=='),
  videos('EgWKAQIQAWoKEAkQChAFEAMQBA=='),
  albums('EgWKAQIYAWoKEAkQChAFEAMQBA=='),
  artists('EgWKAQIgAWoKEAkQChAFEAMQBA=='),
  playlists('EgWKAQIoAWoKEAkQChAFEAMQBA==');

  final String? params;
  const SearchFilter(this.params);
}

// ---------------------------------------------------------------------------
// Errors (Kotlin: Innertube.UnplayableException + Http.HttpStatusException)
// ---------------------------------------------------------------------------

class InnertubeHttpException implements Exception {
  final int code;
  final String url;
  const InnertubeHttpException(this.code, this.url);
  @override
  String toString() => 'InnertubeHttpException($code, $url)';
}

/// The player endpoint answered, but not with a playable video.
/// (Port of OpenTune's UnplayableException classification.)
class UnplayableException implements Exception {
  final String status;
  final String? reason;
  const UnplayableException(this.status, this.reason);

  String get _text => reason ?? status;

  bool get isAgeGate => [
        'confirm your age',
        'age-restricted',
        'age restricted',
        'inappropriate for some users',
      ].any((s) => _text.toLowerCase().contains(s));

  bool get looksLikeBotCheck =>
      !isAgeGate &&
      ['bot', 'unusual traffic', 'sign in', 'login_required'].any((s) =>
          _text.toLowerCase().contains(s) || status.toLowerCase().contains(s));

  bool get isPermanent => [
        'not available in your country',
        'who has blocked it in your country',
        'removed by the uploader',
        'account associated with this video has been terminated',
        'private video',
        'members-only',
      ].any((s) => _text.toLowerCase().contains(s));

  @override
  String toString() => '$status: ${reason ?? "unplayable"}';
}

/// Every client failed (or was stood down) for this track.
class YtExhaustedException implements Exception {
  final String message;
  const YtExhaustedException(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Innertube client (Kotlin: Innertube.kt)
// ---------------------------------------------------------------------------

class Innertube {
  static const String musicBase = 'https://music.youtube.com/youtubei/v1';
  static const String ytBase = 'https://www.youtube.com/youtubei/v1';
  static const String musicOrigin = 'https://music.youtube.com';
  static const String ytOrigin = 'https://www.youtube.com';

  static const Set<int> _retryable = {429, 500, 502, 503, 504};
  static final RegExp _visitorRe = RegExp(r'Cg[A-Za-z0-9_%-]{40,}');
  static const List<String> _sapisidNames = [
    'SAPISID',
    '__Secure-3PAPISID',
    '__Secure-1PAPISID',
  ];

  final http.Client _http;

  /// youtubei base for app-shaped player clients.
  final String ytBaseUrl;

  /// youtubei base for WEB_REMIX (music) calls.
  final String musicBaseUrl;

  /// Visitor-id source; null disables the fetch.
  final String? visitorUrl;

  /// Kotlin derives these from the device Locale (country → region,
  /// language with iw→he / in→id fixes); Flutter has no device locale in
  /// this layer, so they are constructor parameters.
  String region;
  String language;

  String? _cookie;

  /// Session cookie from the sign-in WebView; null = guest.
  /// Setting it drops the cached visitor id, as in Kotlin.
  String? get cookie => _cookie;
  set cookie(String? value) {
    if (_cookie != value) {
      _visitorData = null;
      _cookie = value;
    }
  }

  String? _visitorData;
  String? get visitorData => _visitorData;

  bool get signedIn => _cookie != null && sapisidFrom(_cookie!) != null;

  Innertube({
    http.Client? client,
    this.ytBaseUrl = ytBase,
    this.musicBaseUrl = musicBase,
    this.visitorUrl = 'https://www.youtube.com/sw.js_data',
    this.region = 'IN',
    this.language = 'en',
  }) : _http = client ?? http.Client();

  // ---- visitor data ---------------------------------------------------------

  Future<String?> ensureVisitorData({bool refresh = false}) async {
    if (!refresh && _visitorData != null) return _visitorData;
    final src = visitorUrl;
    if (src == null) return _visitorData;
    String body;
    try {
      final r = await _http.get(Uri.parse(src),
          headers: {'User-Agent': PlayerClient.webRemix.userAgent});
      if (r.statusCode != 200) return _visitorData;
      body = r.body;
    } catch (_) {
      return _visitorData;
    }
    dynamic payload;
    try {
      final nl = body.indexOf('\n');
      final start = nl >= 0 ? nl + 1 : (body.length > 5 ? 5 : 0);
      payload = jsonDecode(body.substring(start));
    } catch (_) {
      return null;
    }
    _visitorData = _findVisitor(payload);
    return _visitorData;
  }

  static String? _findVisitor(dynamic e) {
    if (e is List) {
      for (final item in e) {
        final found = _findVisitor(item);
        if (found != null) return found;
      }
      return null;
    }
    if (e is String && _visitorRe.hasMatch(e)) return e;
    if (e is Map) {
      for (final v in e.values) {
        final found = _findVisitor(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  // ---- SAPISID signing ------------------------------------------------------

  static String? sapisidFrom(String cookieHeader) {
    final jar = <String, String>{};
    for (final e in cookieHeader.split(';')) {
      final eq = e.indexOf('=');
      if (eq < 0) continue;
      final n = e.substring(0, eq).trim();
      final v = e.substring(eq + 1).trim();
      if (n.isNotEmpty && v.isNotEmpty) jar[n] = v;
    }
    for (final name in _sapisidNames) {
      final v = jar[name];
      if (v != null) return v;
    }
    return null;
  }

  static String sapisidHash(String sapisid, String origin, {int? nowSec}) {
    final sec = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = sha1.convert(utf8.encode('$sec $sapisid $origin')).toString();
    return 'SAPISIDHASH ${sec}_$digest';
  }

  // ---- WEB_REMIX endpoints ----------------------------------------------------

  Future<Map<String, dynamic>> browse(String browseId, {String? params}) =>
      _postMusic('browse', extras: {
        'browseId': browseId,
        if (params != null) 'params': params,
      });

  Future<Map<String, dynamic>> browseContinuation(String token) => _postMusic(
        'browse',
        query: {'ctoken': token, 'continuation': token, 'type': 'next'},
        extras: {'continuation': token},
      );

  Future<Map<String, dynamic>> charts(String? country) => _postMusic('browse',
      extras: {
        'browseId': 'FEmusic_charts',
        if (country != null)
          'formData': {
            'selectedValues': [country],
          },
      });

  Future<Map<String, dynamic>> search(String query, {String? params}) =>
      _postMusic('search', extras: {
        'query': query,
        if (params != null) 'params': params,
      });

  Future<Map<String, dynamic>> searchContinuation(String token) => _postMusic(
        'search',
        query: {'ctoken': token, 'continuation': token, 'type': 'next'},
        extras: {'continuation': token},
      );

  Future<Map<String, dynamic>> suggestions(String input) =>
      _postMusic('music/get_search_suggestions', extras: {'input': input});

  /// Watch-next: radio queue ("RDAMVM<id>"), related browse id, lyrics browse id.
  /// [includePlaylist] false sends no playlistId at all, as the Kotlin
  /// lyrics call does (`next(videoId, null)`).
  Future<Map<String, dynamic>> next(String videoId,
          {String? playlistId, bool includePlaylist = true}) =>
      _postMusic('next', extras: {
        'videoId': videoId,
        if (includePlaylist) 'playlistId': playlistId ?? 'RDAMVM$videoId',
        'isAudioOnly': true,
      });

  Future<Map<String, dynamic>> accountMenu() =>
      _postMusic('account/account_menu', extras: const {});

  Future<void> like(String videoId, bool like) async {
    await _postMusic(like ? 'like/like' : 'like/removelike', extras: {
      'target': {'videoId': videoId},
    });
  }

  Future<String?> createPlaylist(String title, List<String> videoIds) async {
    final res = await _postMusic('playlist/create', extras: {
      'title': title,
      'privacyStatus': 'PRIVATE',
      'videoIds': videoIds,
    });
    final id = res['playlistId'];
    return id is String ? id : null;
  }

  Future<void> addToPlaylist(String playlistId, String videoId) =>
      _postMusic('browse/edit_playlist', extras: {
        'playlistId': playlistId.startsWith('VL')
            ? playlistId.substring(2)
            : playlistId,
        'actions': [
          {'action': 'ACTION_ADD_VIDEO', 'addedVideoId': videoId},
        ],
      });

  // ---- player (device clients, anonymous unless asked) ------------------------

  Future<Map<String, dynamic>> player(
    String videoId,
    PlayerClient client, {
    bool authenticated = false,
    int? signatureTimestamp,
  }) async {
    await ensureVisitorData();
    final body = <String, dynamic>{
      'context': {
        'client': {
          'clientName': client.clientName,
          'clientVersion': client.clientVersion,
          if (client.osName != null) 'osName': client.osName,
          if (client.osVersion != null) 'osVersion': client.osVersion,
          if (client.deviceMake != null) 'deviceMake': client.deviceMake,
          if (client.deviceModel != null) 'deviceModel': client.deviceModel,
          if (client.androidSdkVersion != null)
            'androidSdkVersion': client.androidSdkVersion,
          'hl': language,
          'gl': region,
          if (_visitorData != null) 'visitorData': _visitorData,
        },
      },
      if (client.needsSignatureTimestamp && signatureTimestamp != null)
        'playbackContext': {
          'contentPlaybackContext': {'signatureTimestamp': signatureTimestamp},
        },
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
    final base = client.usesMusicHost ? musicBaseUrl : ytBaseUrl;
    final headers = <String, String>{
      'User-Agent': client.userAgent,
      'X-YouTube-Client-Name': client.clientId,
      'X-YouTube-Client-Version': client.clientVersion,
      if (client.origin != null) 'Origin': client.origin!,
      if (client.referer != null) 'Referer': client.referer!,
      if (_visitorData != null) 'X-Goog-Visitor-Id': _visitorData!,
    };
    final c = _cookie;
    if (authenticated && c != null) {
      headers['Cookie'] = c;
      final sapisid = sapisidFrom(c);
      if (sapisid != null) {
        headers['Authorization'] = sapisidHash(
            sapisid,
            client.origin ??
                (client.usesMusicHost ? musicOrigin : ytOrigin));
      }
    }
    final res = await _execJson(
        Uri.parse('$base/player?prettyPrint=false'), body, headers);
    final ps = res['playabilityStatus'];
    final status = ps is Map ? ps['status'] : null;
    if (status is String && status != 'OK') {
      final reason = ps is Map ? ps['reason'] : null;
      throw UnplayableException(status, reason is String ? reason : null);
    }
    return res;
  }

  // ---- plumbing ---------------------------------------------------------------

  Future<Map<String, dynamic>> _postMusic(
    String endpoint, {
    Map<String, String> query = const {},
    required Map<String, dynamic> extras,
  }) async {
    if (_visitorData == null) await ensureVisitorData();
    final url = Uri.parse('$musicBaseUrl/$endpoint').replace(queryParameters: {
      'prettyPrint': 'false',
      ...query,
    });
    final body = <String, dynamic>{
      'context': {
        'client': {
          'clientName': 'WEB_REMIX',
          'clientVersion': PlayerClient.webRemix.clientVersion,
          'hl': language,
          'gl': region,
          if (_visitorData != null) 'visitorData': _visitorData,
        },
        'user': {'lockedSafetyMode': false},
        'request': {'useSsl': true},
      },
      ...extras,
    };
    var attempt = 0;
    while (true) {
      final headers = <String, String>{
        'User-Agent': PlayerClient.webRemix.userAgent,
        'Accept-Language': '$language,en;q=0.8',
        'Origin': musicOrigin,
        'X-Origin': musicOrigin,
        'Referer': '$musicOrigin/',
        'X-YouTube-Client-Name': PlayerClient.webRemix.clientId,
        'X-YouTube-Client-Version': PlayerClient.webRemix.clientVersion,
        if (_visitorData != null) 'X-Goog-Visitor-Id': _visitorData!,
      };
      final c = _cookie;
      if (c != null) {
        headers['Cookie'] = c;
        headers['X-Goog-AuthUser'] = '0';
        final sapisid = sapisidFrom(c);
        if (sapisid != null) {
          headers['Authorization'] = sapisidHash(sapisid, musicOrigin);
        }
      }
      try {
        final res = await _execJson(url, body, headers);
        if (_visitorData == null) {
          final rc = res['responseContext'];
          if (rc is Map && rc['visitorData'] is String) {
            _visitorData = rc['visitorData'] as String;
          }
        }
        return res;
      } on InnertubeHttpException catch (e) {
        if (!_retryable.contains(e.code) || ++attempt >= 3) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  Future<Map<String, dynamic>> _execJson(
      Uri url, Map<String, dynamic> body, Map<String, String> headers) async {
    final r = await _http.post(url,
        headers: {'Content-Type': 'application/json', ...headers},
        body: jsonEncode(body));
    if (r.statusCode != 200) {
      throw InnertubeHttpException(r.statusCode, url.toString());
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(r.body);
    } catch (_) {
      throw IOException('Innertube: response is not JSON (${r.body.length} bytes)');
    }
    if (decoded is! Map<String, dynamic>) {
      throw IOException(
          'Innertube: response is not a JSON object (${r.body.length} bytes)');
    }
    return decoded;
  }
}

/// dart:core has no IOException type of its own in pure Dart libraries
/// (dart:io's HttpException aside); this file stays dart:io-free so it can
/// be unit-tested, hence a local one.
class IOException implements Exception {
  final String message;
  const IOException(this.message);
  @override
  String toString() => 'IOException: $message';
}

// ---------------------------------------------------------------------------
// Tiny JSON navigation helpers (null-safe, never throw) — Kotlin: the
// o/a/s/runs extensions at the bottom of InnertubeParser.kt. Responses are
// decoded JSON: Map<String, dynamic> / List<dynamic> / String / num / bool.
// ---------------------------------------------------------------------------

Map<String, dynamic>? _o(dynamic v, String key) {
  if (v is Map) {
    final inner = v[key];
    if (inner is Map<String, dynamic>) return inner;
    if (inner is Map) return inner.cast<String, dynamic>();
  }
  return null;
}

List<dynamic>? _a(dynamic v, String key) {
  if (v is Map) {
    final inner = v[key];
    if (inner is List) return inner;
  }
  return null;
}

String? _s(dynamic v, String key) {
  if (v is Map) {
    final inner = v[key];
    if (inner is String) return inner;
    if (inner is num || inner is bool) return inner.toString();
  }
  return null;
}

String _runs(dynamic v) {
  final runs = _a(v, 'runs');
  if (runs == null) return '';
  return runs.map((r) => _s(r, 'text') ?? '').join();
}

/// Depth-first collection of a named renderer, preserving document order.
List<Map<String, dynamic>> _collectRenderers(dynamic root, String name) {
  final out = <Map<String, dynamic>>[];
  void walk(dynamic node) {
    if (node is Map) {
      final hit = node[name];
      if (hit is Map<String, dynamic>) out.add(hit);
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(root);
  return out;
}

bool _hasExplicitBadge(dynamic v) {
  if (v is String) return v == 'MUSIC_EXPLICIT_BADGE';
  if (v is List) return v.any(_hasExplicitBadge);
  if (v is Map) return v.values.any(_hasExplicitBadge);
  return false;
}

/// "3:45" / "1:02:03" → ms (Kotlin: parseClock, in source/MusicSource.kt).
int parseClockMs(String? text) {
  if (text == null || text.trim().isEmpty) return 0;
  final parts = text
      .trim()
      .split(':')
      .map((p) => int.tryParse(p.trim()))
      .whereType<int>()
      .toList();
  if (parts.isEmpty) return 0;
  var acc = 0;
  for (final p in parts) {
    acc = acc * 60 + p;
  }
  return acc * 1000;
}

/// YouTube thumbnails carry their size in the URL; ask for a sharper copy
/// for the player. (Kotlin: YtMusic.upscale.)
String? upscaleArtwork(String? url) {
  if (url == null) return null;
  if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
    return url.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w544-h544-l90-rj');
  }
  return url;
}

bool _isPlaceholderArtist(String? name) {
  final key = (name ?? '')
      .trim()
      .replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  return const {'', 'variousartist', 'variousartists', 'va', 'unknownartist', 'unknown', 'artist'}
      .contains(key);
}

String _preferredArtist(List<String?> names) {
  for (final n in names) {
    if (!_isPlaceholderArtist(n)) return n!.trim();
  }
  for (final n in names) {
    if (n != null && n.trim().isNotEmpty) return n.trim();
  }
  return 'Unknown artist';
}

// ---------------------------------------------------------------------------
// Search parsing (Kotlin: InnertubeParser.parseSearchPage /
// parseResponsiveListItem / parseCardShelfSong, songs only)
// ---------------------------------------------------------------------------

final RegExp _durationRe = RegExp(r'^\d+:\d{2}$');
final RegExp _tallyRe = RegExp(
  r'^[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|hours?|minutes?|seconds?)\b.*',
  caseSensitive: false,
);
const Set<String> _typeWords = {
  'song', 'video', 'album', 'single', 'ep', 'artist', 'playlist', 'podcast', 'episode',
};

class _Credits {
  final String? artistId;
  final String? artistName;
  final String? albumId;
  final String? albumName;
  const _Credits({this.artistId, this.artistName, this.albumId, this.albumName});
}

_Credits _creditsOf(List<dynamic> runs) {
  String? artistId, artistName, albumId, albumName;
  for (final run in runs) {
    final browse = _o(_o(run, 'navigationEndpoint'), 'browseEndpoint');
    final id = _s(browse, 'browseId');
    if (browse == null || id == null) continue;
    final pageType = _s(
            _o(_o(browse, 'browseEndpointContextSupportedConfigs'),
                'browseEndpointContextMusicConfig'),
            'pageType') ??
        '';
    if (pageType.contains('ARTIST') &&
        (artistId == null ||
            (_isPlaceholderArtist(artistName) &&
                !_isPlaceholderArtist(_s(run, 'text'))))) {
      artistId = id;
      artistName = _s(run, 'text');
    } else if (pageType.contains('ALBUM') && albumId == null) {
      albumId = id;
      albumName = _s(run, 'text');
    }
  }
  return _Credits(
      artistId: artistId, artistName: artistName, albumId: albumId, albumName: albumName);
}

bool _thumbsNotSquare(List<dynamic>? thumbnails) {
  if (thumbnails == null || thumbnails.isEmpty) return false;
  final last = thumbnails.last;
  final w = _s(last, 'width');
  final h = _s(last, 'height');
  final width = w == null ? null : double.tryParse(w);
  final height = h == null ? null : double.tryParse(h);
  if (width == null || height == null || width <= 0 || height <= 0) return false;
  final ratio = width / height;
  return ratio < 0.85 || ratio > 1.15;
}

String? _bestThumb(List<dynamic>? thumbnails) {
  if (thumbnails == null || thumbnails.isEmpty) return null;
  return _s(thumbnails.last, 'url');
}

class _ParsedSong {
  final Track track;
  final bool isVideo;
  const _ParsedSong(this.track, this.isVideo);
}

/// One track row (Kotlin: InnertubeParser.parseResponsiveListItem).
_ParsedSong? _parseResponsiveListItem(Map<String, dynamic>? renderer,
    {_Credits fallback = const _Credits()}) {
  if (renderer == null) return null;
  // playlistItemData.videoId, else the play button's watch endpoint.
  var node = _o(renderer, 'overlay');
  node = _o(node, 'musicItemThumbnailOverlayRenderer');
  node = _o(node, 'content');
  node = _o(node, 'musicPlayButtonRenderer');
  node = _o(node, 'playNavigationEndpoint');
  final resolvedVideoId = _s(_o(renderer, 'playlistItemData'), 'videoId') ??
      _s(_o(node, 'watchEndpoint'), 'videoId');
  if (resolvedVideoId == null) return null;

  final columns = _a(renderer, 'flexColumns') ?? const [];
  String columnText(int i) {
    if (i >= columns.length) return '';
    return _runs(_o(
        _o(columns[i], 'musicResponsiveListItemFlexColumnRenderer'), 'text'));
  }

  final title = columnText(0);
  if (title.isEmpty) return null;
  final subtitle = columnText(1);
  final parts =
      subtitle.split(' • ').where((p) => p.isNotEmpty).toList();

  String? duration;
  if (parts.isNotEmpty && _durationRe.hasMatch(parts.last)) {
    duration = parts.last;
  } else {
    for (final column in _a(renderer, 'fixedColumns') ?? const []) {
      final text = _runs(
          _o(_o(column, 'musicResponsiveListItemFixedColumnRenderer'), 'text'));
      if (_durationRe.hasMatch(text)) {
        duration = text;
        break;
      }
    }
  }

  String? rowType;
  for (final p in parts) {
    if (_typeWords.contains(p.toLowerCase())) {
      rowType = p.toLowerCase();
      break;
    }
  }
  String? artist;
  for (final p in parts) {
    if (!_durationRe.hasMatch(p) &&
        !_typeWords.contains(p.toLowerCase()) &&
        !_tallyRe.hasMatch(p)) {
      artist = p;
      break;
    }
  }

  final allRuns = <dynamic>[];
  for (final col in columns) {
    final runs = _a(
        _o(_o(col, 'musicResponsiveListItemFlexColumnRenderer'), 'text'),
        'runs');
    if (runs != null) allRuns.addAll(runs);
  }
  final credits = _creditsOf(allRuns);

  final thumbnails = _a(
      _o(_o(_o(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails');

  final artistId = (credits.artistId != null &&
          !_isPlaceholderArtist(credits.artistName))
      ? credits.artistId
      : (fallback.artistId != null &&
              !_isPlaceholderArtist(fallback.artistName)
          ? fallback.artistId
          : null);

  final isVideo = rowType == 'video' || _thumbsNotSquare(thumbnails);
  final track = Track(
    id: 'yt:$resolvedVideoId',
    title: title,
    artist: _preferredArtist([credits.artistName, artist, fallback.artistName]),
    album: credits.albumName ?? fallback.albumName,
    durationMs: parseClockMs(duration),
    artUrl: upscaleArtwork(_bestThumb(thumbnails)),
    artistId: artistId == null ? null : 'yt:$artistId',
    albumId: (credits.albumId ?? fallback.albumId) == null
        ? null
        : 'yt:${credits.albumId ?? fallback.albumId}',
    explicit: _hasExplicitBadge(renderer['badges']),
  );
  return _ParsedSong(track, isVideo);
}

/// The promoted result at the top of an unfiltered search
/// (Kotlin: InnertubeParser.parseCardShelfSong).
_ParsedSong? _parseCardShelfSong(Map<String, dynamic> renderer) {
  final videoId =
      _s(_o(_o(renderer, 'onTap'), 'watchEndpoint'), 'videoId');
  if (videoId == null) return null;
  final title = _runs(_o(renderer, 'title'));
  if (title.isEmpty) return null;
  final subtitleRuns = _a(_o(renderer, 'subtitle'), 'runs') ?? const [];
  final subtitle = subtitleRuns.map((r) => _s(r, 'text') ?? '').join();
  final parts = subtitle.split(' • ').where((p) => p.isNotEmpty).toList();
  final duration =
      parts.isNotEmpty && _durationRe.hasMatch(parts.last) ? parts.last : null;
  String? rowType;
  for (final p in parts) {
    if (_typeWords.contains(p.toLowerCase())) {
      rowType = p.toLowerCase();
      break;
    }
  }
  final credits = _creditsOf(subtitleRuns);
  String? artist;
  for (final p in parts) {
    if (!_durationRe.hasMatch(p) &&
        !_typeWords.contains(p.toLowerCase()) &&
        !_tallyRe.hasMatch(p)) {
      artist = p;
      break;
    }
  }
  final thumbnails = _a(
      _o(_o(_o(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails');
  final isVideo = rowType == 'video' || _thumbsNotSquare(thumbnails);
  return _ParsedSong(
    Track(
      id: 'yt:$videoId',
      title: title,
      artist: _preferredArtist([credits.artistName, artist]),
      album: credits.albumName,
      durationMs: parseClockMs(duration),
      artUrl: upscaleArtwork(_bestThumb(thumbnails)),
      artistId: (credits.artistId != null &&
              !_isPlaceholderArtist(credits.artistName))
          ? 'yt:${credits.artistId}'
          : null,
      albumId: credits.albumId == null ? null : 'yt:${credits.albumId}',
      explicit: _hasExplicitBadge(renderer['subtitleBadges']),
    ),
    isVideo,
  );
}

String? _continuationToken(dynamic root) {
  final items = _collectRenderers(root, 'continuationItemRenderer');
  if (items.isNotEmpty) {
    final token = _s(
        _o(_o(items.first, 'continuationEndpoint'), 'continuationCommand'),
        'token');
    if (token != null) return token;
  }
  // Older shape: a bare nextContinuationData value anywhere in the tree.
  String? found;
  void walk(dynamic node) {
    if (found != null) return;
    if (node is Map) {
      final v = node['nextContinuationData'];
      if (v is Map) found = _s(v, 'continuation');
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(root);
  return found;
}

/// One page of song search results.
class SearchSongsPage {
  final List<Track> tracks;
  final String? continuation;
  const SearchSongsPage(this.tracks, this.continuation);
}

/// Search (songs) parsing from a raw `search` response
/// (Kotlin: InnertubeParser.parseSearchPage with rows reduced to songs —
/// browse rows for albums/artists/playlists are the catalogue layer's job
/// and are skipped here, exactly as YtMusic.search(SONGS) only takes the
/// Track rows).
SearchSongsPage parseSearchSongsPage(Map<String, dynamic> response,
    {bool includeVideos = false}) {
  final seen = <String>{};
  final tracks = <Track>[];

  void addSong(_ParsedSong? song) {
    if (song == null) return;
    if (song.isVideo != includeVideos) return;
    if (seen.add(song.track.id)) tracks.add(song.track);
  }

  // The promoted top result lives on a card shelf, not in a row.
  if (!includeVideos) {
    for (final card in _collectRenderers(response, 'musicCardShelfRenderer')) {
      addSong(_parseCardShelfSong(card));
    }
  }
  for (final row in _collectRenderers(response, 'musicResponsiveListItemRenderer')) {
    // A row with a browse endpoint is an album/artist/playlist card, not a
    // song (an album row also carries a "play album" videoId in its
    // overlay, so browse rows must be tested first — Kotlin does the same).
    final browseId = _s(
        _o(_o(row, 'navigationEndpoint'), 'browseEndpoint'), 'browseId');
    if (browseId != null) continue;
    addSong(_parseResponsiveListItem(row));
  }
  return SearchSongsPage(tracks, _continuationToken(response));
}

/// Just the songs of a search response (Kotlin: parseSearchSongs).
List<Track> parseSearchSongs(Map<String, dynamic> response) =>
    parseSearchSongsPage(response).tracks;

// ---------------------------------------------------------------------------
// Stream formats + resolver (Kotlin: yt/YtStreams.kt essentials)
// ---------------------------------------------------------------------------

/// Quality setting for the Dart resolver. Mirrors the Kotlin Quality caps
/// used by YtFormats.rank (models/Quality lives with the Track port).
enum YtQuality { auto, high, max, lossless }

/// One audio rendition YouTube offers. (Kotlin: YtAudio.)
class YtAudio {
  final int itag;
  final String mime;
  final int bitrate;
  final String? url;
  final int? sampleRate;
  final int? contentLength;

  /// `signatureCipher` (or legacy `cipher`) query string for formats
  /// without a plain [url]. NOT solvable in Dart — see the file header.
  final String? cipher;

  const YtAudio({
    required this.itag,
    required this.mime,
    required this.bitrate,
    this.url,
    this.sampleRate,
    this.contentLength,
    this.cipher,
  });

  bool get opus => mime.contains('opus');
  int get kbps => bitrate ~/ 1000;
  String get codec {
    if (opus) return 'Opus';
    if (mime.contains('mp4a')) return 'AAC';
    final afterSlash = mime.split('/').last;
    final semi = afterSlash.indexOf(';');
    return semi < 0 ? afterSlash : afterSlash.substring(0, semi);
  }

  YtAudio copyWith({String? url}) => YtAudio(
        itag: itag,
        mime: mime,
        bitrate: bitrate,
        url: url ?? this.url,
        sampleRate: sampleRate,
        contentLength: contentLength,
        cipher: cipher,
      );
}

/// A resolved, playable stream. (Kotlin: YtResolved.)
class YtResolved {
  final String url;
  final Map<String, String> headers;
  final YtAudio audio;
  final String clientName;
  const YtResolved(this.url, this.headers, this.audio, this.clientName);
}

class YtFormats {
  YtFormats._();

  /// Premium-only higher renditions: 774 (Opus ~256k), 141 (AAC 256k).
  static const Set<int> premium = {774, 141};

  /// Ranks audio renditions for a quality setting. MAX/LOSSLESS (YouTube
  /// has no lossless) take the highest bitrate, preferring Opus at equal
  /// bitrate; HIGH caps at ~160 kbps; AUTO behaves as MAX on unmetered
  /// networks and HIGH on metered ones. (Kotlin: YtFormats.rank.)
  static List<YtAudio> rank(List<YtAudio> formats,
      {YtQuality quality = YtQuality.max, bool metered = false}) {
    final audio = formats.where((f) => f.mime.startsWith('audio/')).toList();
    final int cap;
    switch (quality) {
      case YtQuality.high:
        cap = 170;
      case YtQuality.auto:
        cap = metered ? 170 : 0x7fffffffffffffff;
      case YtQuality.max:
      case YtQuality.lossless:
        cap = 0x7fffffffffffffff;
    }
    final under = audio.where((f) => f.kbps <= cap).toList();
    final over = audio.where((f) => f.kbps > cap).toList();
    int bucket(YtAudio f) => (f.kbps < cap ? f.kbps : cap) ~/ 16;
    under.sort((a, b) {
      final byBucket = bucket(b).compareTo(bucket(a));
      if (byBucket != 0) return byBucket;
      if (a.opus != b.opus) return a.opus ? -1 : 1;
      return b.bitrate.compareTo(a.bitrate);
    });
    over.sort((a, b) => a.bitrate.compareTo(b.bitrate));
    return [...under, ...over];
  }

  /// The audio formats of a player response. (Kotlin: YtFormats.parse.)
  static List<YtAudio> parse(Map<String, dynamic> player) {
    final sd = _o(player, 'streamingData');
    final list = _a(sd, 'adaptiveFormats');
    if (sd == null || list == null) return const [];
    final out = <YtAudio>[];
    for (final e in list) {
      if (e is! Map) continue;
      final mime = _s(e, 'mimeType');
      if (mime == null || !mime.startsWith('audio/')) continue;
      out.add(YtAudio(
        itag: int.tryParse(_s(e, 'itag') ?? '') ?? 0,
        mime: mime,
        bitrate: int.tryParse(_s(e, 'bitrate') ?? '') ??
            int.tryParse(_s(e, 'averageBitrate') ?? '') ??
            0,
        url: _s(e, 'url'),
        sampleRate: int.tryParse(_s(e, 'audioSampleRate') ?? ''),
        contentLength: int.tryParse(_s(e, 'contentLength') ?? ''),
        cipher: _s(e, 'signatureCipher') ?? _s(e, 'cipher'),
      ));
    }
    return out;
  }

  /// Why a player response yielded no usable audio (Kotlin: YtFormats.describe).
  static String describe(Map<String, dynamic> player) {
    final ps = _o(player, 'playabilityStatus');
    final status = _s(ps, 'status') ?? '?';
    final reason = _s(ps, 'reason');
    final head = 'status $status${reason == null ? '' : ' ($reason)'}';
    final sd = _o(player, 'streamingData');
    if (sd == null) return '$head, no streamingData';
    final adaptive = _a(sd, 'adaptiveFormats') ?? const [];
    final muxed = (_a(sd, 'formats') ?? const []).length;
    final audioMaps =
        adaptive.whereType<Map>().where((o) => (_s(o, 'mimeType') ?? '').startsWith('audio/')).toList();
    final withUrl = audioMaps.where((o) => _s(o, 'url') != null).length;
    final withCipher = audioMaps
        .where((o) => _s(o, 'signatureCipher') != null || _s(o, 'cipher') != null)
        .length;
    final hls = _s(sd, 'hlsManifestUrl') != null;
    final sabr = _s(sd, 'serverAbrStreamingUrl') != null;
    return '$head, adaptive ${adaptive.length} (audio ${audioMaps.length}: '
        'url $withUrl, cipher $withCipher), muxed $muxed'
        '${hls ? ', HLS manifest only (not used)' : ''}'
        '${sabr ? ', SABR url' : ''}';
  }
}

/// Direct-Innertube stream resolution: walks the client list starting with
/// the client that last worked, takes the best-ranked format that carries
/// a plain URL, patches `cver`, waits for the URL to go live and proves it
/// with a ranged GET carrying the minting client's headers.
///
/// Deliberately NOT ported from the Kotlin resolver (needs the JVM /
/// NewPipeExtractor — see the file header): signature deciphering, the `n`
/// transform, and the NewPipe extraction fallback. Clients that only
/// answer with ciphered formats (ANDROID, signed-in WEB_REMIX) are
/// therefore skipped, with the reason recorded in the error list.
class YtStreamResolver {
  final Innertube tube;
  final http.Client _http;

  /// Fresh googlevideo URLs answer 403 for roughly 2–7 s after the player
  /// response; this passes before the first byte request.
  final int availabilityWaitMs;
  final Future<void> Function(Duration) _sleep;

  /// Stand-downs expire after 2 minutes (Kotlin v2.0.5).
  static const int standDownMs = 2 * 60 * 1000;
  static const int probeBytes = 16 * 1024;
  static const int maxAvailabilityWaitMs = 8000;
  static const Set<int> _refusalCodes = {403, 404, 410};

  /// OpenTune 1.0.4 StreamResolver.CLIENTS order.
  static List<PlayerClient> _clientList() => [
        PlayerClient.androidMusic,
        PlayerClient.tvHtml5,
        PlayerClient.androidVr,
        PlayerClient.androidVrLegacy,
        PlayerClient.ios,
        PlayerClient.iosRecent,
        PlayerClient.android,
      ];

  /// The client that served the last track; the walk starts there.
  PlayerClient? preferred;

  /// "videoId|client@version" → stood down until (epoch ms).
  final Map<String, int> _standDownUntil = {};

  YtStreamResolver(
    this.tube, {
    http.Client? client,
    this.availabilityWaitMs = 3000,
    Future<void> Function(Duration)? sleep,
  })  : _http = client ?? http.Client(),
        _sleep = sleep ?? ((d) => Future.delayed(d));

  String _key(String videoId, PlayerClient c) =>
      '$videoId|${c.clientName}@${c.clientVersion}';

  bool isStoodDown(String videoId, PlayerClient c) {
    final until = _standDownUntil[_key(videoId, c)];
    if (until == null) return false;
    if (until > DateTime.now().millisecondsSinceEpoch) return true;
    _standDownUntil.remove(_key(videoId, c));
    return false;
  }

  void _standDown(String videoId, PlayerClient c) {
    if (_standDownUntil.length > 512) _standDownUntil.clear();
    _standDownUntil[_key(videoId, c)] =
        DateTime.now().millisecondsSinceEpoch + standDownMs;
    if (preferred == c) preferred = null;
  }

  void clearStandDowns(String videoId) =>
      _standDownUntil.removeWhere((k, _) => k.startsWith('$videoId|'));

  /// Walk order: the preferred client first, then the client list, then
  /// WEB_REMIX with the session when signed in.
  List<PlayerClient> clientOrder({bool? signedIn}) {
    final base = _clientList()
      ..addAll((signedIn ?? tube.signedIn)
          ? [PlayerClient.webRemix]
          : const <PlayerClient>[]);
    final first = preferred;
    if (first == null || !base.contains(first)) return base;
    return [first, ...base.where((c) => c != first)];
  }

  Future<YtResolved> resolve(
    String videoId, {
    YtQuality quality = YtQuality.max,
    bool metered = false,
    bool probe = true,
  }) async {
    final errors = <String>[];
    final signedIn = tube.signedIn;
    try {
      await tube.ensureVisitorData();
    } catch (_) {}
    var tried = 0;
    // When every client is stood down for this track, clear the
    // stand-downs once and walk again once (Kotlin v2.0.5).
    for (var pass = 0; pass <= 1; pass++) {
      if (pass == 1) {
        if (tried > 0) break;
        clearStandDowns(videoId);
      }
      for (final client in clientOrder(signedIn: signedIn)) {
        if (isStoodDown(videoId, client)) {
          errors.add('${client.clientName}: stood down');
          continue;
        }
        tried++;
        if (client.needsSignatureTimestamp) {
          // Kotlin asks NewPipe's JS player for the timestamp and skips
          // the client without one; Dart has no JS solver, so these
          // clients (ANDROID, signed-in WEB_REMIX) cannot be used here.
          errors.add(
              '${client.clientName}: needs signature timestamp + cipher solver (NewPipe/Java, not portable)');
          continue;
        }
        final auth = signedIn &&
            (client == PlayerClient.androidMusic ||
                client == PlayerClient.webRemix);
        Map<String, dynamic> res;
        try {
          res = await tube.player(videoId, client, authenticated: auth);
        } on UnplayableException catch (e) {
          errors.add('${client.clientName}: $e');
          if (e.isPermanent) {
            throw YtExhaustedException(
                'YouTube: no playable stream (${errors.join('; ')})');
          }
          _standDown(videoId, client);
          continue;
        } catch (e) {
          errors.add('${client.clientName}: $e');
          continue;
        }
        final ranked = YtFormats.rank(YtFormats.parse(res),
                quality: quality, metered: metered)
            .where((a) => a.url != null || a.cipher != null)
            .toList();
        if (ranked.isEmpty) {
          errors.add(
              '${client.clientName}: no audio formats (${YtFormats.describe(res)})');
          _standDown(videoId, client);
          continue;
        }
        final plain = ranked.where((a) => a.url != null).toList();
        final picked = plain.isEmpty ? null : plain.first;
        if (picked == null) {
          errors.add(
              '${client.clientName}: formats ciphered only (cannot decipher in Dart)');
          _standDown(videoId, client);
          continue;
        }
        var url = picked.url!;
        url = _patchClientVersion(url, client.clientVersion);
        final headers = client.mediaHeaders();
        if (probe) {
          final waitMs = availabilityWaitMs < 0
              ? 0
              : (availabilityWaitMs > maxAvailabilityWaitMs
                  ? maxAvailabilityWaitMs
                  : availabilityWaitMs);
          await _sleep(Duration(milliseconds: waitMs));
          var verdict = await _probe(url, headers);
          if (verdict == _Probe.refused) {
            // A URL probed a moment too early answers 403 too: wait once
            // more before blaming the client.
            await _sleep(Duration(milliseconds: availabilityWaitMs));
            verdict = await _probe(url, headers);
          }
          if (verdict == _Probe.refused) {
            errors.add('${client.clientName}: stream refused (403)');
            _standDown(videoId, client);
            continue;
          }
          if (verdict == _Probe.unreachable) {
            errors.add('${client.clientName}: stream unreachable');
            continue;
          }
        }
        preferred = client;
        return YtResolved(url, headers, picked.copyWith(url: url), client.clientName);
      }
    }
    throw YtExhaustedException(
        'YouTube: no playable stream (${_truncate(errors.join('; '), 400)})');
  }

  /// Playback got a 403/404/410 from a URL this resolver handed out: stand
  /// its minting client down for that track. (The Kotlin version also
  /// remembers every minted URL; here the client is read off the URL's
  /// `c=` parameter, which is what PlayerClient.forStreamUrl is for.)
  void onPlaybackRefused(String url, {String? videoId}) {
    final client = PlayerClient.forStreamUrl(url);
    if (videoId != null) _standDown(videoId, client);
    if (preferred == client) preferred = null;
  }

  /// 16 KB ranged GET with the player's exact headers: OK only for 2xx +
  /// an audio content type. (Kotlin: YtStreamResolver.probe.)
  Future<_Probe> _probe(String url, Map<String, String> headers) async {
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(headers);
      req.headers['Range'] = 'bytes=0-${probeBytes - 1}';
      req.headers['Accept-Encoding'] = 'identity';
      final r = await _http
          .send(req)
          .timeout(const Duration(seconds: 8));
      final code = r.statusCode;
      if (_refusalCodes.contains(code)) return _Probe.refused;
      if (code < 200 || code > 299) return _Probe.unreachable;
      final ct = r.headers['content-type'] ?? '';
      if (!ct.startsWith('audio/')) return _Probe.refused;
      return _Probe.ok;
    } catch (_) {
      return _Probe.unreachable;
    }
  }

  /// Duration in ms from a player response, when present.
  static int? lengthMs(Map<String, dynamic> player) {
    final seconds =
        _s(_o(player, 'videoDetails'), 'lengthSeconds');
    final v = seconds == null ? null : int.tryParse(seconds);
    return v == null ? null : v * 1000;
  }

  /// Align `cver` with the client that asked; googlevideo answers a
  /// mismatched version with 403.
  static String _patchClientVersion(String url, String clientVersion) {
    if (!url.contains('cver=')) return url;
    return url.replaceAll(
        RegExp(r'cver=[^&]+'), 'cver=$clientVersion');
  }
}

enum _Probe { ok, refused, unreachable }

String _truncate(String s, int n) => s.length <= n ? s : s.substring(0, n);

// ---------------------------------------------------------------------------
// YouTube Music catalogue facade (Kotlin: YtMusic.kt essentials)
// ---------------------------------------------------------------------------

/// The parts of YtMusic this layer needs: song search, the plain YTM
/// lyrics (which wire straight into lyrics_repository's YtLyricsProvider),
/// and stream resolution for a Track.
class YtMusic {
  final Innertube tube;
  final YtStreamResolver resolver;

  YtMusic(this.tube, {YtStreamResolver? resolver})
      : resolver = resolver ?? YtStreamResolver(tube);

  /// Song search (Kotlin: YtMusic.search with SearchFilter.SONGS, then the
  /// MusicSource search taking the first [limit] tracks).
  Future<List<Track>> searchSongs(String query, {int limit = 20}) async {
    final page = parseSearchSongsPage(
        await tube.search(query, params: SearchFilter.songs.params));
    return page.tracks.take(limit).toList();
  }

  /// Radio / autoplay: YouTube Music's watch-next queue seeded by [videoId].
  ///
  /// Simplified: the Kotlin parser reads `playlistPanelVideoRenderer` rows
  /// (InnertubeParser.parseWatchQueue, not ported in this layer); this
  /// reads responsive list rows when the response carries them.
  Future<List<Track>> radio(String videoId) async {
    final res = await tube.next(videoId);
    final out = <Track>[];
    final seen = <String>{};
    for (final row
        in _collectRenderers(res, 'musicResponsiveListItemRenderer')) {
      final song = _parseResponsiveListItem(row);
      if (song == null) continue;
      final id = song.track.id.substring(3);
      if (id == videoId) continue;
      if (seen.add(song.track.id)) out.add(song.track);
    }
    return out;
  }

  /// YouTube Music's own (plain, unsynced) lyrics, with the provider
  /// credit it shows. Returns the record shape YtLyricsProvider expects.
  Future<({String text, String? source})?> lyrics(String videoId) async {
    final nextRes = await tube.next(videoId, includePlaylist: false);
    final browseId = _tabBrowseId(nextRes, 'MUSIC_PAGE_TYPE_TRACK_LYRICS');
    if (browseId == null) return null;
    final res = await tube.browse(browseId);
    ({String text, String? source})? found;
    void walk(dynamic node) {
      if (found != null) return;
      if (node is Map) {
        final shelf = node['musicDescriptionShelfRenderer'];
        if (shelf is Map) {
          final text = _runs(_o(shelf, 'description'));
          if (text.isNotEmpty) {
            final credit = _runs(_o(shelf, 'footer'));
            found = (
              text: text,
              source: credit.isEmpty ? null : credit,
            );
            return;
          }
        }
        node.values.forEach(walk);
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    walk(res);
    return found;
  }

  static String? _tabBrowseId(Map<String, dynamic> next, String pageType) {
    String? id;
    void walk(dynamic node) {
      if (id != null) return;
      if (node is Map) {
        final be = node['browseEndpoint'];
        if (be is Map) {
          final type = _s(
              _o(_o(be, 'browseEndpointContextSupportedConfigs'),
                  'browseEndpointContextMusicConfig'),
              'pageType');
          if (type == pageType) id = _s(be, 'browseId');
        }
        node.values.forEach(walk);
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    walk(next);
    return id;
  }

  /// Resolve a YouTube track to a playable stream
  /// (Kotlin: YtMusic.resolve via YtStreamResolver).
  Future<YtResolved> resolveTrack(
    Track track, {
    YtQuality quality = YtQuality.max,
    bool metered = false,
  }) {
    final videoId =
        track.id.startsWith('yt:') ? track.id.substring(3) : track.id;
    return resolver.resolve(videoId, quality: quality, metered: metered);
  }

  /// Playback was refused on a URL this source handed out.
  void onPlaybackRefused(String url, {String? videoId}) =>
      resolver.onPlaybackRefused(url, videoId: videoId);
}
