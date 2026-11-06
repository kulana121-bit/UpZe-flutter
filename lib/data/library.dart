// Port of data/Library.kt essentials (UpZe v1.0.1, com.ravi.musicspot.data).
// Pure Dart — persistence is a JSON file in a directory whose path is
// passed to the constructor (the app supplies it via path_provider).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/track.dart';

const Object _unset = Object();

/// Java/Kotlin String.hashCode(), so ids derived from it in the original
/// (upsertSynced playlist ids) match the Kotlin build's ids.
int _javaHashCode(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (31 * h + c) & 0xFFFFFFFF;
    if (h >= 0x80000000) h -= 0x100000000; // to signed 32-bit
  }
  return h;
}

String _base36Unsigned(int value) =>
    (value & 0xFFFFFFFF).toRadixString(36);

List<T> _listOf<T>(Object? v, T Function(Map<String, dynamic>) fromJson) =>
    ((v as List?) ?? const [])
        .map((e) => fromJson(e as Map<String, dynamic>))
        .toList();

/// (Kotlin: LocalPlaylist)
class LocalPlaylist {
  const LocalPlaylist({
    required this.id,
    required this.name,
    this.tracks = const [],
    this.origin = 'local',
    this.artUrl,
    this.syncedAtMs = 0,
  });

  final String id;
  final String name;
  final List<Track> tracks;

  /// "local", "spotify:<id>" (synced import), "yt:<browseId>" (YT Music
  /// playlist), "link:<url>" (shared-link import).
  final String origin;
  final String? artUrl;
  final int syncedAtMs;

  bool get isSynced => origin.startsWith('spotify:') || origin.startsWith('yt:');

  LocalPlaylist copyWith({
    String? id,
    String? name,
    List<Track>? tracks,
    String? origin,
    Object? artUrl = _unset,
    int? syncedAtMs,
  }) =>
      LocalPlaylist(
        id: id ?? this.id,
        name: name ?? this.name,
        tracks: tracks ?? this.tracks,
        origin: origin ?? this.origin,
        artUrl: identical(artUrl, _unset) ? this.artUrl : artUrl as String?,
        syncedAtMs: syncedAtMs ?? this.syncedAtMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'origin': origin,
        if (artUrl != null) 'artUrl': artUrl,
        'syncedAtMs': syncedAtMs,
      };

  factory LocalPlaylist.fromJson(Map<String, dynamic> json) => LocalPlaylist(
        id: json['id'] as String,
        name: json['name'] as String,
        tracks: _listOf(json['tracks'], Track.fromJson),
        origin: json['origin'] as String? ?? 'local',
        artUrl: json['artUrl'] as String?,
        syncedAtMs: (json['syncedAtMs'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is LocalPlaylist &&
      other.id == id &&
      other.name == name &&
      other.origin == origin &&
      other.artUrl == artUrl &&
      other.syncedAtMs == syncedAtMs &&
      _trackListsEqual(other.tracks, tracks);

  @override
  int get hashCode =>
      Object.hash(id, name, origin, artUrl, syncedAtMs, Object.hashAll(tracks));
}

bool _trackListsEqual(List<Track> a, List<Track> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// (Kotlin: HistoryEntry)
class HistoryEntry {
  const HistoryEntry({required this.track, required this.atMs, this.source});

  final Track track;
  final int atMs;
  final String? source;

  HistoryEntry copyWith({Track? track, int? atMs, Object? source = _unset}) =>
      HistoryEntry(
        track: track ?? this.track,
        atMs: atMs ?? this.atMs,
        source: identical(source, _unset) ? this.source : source as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'track': track.toJson(),
        'atMs': atMs,
        if (source != null) 'source': source,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        track: Track.fromJson(json['track'] as Map<String, dynamic>),
        atMs: (json['atMs'] as num?)?.toInt() ?? 0,
        source: json['source'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is HistoryEntry &&
      other.track == track &&
      other.atMs == atMs &&
      other.source == source;

  @override
  int get hashCode => Object.hash(track, atMs, source);
}

/// (Kotlin: LibraryData)
class LibraryData {
  const LibraryData({
    this.liked = const [],
    this.playlists = const [],
    this.saved = const [],
    this.history = const [],
    this.matches = const {},
  });

  final List<Track> liked;
  final List<LocalPlaylist> playlists;
  final List<Collection> saved;
  final List<HistoryEntry> history;

  /// Spotify track id → matched playable track (cache for Spotify sync).
  final Map<String, Track> matches;

  LibraryData copyWith({
    List<Track>? liked,
    List<LocalPlaylist>? playlists,
    List<Collection>? saved,
    List<HistoryEntry>? history,
    Map<String, Track>? matches,
  }) =>
      LibraryData(
        liked: liked ?? this.liked,
        playlists: playlists ?? this.playlists,
        saved: saved ?? this.saved,
        history: history ?? this.history,
        matches: matches ?? this.matches,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'liked': liked.map((t) => t.toJson()).toList(),
        'playlists': playlists.map((p) => p.toJson()).toList(),
        'saved': saved.map((c) => c.toJson()).toList(),
        'history': history.map((h) => h.toJson()).toList(),
        'matches': matches.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory LibraryData.fromJson(Map<String, dynamic> json) => LibraryData(
        liked: _listOf(json['liked'], Track.fromJson),
        playlists: _listOf(json['playlists'], LocalPlaylist.fromJson),
        saved: _listOf(json['saved'], Collection.fromJson),
        history: _listOf(json['history'], HistoryEntry.fromJson),
        matches: ((json['matches'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(
              k as String, Track.fromJson(v as Map<String, dynamic>)),
        ),
      );
}

/// The user's own data. Everything starts empty: no demo content.
/// (Kotlin: LibraryRepo — StateFlow replaced by a plain getter + listeners;
/// JsonFile's 800 ms debounce is approximated by coalescing writes.)
class LibraryRepo {
  LibraryRepo(String dirPath) : _file = File('$dirPath/library.json');

  final File _file;
  LibraryData _data = const LibraryData();
  final List<void Function()> _listeners = [];
  Timer? _saveTimer;

  LibraryData get data => _data;

  // --- convenience accessors over the Kotlin fields ---
  List<Track> get liked => _data.liked;
  List<LocalPlaylist> get playlists => _data.playlists;
  List<Collection> get saved => _data.saved;
  List<HistoryEntry> get history => _data.history;

  /// Most recently played tracks, newest first (history order in the
  /// original is newest-first already).
  List<Track> get recentlyPlayed => _data.history.map((h) => h.track).toList();

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          _data = LibraryData.fromJson(decoded);
        }
      }
    } catch (_) {
      // Corrupt file: start empty, like the original's null read.
    }
  }

  void _edit(LibraryData Function(LibraryData) f) {
    _data = f(_data);
    for (final l in List.of(_listeners)) {
      l();
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flush);
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_data.toJson()));
    } catch (_) {}
  }

  /// Force any pending debounced write to disk now.
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _flush();
    }
  }

  bool isLiked(String id) => _data.liked.any((t) => t.id == id);

  void setLiked(Track t, bool liked) => _edit((d) => d.copyWith(
        liked: liked
            ? [t, ...d.liked.where((x) => x.id != t.id)]
            : d.liked.where((x) => x.id != t.id).toList(),
      ));

  void mergeLiked(List<Track> tracks) => _edit((d) => d.copyWith(
        liked: [
          ...d.liked,
          ...tracks.where((t) => d.liked.every((x) => x.id != t.id)),
        ],
      ));

  LocalPlaylist createPlaylist(String name,
      {List<Track> tracks = const [],
      String origin = 'local',
      String? art}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final p = LocalPlaylist(
      id: 'pl-${now.toRadixString(36)}',
      name: name.trim().isEmpty ? 'New playlist' : name.trim(),
      tracks: tracks,
      origin: origin,
      artUrl: art,
      syncedAtMs: now,
    );
    _edit((d) => d.copyWith(playlists: [p, ...d.playlists]));
    return p;
  }

  /// Inserts or replaces the playlist with the same origin (sync),
  /// keeping its id.
  void upsertSynced(String origin, String name, List<Track> tracks, String? art) =>
      _edit((d) {
        LocalPlaylist? existing;
        for (final p in d.playlists) {
          if (p.origin == origin) {
            existing = p;
            break;
          }
        }
        final base = existing ??
            LocalPlaylist(
                id: 'pl-${_base36Unsigned(_javaHashCode(origin))}',
                name: name,
                origin: origin);
        final p = base.copyWith(
          name: name,
          tracks: tracks,
          artUrl: art,
          syncedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        return d.copyWith(
          playlists: existing != null
              ? d.playlists.map((x) => x.id == p.id ? p : x).toList()
              : [...d.playlists, p],
        );
      });

  void renamePlaylist(String id, String name) => _edit((d) => d.copyWith(
        playlists: d.playlists
            .map((p) => p.id == id
                ? p.copyWith(name: name.trim().isEmpty ? p.name : name.trim())
                : p)
            .toList(),
      ));

  void deletePlaylist(String id) => _edit((d) =>
      d.copyWith(playlists: d.playlists.where((p) => p.id != id).toList()));

  void removeSyncedFrom(String prefix) => _edit((d) => d.copyWith(
      playlists:
          d.playlists.where((p) => !p.origin.startsWith(prefix)).toList()));

  void addToPlaylist(String id, Track t) => _edit((d) => d.copyWith(
        playlists: d.playlists
            .map((p) => (p.id == id && p.tracks.every((x) => x.id != t.id))
                ? p.copyWith(tracks: [...p.tracks, t])
                : p)
            .toList(),
      ));

  void removeFromPlaylist(String id, String trackId) => _edit((d) => d.copyWith(
        playlists: d.playlists
            .map((p) => p.id == id
                ? p.copyWith(
                    tracks: p.tracks.where((x) => x.id != trackId).toList())
                : p)
            .toList(),
      ));

  void movePlaylistTrack(String id, int from, int to) => _edit((d) => d.copyWith(
        playlists: d.playlists.map((p) {
          if (p.id != id ||
              from < 0 ||
              from >= p.tracks.length ||
              to < 0 ||
              to >= p.tracks.length) {
            return p;
          }
          final tracks = [...p.tracks];
          tracks.insert(to, tracks.removeAt(from));
          return p.copyWith(tracks: tracks);
        }).toList(),
      ));

  LocalPlaylist? playlist(String id) {
    for (final p in _data.playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool isSaved(String id) => _data.saved.any((c) => c.id == id);

  void toggleSaved(Collection c) => _edit((d) => d.copyWith(
        saved: d.saved.any((x) => x.id == c.id)
            ? d.saved.where((x) => x.id != c.id).toList()
            : [c, ...d.saved],
      ));

  void mergeSaved(List<Collection> cs) => _edit((d) => d.copyWith(
        saved: [
          ...d.saved,
          ...cs.where((c) => d.saved.every((x) => x.id != c.id)),
        ],
      ));

  void recordPlay(Track t, String? source) => _edit((d) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final last = d.history.isEmpty ? null : d.history.first;
        if (last != null && last.track.id == t.id && now - last.atMs < 30000) {
          return d;
        }
        return d.copyWith(
          history: [HistoryEntry(track: t, atMs: now, source: source), ...d.history]
              .take(maxHistory)
              .toList(),
        );
      });

  void mergeHistory(List<Track> tracks) => _edit((d) {
        final known = d.history.map((h) => h.track.id).toSet();
        final now = DateTime.now().millisecondsSinceEpoch;
        final added = <HistoryEntry>[];
        var i = 0;
        for (final t in tracks) {
          if (known.add(t.id)) {
            added.add(HistoryEntry(
                track: t,
                atMs: now - 3600000 * (i + 1),
                source: 'YouTube Music history'));
            i++;
          }
        }
        final merged = [...d.history, ...added]
          ..sort((a, b) => b.atMs.compareTo(a.atMs));
        return d.copyWith(history: merged.take(maxHistory).toList());
      });

  void clearHistory() => _edit((d) => d.copyWith(history: const []));

  Track? cachedMatch(String spotifyId) => _data.matches[spotifyId];

  void rememberMatches(Map<String, Track> m) => _edit((d) {
        final entries = {...d.matches, ...m}.entries.toList();
        final kept = entries.length > maxMatches
            ? entries.sublist(entries.length - maxMatches)
            : entries;
        return d.copyWith(matches: Map.fromEntries(kept));
      });

  static const int maxHistory = 1000;
  static const int maxMatches = 5000;
}

/// (Kotlin: QueueSnapshot)
class QueueSnapshot {
  const QueueSnapshot({
    this.tracks = const [],
    this.index = 0,
    this.positionMs = 0,
    this.shuffle = false,
    this.repeat = 0,
  });

  final List<Track> tracks;
  final int index;
  final int positionMs;
  final bool shuffle;

  /// Kotlin: Int repeat (0 = off, 1 = all, 2 = one — ExoPlayer repeat modes).
  final int repeat;

  QueueSnapshot copyWith({
    List<Track>? tracks,
    int? index,
    int? positionMs,
    bool? shuffle,
    int? repeat,
  }) =>
      QueueSnapshot(
        tracks: tracks ?? this.tracks,
        index: index ?? this.index,
        positionMs: positionMs ?? this.positionMs,
        shuffle: shuffle ?? this.shuffle,
        repeat: repeat ?? this.repeat,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'index': index,
        'positionMs': positionMs,
        'shuffle': shuffle,
        'repeat': repeat,
      };

  factory QueueSnapshot.fromJson(Map<String, dynamic> json) => QueueSnapshot(
        tracks: _listOf(json['tracks'], Track.fromJson),
        index: (json['index'] as num?)?.toInt() ?? 0,
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        shuffle: json['shuffle'] as bool? ?? false,
        repeat: (json['repeat'] as num?)?.toInt() ?? 0,
      );
}

/// Queue persistence: restored on the next start (also for media-button
/// resumption). (Kotlin: QueueStore)
class QueueStore {
  QueueStore(String dirPath) : _file = File('$dirPath/queue.json');

  final File _file;
  Timer? _saveTimer;
  QueueSnapshot? _pending;

  Future<QueueSnapshot?> read() async {
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          return QueueSnapshot.fromJson(decoded);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Debounced by 1500 ms like the original.
  void save(QueueSnapshot s) {
    _pending = s;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), _flush);
  }

  Future<void> _flush() async {
    final s = _pending;
    if (s == null) return;
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(s.toJson()));
    } catch (_) {}
  }

  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _flush();
    }
  }
}
