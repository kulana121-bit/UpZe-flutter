// Port of source/LocalSource.kt (UpZe v1.0.1): music on the device.
//
// The Kotlin reads MediaStore directly (IS_MUSIC != 0, sorted by title
// COLLATE NOCASE) and asks for the runtime permission only when the user
// turns the source on. This port does the same through the native
// `upze/media` channel (MediaBridge.kt) — the on_audio_query plugin it
// first used is unmaintained and its Android library has no AGP-8
// namespace, which fails modern Gradle builds.
//
// PERMISSIONS: this port does NOT request anything: the caller grants
// the right permission (via permission_handler — READ_MEDIA_AUDIO on
// API 33+, READ_EXTERNAL_STORAGE below; see [LocalSource.permissionForSdk])
// and reports it through the `hasPermission` constructor callback;
// [available] mirrors the Kotlin's `enabled() && hasPermission()`.
//
// Search uses a local copy of logic/SearchFilter (Logic.kt) — there is no
// Dart port of Logic.kt yet. Its accent folding is approximated (dart:core
// has no Unicode Normalizer; same stdlib limit the lyrics port records):
// common precomposed Latin accents fold to their base letter, everything
// else follows the Kotlin's rules exactly.

import 'package:flutter/services.dart';

import '../models/track.dart';
import 'music_source.dart';

class LocalSource implements MusicSource {
  LocalSource({
    required bool Function() enabled,
    required bool Function() hasPermission,
  })  : _enabled = enabled,
        _hasPermission = hasPermission;

  static const _channel = MethodChannel('upze/media');

  final bool Function() _enabled;
  final bool Function() _hasPermission;

  List<Track> _tracks = const [];

  @override
  SourceKind get kind => SourceKind.local;

  /// The last scan's tracks (Kotlin: the `tracks` StateFlow's value).
  List<Track> get tracks => _tracks;

  /// The runtime permission the Kotlin asks for on this SDK level.
  static String permissionForSdk(int sdkInt) => sdkInt >= 33
      ? 'android.permission.READ_MEDIA_AUDIO'
      : 'android.permission.READ_EXTERNAL_STORAGE';

  @override
  bool available() => _enabled() && _hasPermission();

  /// A full device scan (Kotlin: scan). No permission → empty list, and a
  /// query failure (permission revoked mid-scan, provider error) is also
  /// treated as "no tracks", like the Kotlin's guarded cursor query.
  Future<List<Track>> scan() async {
    if (!_hasPermission()) return const [];
    final List<dynamic> rows;
    try {
      rows = await _channel.invokeMethod<List<dynamic>>('songs') ?? const [];
    } catch (_) {
      _tracks = const [];
      return _tracks;
    }
    final out = <Track>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final id = (row['id'] as num?)?.toInt();
      if (id == null) continue;
      final artist = row['artist'] as String?;
      final albumId = (row['albumId'] as num?)?.toInt();
      final year = (row['year'] as num?)?.toInt() ?? 0;
      out.add(Track(
        id: 'local:$id',
        title: (row['title'] as String?) ?? '',
        artist: (artist == null || artist == '<unknown>') ? '' : artist,
        album: row['album'] as String?,
        durationMs: (row['duration'] as num?)?.toInt() ?? 0,
        artUrl: albumId == null
            ? null
            : 'content://media/external/audio/albumart/$albumId',
        albumId: albumId == null ? null : 'local:al:$albumId',
        year: year > 0 ? year.toString() : null,
        format: formatOfMime((row['mime'] as String?) ?? ''),
      ));
    }
    _tracks = out;
    return out;
  }

  @override
  Future<List<Track>> search(String query, [int limit = 20]) async {
    if (!available()) return const [];
    final all = _tracks.isEmpty ? await scan() : _tracks;
    return _SearchFilter.filter(query, all).take(limit).toList();
  }

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final id = int.tryParse(track.nativeId) ??
        (throw SourceUnavailableException('bad local id'));
    // ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI)
    final uri = 'content://media/external/audio/media/$id';
    // Codec/bitrate/sample rate are filled from the decoder's Format once
    // the player has read the file (same note as the Kotlin).
    return Resolved(
      uri: uri,
      info: StreamInfo(
        source: kind,
        codec: track.format?.toUpperCase(),
        sourceTrackId: track.id,
      ),
      cacheKey: track.id,
    );
  }

  @override
  Future<String> probe() async {
    if (!_hasPermission()) {
      throw SourceUnavailableException('permission not granted');
    }
    return '${(await scan()).length} tracks on device';
  }

  /// The Kotlin companion's exact MIME → format mapping.
  static String? formatOfMime(String mime) {
    if (mime.contains('flac')) return 'flac';
    if (mime.contains('wav') || mime.contains('x-wav')) return 'wav';
    if (mime.contains('alac')) return 'alac';
    if (mime.contains('aiff')) return 'aiff';
    if (mime.contains('mpeg') || mime.contains('mp3')) return 'mp3';
    if (mime.contains('mp4') || mime.contains('m4a') || mime.contains('aac')) {
      return 'm4a';
    }
    if (mime.contains('ogg') || mime.contains('opus')) return 'ogg';
    final after = mime.contains('/') ? mime.substring(mime.indexOf('/') + 1) : mime;
    return after.isEmpty ? null : after;
  }
}

/// logic/SearchFilter (Logic.kt), specialised for Track fields
/// (title / artist / album-or-empty), as LocalSource.search uses it.
abstract final class _SearchFilter {
  static final RegExp _nonWord = RegExp(r'[^a-z0-9 ]');
  static final RegExp _spaces = RegExp(r'\s+');

  // Precomposed Latin accents → base letter (approximation of the Kotlin's
  // Normalizer NFD + combining-mark strip; see the file header).
  static final Map<int, String> _fold = () {
    final m = <int, String>{};
    void add(String chars, String base) {
      for (final r in chars.toLowerCase().runes) {
        m[r] = base;
      }
    }

    add('àáâãäåāăąǎȁȃạảấầẩẫậắằẳẵặ', 'a');
    add('çćĉċč', 'c');
    add('ďđð', 'd');
    add('èéêëēĕėęěȅȇẹẻẽếềểễệ', 'e');
    add('ĝğġģ', 'g');
    add('ĥħ', 'h');
    add('ìíîïĩīĭįıǐȉȋịỉ', 'i');
    add('ĵ', 'j');
    add('ķ', 'k');
    add('ĺļľŀł', 'l');
    add('ñńņňŉ', 'n');
    add('òóôõöøōŏőơǒǿȍȏọỏốồổỗộớờởỡợơ', 'o');
    add('ŕŗř', 'r');
    add('śŝşšș', 's');
    add('ţťŧț', 't');
    add('ùúûüũūŭůűųǔȕȗụủứừửữự', 'u');
    add('ýÿŷ', 'y');
    add('źżž', 'z');
    return m;
  }();

  static String normalize(String s) {
    final b = StringBuffer();
    for (final r in s.toLowerCase().runes) {
      b.write(_fold[r] ?? String.fromCharCode(r));
    }
    return b
        .toString()
        .replaceAll('&', ' and ')
        .replaceAll(_nonWord, ' ')
        .replaceAll(_spaces, ' ')
        .trim();
  }

  /// Score > 0 when every token matches somewhere; higher is better.
  static int score(String query, Track t) {
    final q = normalize(query);
    if (q.isEmpty) return 0;
    final title = normalize(t.title);
    final artist = normalize(t.artist);
    final album = normalize(t.album ?? '');
    var total = 0;
    for (final tok in q.split(' ')) {
      final int s;
      if (title == q) {
        s = 120;
      } else if (title.startsWith(tok)) {
        s = 60;
      } else if (title.split(' ').any((w) => w.startsWith(tok))) {
        s = 45;
      } else if (artist.split(' ').any((w) => w.startsWith(tok))) {
        s = 35;
      } else if (album.split(' ').any((w) => w.startsWith(tok))) {
        s = 25;
      } else if (title.contains(tok)) {
        s = 15;
      } else if (artist.contains(tok) || album.contains(tok)) {
        s = 10;
      } else {
        return 0;
      }
      total += s;
    }
    return total;
  }

  static List<Track> filter(String query, List<Track> items) {
    if (normalize(query).isEmpty) return const [];
    final scored = items
        .map((t) => (t, score(query, t)))
        .where((p) => p.$2 > 0)
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return scored.map((p) => p.$1).toList();
  }
}
