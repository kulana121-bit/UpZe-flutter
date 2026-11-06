// Port of model/Track.kt (UpZe v1.0.1, com.ravi.musicspot.model).
// Pure Dart — no Flutter imports.
import 'dart:convert';

const Object _unset = Object();

/// Where a track (or a match for it) can be played from.
/// Order here is only the default priority. (Kotlin: SourceKind)
enum SourceKind {
  youtube('YouTube Music', 'yt'),
  jiosaavn('JioSaavn', 'js'),
  audius('Audius', 'au'),
  soundcloud('SoundCloud', 'sc'),
  jamendo('Jamendo', 'jm'),
  archive('Internet Archive', 'ia'),
  local('On this device', 'local'),
  subsonic('Subsonic / Navidrome', 'sub'),
  jellyfin('Jellyfin', 'jf'),
  spotify('Spotify (metadata only)', 'sp');

  const SourceKind(this.label, this.prefix);

  final String label;
  final String prefix;

  bool get playable => this != SourceKind.spotify;

  /// Kotlin: SourceKind.ofId — first kind whose "<prefix>:" starts the id,
  /// falling back to YOUTUBE.
  static SourceKind ofId(String id) {
    for (final kind in SourceKind.values) {
      if (id.startsWith('${kind.prefix}:')) return kind;
    }
    return SourceKind.youtube;
  }

  /// kotlinx.serialization writes enum constants by name ("YOUTUBE", ...).
  String get serializedName => name.toUpperCase();

  static SourceKind fromSerializedName(String? value) {
    for (final kind in SourceKind.values) {
      if (kind.serializedName == value) return kind;
    }
    return SourceKind.youtube;
  }
}

/// User-facing quality setting. YouTube/JioSaavn top out at lossy 256–320 kbps;
/// Lossless only comes from FLAC/ALAC/WAV sources. (Kotlin: Quality)
/// The Kotlin enum has no explicit rank field — declaration order is the rank,
/// exposed here as [rank] (= index).
enum Quality {
  auto('Auto', 'Best on Wi-Fi, ~160 kbps on mobile data'),
  high('High', '~160 kbps Opus / 320 kbps AAC'),
  max('Max', 'Highest bitrate any source offers'),
  lossless('Lossless when available',
      'FLAC/ALAC/WAV from your files, servers and free FLAC catalogues; otherwise Max');

  const Quality(this.label, this.detail);

  final String label;
  final String detail;

  /// Rank in declaration order (AUTO=0 < HIGH=1 < MAX=2 < LOSSLESS=3).
  int get rank => index;

  String get serializedName => name.toUpperCase();

  static Quality fromSerializedName(String? value, [Quality fallback = Quality.auto]) {
    for (final q in Quality.values) {
      if (q.serializedName == value) return q;
    }
    return fallback;
  }
}

/// One song, from any source. [id] is "<prefix>:<native id>", e.g.
/// "yt:dQw4w9WgXcQ", "js:AbC123", "local:42", "sub:<serverId>:<id>",
/// "jf:<serverId>:<id>", "sp:<spotify id>" (metadata only; played via a match).
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs = 0,
    this.artUrl,
    this.artistId,
    this.albumId,
    this.explicit = false,
    this.year,
    this.isrc,
    this.format,
    this.bitrateKbps,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;

  /// Kotlin: Long durationMs.
  final int durationMs;
  final String? artUrl;
  final String? artistId;
  final String? albumId;
  final bool explicit;
  final String? year;

  /// ISRC when the source gives one (Spotify, some servers):
  /// the strongest cross-source match key.
  final String? isrc;

  /// Container/codec hint from the source listing ("flac", "mp3", "m4a",
  /// "alac"), when known before playback.
  final String? format;
  final int? bitrateKbps;

  SourceKind get source => SourceKind.ofId(id);

  /// Kotlin: id.substringAfter(':') — everything after the first ':'.
  String get nativeId {
    final i = id.indexOf(':');
    return i < 0 ? id : id.substring(i + 1);
  }

  Track copyWith({
    String? id,
    String? title,
    String? artist,
    Object? album = _unset,
    int? durationMs,
    Object? artUrl = _unset,
    Object? artistId = _unset,
    Object? albumId = _unset,
    bool? explicit,
    Object? year = _unset,
    Object? isrc = _unset,
    Object? format = _unset,
    Object? bitrateKbps = _unset,
  }) {
    return Track(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: identical(album, _unset) ? this.album : album as String?,
      durationMs: durationMs ?? this.durationMs,
      artUrl: identical(artUrl, _unset) ? this.artUrl : artUrl as String?,
      artistId: identical(artistId, _unset) ? this.artistId : artistId as String?,
      albumId: identical(albumId, _unset) ? this.albumId : albumId as String?,
      explicit: explicit ?? this.explicit,
      year: identical(year, _unset) ? this.year : year as String?,
      isrc: identical(isrc, _unset) ? this.isrc : isrc as String?,
      format: identical(format, _unset) ? this.format : format as String?,
      bitrateKbps: identical(bitrateKbps, _unset) ? this.bitrateKbps : bitrateKbps as int?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'artist': artist,
        if (album != null) 'album': album,
        'durationMs': durationMs,
        if (artUrl != null) 'artUrl': artUrl,
        if (artistId != null) 'artistId': artistId,
        if (albumId != null) 'albumId': albumId,
        'explicit': explicit,
        if (year != null) 'year': year,
        if (isrc != null) 'isrc': isrc,
        if (format != null) 'format': format,
        if (bitrateKbps != null) 'bitrateKbps': bitrateKbps,
      };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String?,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        artUrl: json['artUrl'] as String?,
        artistId: json['artistId'] as String?,
        albumId: json['albumId'] as String?,
        explicit: json['explicit'] as bool? ?? false,
        year: json['year'] as String?,
        isrc: json['isrc'] as String?,
        format: json['format'] as String?,
        bitrateKbps: (json['bitrateKbps'] as num?)?.toInt(),
      );

  String toJsonString() => jsonEncode(toJson());

  factory Track.fromJsonString(String source) =>
      Track.fromJson(jsonDecode(source) as Map<String, dynamic>);

  @override
  bool operator ==(Object other) =>
      other is Track &&
      other.id == id &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.durationMs == durationMs &&
      other.artUrl == artUrl &&
      other.artistId == artistId &&
      other.albumId == albumId &&
      other.explicit == explicit &&
      other.year == year &&
      other.isrc == isrc &&
      other.format == format &&
      other.bitrateKbps == bitrateKbps;

  @override
  int get hashCode => Object.hash(id, title, artist, album, durationMs, artUrl,
      artistId, albumId, explicit, year, isrc, format, bitrateKbps);

  @override
  String toString() => 'Track(id: $id, title: $title, artist: $artist)';
}

/// Kind of a [Collection]. (Kotlin: Collection.Kind — nested in the original;
/// Dart has no nested type declarations, so it lives at top level here.)
enum CollectionKind {
  album('ALBUM'),
  playlist('PLAYLIST'),
  artist('ARTIST'),
  mood('MOOD'),
  localPlaylist('LOCAL_PLAYLIST');

  const CollectionKind(this.serializedName);

  final String serializedName;

  static CollectionKind fromSerializedName(String? value) {
    for (final k in CollectionKind.values) {
      if (k.serializedName == value) return k;
    }
    return CollectionKind.playlist;
  }
}

/// A browsable collection (album, playlist, artist, mood) on some source.
/// (Kotlin: Collection in Track.kt)
class Collection {
  const Collection({
    required this.id,
    required this.kind,
    required this.title,
    this.subtitle,
    this.artUrl,
  });

  final String id;
  final CollectionKind kind;
  final String title;
  final String? subtitle;
  final String? artUrl;

  Collection copyWith({
    String? id,
    CollectionKind? kind,
    String? title,
    Object? subtitle = _unset,
    Object? artUrl = _unset,
  }) =>
      Collection(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        title: title ?? this.title,
        subtitle: identical(subtitle, _unset) ? this.subtitle : subtitle as String?,
        artUrl: identical(artUrl, _unset) ? this.artUrl : artUrl as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind.serializedName,
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        if (artUrl != null) 'artUrl': artUrl,
      };

  factory Collection.fromJson(Map<String, dynamic> json) => Collection(
        id: json['id'] as String,
        kind: CollectionKind.fromSerializedName(json['kind'] as String?),
        title: json['title'] as String,
        subtitle: json['subtitle'] as String?,
        artUrl: json['artUrl'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Collection &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.artUrl == artUrl;

  @override
  int get hashCode => Object.hash(id, kind, title, subtitle, artUrl);
}

/// A row of items on Home/Explore/Artist pages. (Kotlin: Shelf — not
/// @Serializable in the original, kept that way here apart from helpers.)
class Shelf {
  const Shelf({
    required this.title,
    this.tracks = const [],
    this.collections = const [],
    this.subtitle,
    this.moreId,
  });

  final String title;
  final List<Track> tracks;
  final List<Collection> collections;
  final String? subtitle;
  final String? moreId;

  Shelf copyWith({
    String? title,
    List<Track>? tracks,
    List<Collection>? collections,
    Object? subtitle = _unset,
    Object? moreId = _unset,
  }) =>
      Shelf(
        title: title ?? this.title,
        tracks: tracks ?? this.tracks,
        collections: collections ?? this.collections,
        subtitle: identical(subtitle, _unset) ? this.subtitle : subtitle as String?,
        moreId: identical(moreId, _unset) ? this.moreId : moreId as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'collections': collections.map((c) => c.toJson()).toList(),
        if (subtitle != null) 'subtitle': subtitle,
        if (moreId != null) 'moreId': moreId,
      };

  factory Shelf.fromJson(Map<String, dynamic> json) => Shelf(
        title: json['title'] as String,
        tracks: ((json['tracks'] as List?) ?? const [])
            .map((e) => Track.fromJson(e as Map<String, dynamic>))
            .toList(),
        collections: ((json['collections'] as List?) ?? const [])
            .map((e) => Collection.fromJson(e as Map<String, dynamic>))
            .toList(),
        subtitle: json['subtitle'] as String?,
        moreId: json['moreId'] as String?,
      );
}

/// What the player actually got for a track: real codec/bitrate as resolved
/// (and later refined by the player's Format). (Kotlin: StreamInfo)
class StreamInfo {
  const StreamInfo({
    required this.source,
    this.codec,
    this.bitrateKbps,
    this.sampleRateHz,
    this.sourceTrackId,
  });

  final SourceKind source;
  final String? codec;
  final int? bitrateKbps;
  final int? sampleRateHz;
  final String? sourceTrackId;

  /// Kotlin: buildString label — "YouTube Music · opus · 160 kbps · 48.0 kHz".
  String get label {
    final b = StringBuffer(source.label);
    if (codec != null) b.write(' · $codec');
    if (bitrateKbps != null) b.write(' · $bitrateKbps kbps');
    if (sampleRateHz != null) {
      b.write(' · ${(sampleRateHz! / 1000.0).toStringAsFixed(1)} kHz');
    }
    return b.toString();
  }

  StreamInfo copyWith({
    SourceKind? source,
    Object? codec = _unset,
    Object? bitrateKbps = _unset,
    Object? sampleRateHz = _unset,
    Object? sourceTrackId = _unset,
  }) =>
      StreamInfo(
        source: source ?? this.source,
        codec: identical(codec, _unset) ? this.codec : codec as String?,
        bitrateKbps:
            identical(bitrateKbps, _unset) ? this.bitrateKbps : bitrateKbps as int?,
        sampleRateHz:
            identical(sampleRateHz, _unset) ? this.sampleRateHz : sampleRateHz as int?,
        sourceTrackId: identical(sourceTrackId, _unset)
            ? this.sourceTrackId
            : sourceTrackId as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source.serializedName,
        if (codec != null) 'codec': codec,
        if (bitrateKbps != null) 'bitrateKbps': bitrateKbps,
        if (sampleRateHz != null) 'sampleRateHz': sampleRateHz,
        if (sourceTrackId != null) 'sourceTrackId': sourceTrackId,
      };

  factory StreamInfo.fromJson(Map<String, dynamic> json) => StreamInfo(
        source: SourceKind.fromSerializedName(json['source'] as String?),
        codec: json['codec'] as String?,
        bitrateKbps: (json['bitrateKbps'] as num?)?.toInt(),
        sampleRateHz: (json['sampleRateHz'] as num?)?.toInt(),
        sourceTrackId: json['sourceTrackId'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is StreamInfo &&
      other.source == source &&
      other.codec == codec &&
      other.bitrateKbps == bitrateKbps &&
      other.sampleRateHz == sampleRateHz &&
      other.sourceTrackId == sourceTrackId;

  @override
  int get hashCode =>
      Object.hash(source, codec, bitrateKbps, sampleRateHz, sourceTrackId);
}
