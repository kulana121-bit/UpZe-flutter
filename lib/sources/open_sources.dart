// Port of source/OpenSources.kt (UpZe v1.0.1): the open-catalogue sources.
//
//  * AudiusSource  — official open API, no key.
//  * JamendoSource — official API, user's own free client_id.
//  * ArchiveSource — Internet Archive public-domain / live recordings.
//
// NOT ported from OpenSources.kt: SoundCloudSource. The Kotlin original is
// built on NewPipeExtractor (Java) — there is no Dart equivalent (same hard
// limit the rewrite map records for YouTube/NewPipe), so it cannot be
// ported 1:1. SourceManager already keeps SoundCloud out of the automatic
// fallback for the same unreliability reason.

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

/// Audius: official open API (no key; app_name identifies the client).
/// Streams are MP3 up to 320 kbps.
class AudiusSource implements MusicSource {
  AudiusSource({required bool Function() enabled}) : _enabled = enabled;

  final bool Function() _enabled;
  String? _host;

  @override
  SourceKind get kind => SourceKind.audius;

  @override
  bool available() => _enabled();

  Future<String> _host_() async {
    final cached = _host;
    if (cached != null) return cached;
    // Discovery failure falls back to the public gateway instead of
    // failing search/play.
    String? discovered;
    try {
      final o = _asMap(await getJson('https://api.audius.co'));
      for (final e in _arr(o, 'data')) {
        if (e is String && e.startsWith('https://')) {
          discovered = e;
          break;
        }
      }
    } catch (_) {
      discovered = null;
    }
    return _host = discovered ?? 'https://api.audius.co';
  }

  @override
  Future<List<Track>> search(String query, [int limit = 20]) async {
    final host = await _host_();
    final url = Uri.parse('$host/v1/tracks/search').replace(
      queryParameters: {'query': query, 'app_name': appName, 'limit': '$limit'},
    );
    final o = _asMap(await getJson(url.toString()));
    if (o == null) return const [];
    final out = <Track>[];
    for ( final e in _arr(o, 'data')) {
      if (e is! Map) continue;
      final t = e.cast<String, dynamic>();
      final id = _s(t, 'id');
      if (id == null) continue;
      if (_s(t, 'is_streamable') == 'false') continue;
      out.add(Track(
        id: 'au:$id',
        title: _s(t, 'title') ?? '',
        artist: _s(_o(t, 'user'), 'name') ?? '',
        durationMs: (_l(t, 'duration') ?? 0) * 1000,
        artUrl: _s(_o(t, 'artwork'), '480x480') ?? _s(_o(t, 'artwork'), '150x150'),
        format: 'mp3',
      ));
    }
    return out;
  }

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final host = await _host_();
    final url = Uri.parse('$host/v1/tracks/${track.nativeId}/stream')
        .replace(queryParameters: {'app_name': appName});
    // Bitrate is refined from the decoder's Format once playback starts.
    return Resolved(
      uri: url.toString(),
      info: StreamInfo(source: kind, codec: 'MP3', sourceTrackId: track.id),
      cacheKey: 'au:${track.nativeId}',
    );
  }

  @override
  Future<String> probe() async =>
      '${(await search('lofi', 2)).length} results from ${await _host_()}';

  static const String appName = 'UpZe';
}

/// Jamendo: official API, free Creative Commons music. Needs the user's own
/// free client_id (developer.jamendo.com). FLAC when the artist allows
/// downloads (audiodlformat=flac), otherwise high-VBR MP3.
class JamendoSource implements MusicSource {
  JamendoSource({
    required String? Function() clientId,
    required bool Function() enabled,
  })  : _clientId = clientId,
        _enabled = enabled;

  final String? Function() _clientId;
  final bool Function() _enabled;

  @override
  SourceKind get kind => SourceKind.jamendo;

  @override
  bool available() {
    final id = _clientId();
    return _enabled() && id != null && id.isNotEmpty;
  }

  Uri _base(Map<String, String> extra) {
    final id = _clientId();
    if (id == null || id.isEmpty) {
      throw SourceUnavailableException(
          'Jamendo: add your client_id in Settings → Sources');
    }
    return Uri.parse('https://api.jamendo.com/v3.0/tracks/').replace(
      queryParameters: {
        'client_id': id,
        'format': 'json',
        'audioformat': 'mp32',
        'audiodlformat': 'flac',
        ...extra,
      },
    );
  }

  @override
  Future<List<Track>> search(String query, [int limit = 20]) async {
    final o = _asMap(await getJson(
        _base({'search': query, 'limit': '$limit'}).toString()));
    if (o == null) return const [];
    final out = <Track>[];
    for (final e in _arr(o, 'results')) {
      if (e is! Map) continue;
      final t = e.cast<String, dynamic>();
      final id = _s(t, 'id');
      if (id == null) continue;
      final flac = _s(t, 'audiodownload_allowed') == 'true';
      out.add(Track(
        id: 'jm:$id',
        title: _s(t, 'name') ?? '',
        artist: _s(t, 'artist_name') ?? '',
        album: _s(t, 'album_name'),
        durationMs: (_l(t, 'duration') ?? 0) * 1000,
        artUrl: _s(t, 'image'),
        format: flac ? 'flac' : 'mp3',
      ));
    }
    return out;
  }

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final o = _asMap(
        await getJson(_base({'id': track.nativeId}).toString()));
    final results = _arr(o, 'results');
    final t = results.isNotEmpty && results.first is Map
        ? (results.first as Map).cast<String, dynamic>()
        : null;
    if (t == null) throw SourceUnavailableException('Jamendo: not found');
    final wantFlac = (quality == Quality.lossless || quality == Quality.max) &&
        _s(t, 'audiodownload_allowed') == 'true';
    final raw = wantFlac ? _s(t, 'audiodownload') : _s(t, 'audio');
    if (raw == null) throw SourceUnavailableException('Jamendo: no audio');
    final url = raw.replaceFirst('http://', 'https://');
    return Resolved(
      uri: url,
      info: StreamInfo(
        source: kind,
        codec: wantFlac ? 'FLAC' : 'MP3',
        sourceTrackId: track.id,
      ),
      cacheKey: 'jm:${track.nativeId}@${wantFlac ? 'flac' : 'mp3'}',
    );
  }

  @override
  Future<String> probe() async => '${(await search('piano', 2)).length} results';
}

/// Internet Archive: public-domain and live recordings, FLAC where the
/// uploader provided it.
class ArchiveSource implements MusicSource {
  ArchiveSource({required bool Function() enabled}) : _enabled = enabled;

  final bool Function() _enabled;

  @override
  SourceKind get kind => SourceKind.archive;

  @override
  bool available() => _enabled();

  /// Items (concerts/albums) matching [query].
  Future<List<Collection>> searchItems(String query, [int rows = 20]) async {
    final url = Uri.parse('https://archive.org/advancedsearch.php').replace(
      queryParameters: {
        'q': '($query) AND mediatype:audio',
        'fl[]': ['identifier', 'title', 'creator'],
        'rows': '$rows',
        'output': 'json',
      },
    );
    final o = _asMap(await getJson(url.toString()));
    if (o == null) return const [];
    final docs = _arr(_o(o, 'response'), 'docs');
    final out = <Collection>[];
    for (final e in docs) {
      if (e is! Map) continue;
      final d = e.cast<String, dynamic>();
      final id = _s(d, 'identifier');
      if (id == null) continue;
      final creatorRaw = d['creator'];
      final creator = creatorRaw is String
          ? creatorRaw
          : (creatorRaw is List && creatorRaw.isNotEmpty
              ? creatorRaw.first?.toString()
              : null);
      out.add(Collection(
        id: 'ia:$id',
        kind: CollectionKind.album,
        title: _s(d, 'title') ?? id,
        subtitle: creator,
        artUrl: 'https://archive.org/services/img/$id',
      ));
    }
    return out;
  }

  /// Tracks in one item: original FLAC files preferred, otherwise VBR MP3
  /// derivatives.
  Future<(Collection, List<Track>)> item(String identifier) async {
    final o = _asMap(
        await getJson('https://archive.org/metadata/$identifier'));
    if (o == null) {
      throw SourceUnavailableException('Archive: item not found');
    }
    final meta = _o(o, 'metadata');
    final title = _s(meta, 'title') ?? identifier;
    final creator = _s(meta, 'creator') ?? '';
    final files = _arr(o, 'files')
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    bool isFlac(Map<String, dynamic> f) =>
        (_s(f, 'format') ?? '').toLowerCase().contains('flac');
    final flac = files.where(isFlac).toList();
    final chosen =
        flac.isNotEmpty ? flac : files.where((f) => _s(f, 'format') == 'VBR MP3').toList();
    int trackNo(Map<String, dynamic> f) {
      final t = _s(f, 'track');
      if (t == null) return 0x7fffffff;
      return int.tryParse(t.split('/').first) ?? 0x7fffffff;
    }

    chosen.sort((a, b) => trackNo(a).compareTo(trackNo(b)));
    final art = 'https://archive.org/services/img/$identifier';
    final tracks = <Track>[];
    for (final f in chosen) {
      final name = _s(f, 'name') ?? '';
      final lenRaw = _s(f, 'length');
      var durationMs = 0;
      if (lenRaw != null) {
        final secs = double.tryParse(lenRaw);
        durationMs =
            secs != null ? (secs * 1000).toInt() : parseClock(lenRaw);
      }
      final dot = name.lastIndexOf('.');
      tracks.add(Track(
        id: 'ia:$identifier/$name',
        title: _s(f, 'title') ?? (dot > 0 ? name.substring(0, dot) : name),
        artist: _s(f, 'creator') ?? creator,
        album: title,
        durationMs: durationMs,
        artUrl: art,
        albumId: 'ia:$identifier',
        format: isFlac(f) ? 'flac' : 'mp3',
      ));
    }
    return (
      Collection(
        id: 'ia:$identifier',
        kind: CollectionKind.album,
        title: title,
        subtitle: creator,
        artUrl: art,
      ),
      tracks,
    );
  }

  /// Items, not tracks: see [searchItems].
  @override
  Future<List<Track>> search(String query, [int limit = 20]) async =>
      const [];

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final path = track.nativeId
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return Resolved(
      uri: 'https://archive.org/download/$path',
      info: StreamInfo(
        source: kind,
        codec: track.format?.toUpperCase(),
        sourceTrackId: track.id,
      ),
      cacheKey: 'ia:${track.nativeId}',
    );
  }

  @override
  Future<String> probe() async =>
      '${(await searchItems('jazz', 2)).length} items';
}
