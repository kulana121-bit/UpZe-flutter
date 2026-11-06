// Port of source/MusicSource.kt (UpZe v1.0.1, com.ravi.musicspot).
//
// The MusicSource contract every catalogue/stream backend implements, the
// Resolved value handed to the player, and the small shared helpers the
// Kotlin file carries (parseClock, unescapeHtml, StreamProbe).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/track.dart';

/// Browser user-agent the Kotlin app sends to catalogue APIs (Http.BROWSER_UA).
const String browserUa =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/141.0.0.0 Mobile Safari/537.36';

/// Optional diagnostics sink (stands in for Kotlin's PlaybackLog). The UI /
/// diagnostics layer may set this; sources and the router log through it.
void Function(String message)? sourceLogger;

void logSource(String message) => sourceLogger?.call(message);

/// What a source hands the player for one track. [uri] is https://,
/// content:// or file://.
class Resolved {
  const Resolved({
    required this.uri,
    required this.info,
    this.headers = const {},
    required this.cacheKey,
    this.fallbackFrom,
  });

  final String uri;
  final StreamInfo info;
  final Map<String, String> headers;

  /// Stable cache key for these exact bytes (source + id + rendition).
  final String cacheKey;

  /// Set when this plays from another source because [fallbackFrom]
  /// (YouTube) was exhausted or excluded.
  final SourceKind? fallbackFrom;

  Resolved copyWith({
    String? uri,
    StreamInfo? info,
    Map<String, String>? headers,
    String? cacheKey,
    SourceKind? fallbackFrom,
  }) {
    return Resolved(
      uri: uri ?? this.uri,
      info: info ?? this.info,
      headers: headers ?? this.headers,
      cacheKey: cacheKey ?? this.cacheKey,
      fallbackFrom: fallbackFrom ?? this.fallbackFrom,
    );
  }
}

abstract class MusicSource {
  SourceKind get kind;

  /// Whether the user has this source switched on and configured.
  bool available();

  Future<List<Track>> search(String query, [int limit = 20]);

  Future<Resolved> resolve(Track track, Quality quality, bool metered);

  /// A cheap real request used by Diagnostics; returns a short description
  /// of what answered.
  Future<String> probe();
}

class SourceUnavailableException extends IOException {
  SourceUnavailableException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'SourceUnavailableException: $message';
}

/// Parses "3:45" / "1:02:03" into ms.
int parseClock(String? text) {
  if (text == null || text.trim().isEmpty) return 0;
  final parts = text
      .trim()
      .split(':')
      .map((p) => int.tryParse(p.trim()))
      .whereType<int>()
      .toList();
  if (parts.isEmpty) return 0;
  return parts.fold<int>(0, (acc, p) => acc * 60 + p) * 1000;
}

/// HTML entity cleanup for catalog APIs that return escaped titles
/// (JioSaavn).
String unescapeHtml(String? s) => (s ?? '')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// Status of a 2-byte ranged GET of a resolved stream (local/file URIs are
/// not probed). Kotlin: StreamProbe in MusicSource.kt (v2.0.4).
abstract final class StreamProbe {
  static Future<int?> status(Resolved r) async {
    if (!r.uri.startsWith('https://')) return null;
    try {
      final resp = await http
          .get(
            Uri.parse(r.uri),
            headers: {'Range': 'bytes=0-1', ...r.headers},
          )
          .timeout(const Duration(seconds: 6));
      return resp.statusCode;
    } catch (_) {
      return null;
    }
  }
}

/// GET [url] and JSON-decode the body, with a whole-call timeout.
/// Throws [SourceUnavailableException] on HTTP errors / invalid JSON so
/// callers can fail over uniformly (the Kotlin Http layer throws
/// IOException subclasses the same way).
Future<Object?> getJson(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final http.Response resp;
  try {
    resp = await http.get(Uri.parse(url), headers: headers).timeout(timeout);
  } on TimeoutException {
    throw SourceUnavailableException('Timed out fetching $url');
  } catch (e) {
    throw SourceUnavailableException('Fetch failed for $url', e);
  }
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw SourceUnavailableException('HTTP ${resp.statusCode} for $url');
  }
  try {
    return resp.body.isEmpty ? null : jsonDecode(resp.body);
  } on FormatException catch (e) {
    throw SourceUnavailableException('Invalid JSON from $url', e);
  }
}
