// YouTube as a MusicSource — adapter over the ported Innertube layer
// (lib/yt/innertube.dart). The Kotlin app wires YtMusic into its source
// registry the same way; this adapter keeps SourceManager source-agnostic.
//
// Limit (from REWRITE_MAP.md): direct Innertube API path only —
// NewPipeExtractor is a Java library and cannot run in Dart, so
// cipher-only formats are skipped by the resolver itself.

import '../models/track.dart';
import '../yt/innertube.dart';
import 'music_source.dart';

class YouTubeSource implements MusicSource {
  YouTubeSource({required bool Function() enabled, YtMusic? music})
      : _enabled = enabled,
        _music = music ?? YtMusic(Innertube());

  final bool Function() _enabled;
  final YtMusic _music;

  YtMusic get music => _music;

  @override
  SourceKind get kind => SourceKind.youtube;

  @override
  bool available() => _enabled();

  @override
  Future<List<Track>> search(String query, [int limit = 20]) =>
      _music.searchSongs(query, limit: limit);

  @override
  Future<Resolved> resolve(Track track, Quality quality, bool metered) async {
    final r = await _music.resolveTrack(track, metered: metered);
    return Resolved(
      uri: r.url,
      headers: r.headers,
      cacheKey: 'yt:${track.id}:${r.audio.itag}',
      info: StreamInfo(
        source: SourceKind.youtube,
        codec: r.audio.mime.contains('opus') ? 'opus' : 'aac',
        bitrateKbps: (r.audio.bitrate / 1000).round(),
        sampleRateHz: r.audio.sampleRate,
        sourceTrackId: track.id,
      ),
    );
  }

  @override
  Future<String> probe() async {
    final tracks = await _music.searchSongs('test', limit: 1);
    return 'YouTube search OK (${tracks.length} result)';
  }
}
