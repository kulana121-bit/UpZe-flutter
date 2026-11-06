// Port of data/PlayStats.kt essentials (UpZe v1.0.1, com.ravi.musicspot.data),
// with PlayStat itself ported from logic/Taste.kt where the original defines it.
// Pure Dart — persistence is a JSON file in a directory whose path is
// passed to the constructor.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/track.dart';

/// How often one song was really listened to (v2.0.5).
/// (Kotlin: logic.PlayStat)
class PlayStat {
  const PlayStat({
    required this.track,
    this.plays = 0,
    this.repeats = 0,
    this.lastMs = 0,
  });

  final Track track;
  final int plays;
  final int repeats;

  /// Epoch millis of the most recent counted play.
  final int lastMs;

  PlayStat copyWith({Track? track, int? plays, int? repeats, int? lastMs}) =>
      PlayStat(
        track: track ?? this.track,
        plays: plays ?? this.plays,
        repeats: repeats ?? this.repeats,
        lastMs: lastMs ?? this.lastMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'track': track.toJson(),
        'plays': plays,
        'repeats': repeats,
        'lastMs': lastMs,
      };

  factory PlayStat.fromJson(Map<String, dynamic> json) => PlayStat(
        track: Track.fromJson(json['track'] as Map<String, dynamic>),
        plays: (json['plays'] as num?)?.toInt() ?? 0,
        repeats: (json['repeats'] as num?)?.toInt() ?? 0,
        lastMs: (json['lastMs'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is PlayStat &&
      other.track == track &&
      other.plays == plays &&
      other.repeats == repeats &&
      other.lastMs == lastMs;

  @override
  int get hashCode => Object.hash(track, plays, repeats, lastMs);
}

/// (Kotlin: PlayStatsData)
class PlayStatsData {
  const PlayStatsData({this.stats = const {}});

  /// Track id → stat.
  final Map<String, PlayStat> stats;

  PlayStatsData copyWith({Map<String, PlayStat>? stats}) =>
      PlayStatsData(stats: stats ?? this.stats);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'stats': stats.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory PlayStatsData.fromJson(Map<String, dynamic> json) => PlayStatsData(
        stats: ((json['stats'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(
              k as String, PlayStat.fromJson(v as Map<String, dynamic>)),
        ),
      );
}

/// v2.0.5 play-count store (play-stats.json): a play is counted by the
/// playback layer after ~30 s (or half a short song) of real listening; a
/// consecutive replay of the same song also counts as a repeat. Feeds
/// Home's "On repeat" and the autoplay taste re-rank. Bounded to [max]
/// songs (least recent dropped). (Kotlin: PlayStatsRepo)
class PlayStatsRepo {
  PlayStatsRepo(String dirPath) : _file = File('$dirPath/play-stats.json');

  final File _file;
  PlayStatsData _data = const PlayStatsData();
  final List<void Function()> _listeners = [];
  Timer? _saveTimer;

  PlayStatsData get data => _data;
  Map<String, PlayStat> get stats => _data.stats;

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          _data = PlayStatsData.fromJson(decoded);
        }
      }
    } catch (_) {}
  }

  void _save() {
    for (final l in List.of(_listeners)) {
      l();
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), _flush);
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_data.toJson()));
    } catch (_) {}
  }

  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _flush();
    }
  }

  PlayStat? statFor(String trackId) => _data.stats[trackId];
  int playsFor(String trackId) => _data.stats[trackId]?.plays ?? 0;

  /// All stats, most recently played first.
  List<PlayStat> get byRecent {
    final list = _data.stats.values.toList()
      ..sort((a, b) => b.lastMs.compareTo(a.lastMs));
    return list;
  }

  /// Tracks with at least one repeat, most repeated first —
  /// the "On repeat" feed in the original.
  List<PlayStat> get onRepeat {
    final list = _data.stats.values.where((s) => s.repeats > 0).toList()
      ..sort((a, b) => b.repeats.compareTo(a.repeats));
    return list;
  }

  void count(Track t, {required bool repeat, int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final cur = _data.stats[t.id];
    final next = PlayStat(
      track: t,
      plays: (cur?.plays ?? 0) + 1,
      repeats: (cur?.repeats ?? 0) + (repeat ? 1 : 0),
      lastMs: now,
    );
    var map = {..._data.stats, t.id: next};
    if (map.length > max) {
      final kept = map.entries.toList()
        ..sort((a, b) => b.value.lastMs.compareTo(a.value.lastMs));
      map = Map.fromEntries(kept.take(max));
    }
    _data = _data.copyWith(stats: map);
    _save();
  }

  void clear() {
    _data = const PlayStatsData();
    _save();
  }

  static const int max = 2000;
}
