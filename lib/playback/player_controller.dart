// PlayerController — the playback layer of the UpZe Flutter rewrite.
//
// Port of the *behaviour* of playback/PlaybackService.kt +
// playback/PlayerConnection.kt (Media3/ExoPlayer) onto just_audio.
//
// ARCHITECTURE CHOICE (one approach, as briefed)
// ----------------------------------------------
// The Kotlin service gives ExoPlayer a playlist of lazy "musicspot://"
// URIs and resolves each to a real stream URL inside a
// ResolvingDataSource, at load time, invisibly. just_audio has no
// equivalent hook, so this controller owns the queue itself:
//
//   * The queue is a plain List<Track> here, NOT a ConcatenatingAudioSource.
//     Each track change resolves the track through SourceManager (lazily,
//     per track, cached — see [_resolvedCache]) and loads that one stream
//     into the active AudioPlayer with `setAudioSource`.
//   * Track end (ProcessingState.completed) advances the queue manually,
//     honouring shuffle order / repeat modes / sleep modes.
//   * The *next* track is pre-resolved in the background as soon as the
//     current one starts (the Kotlin PREFETCH_AHEAD behaviour), so a skip
//     or an advance usually starts from an already-minted URL.
//
// APPROXIMATIONS vs Media3 (honest list)
// --------------------------------------
//   * GAPLESS: there is no true sample-accurate gapless hand-off between
//     two lazily-resolved streams in just_audio. Pre-resolution makes the
//     switch fast (typically sub-second), but a short gap can remain.
//     When settings.gapless is on, crossfade is disabled (same rule as
//     the Kotlin ticker: cf = 0 when gapless).
//   * CROSSFADE: the Kotlin app fades a *single* ExoPlayer's volume out
//     and back in around an instant item switch (it is not really a
//     two-player overlap either). Here settings.crossfadeSec > 0 uses a
//     genuine two-player overlap: the incoming track starts on the second
//     AudioPlayer at the (duration - crossfade) mark and both volumes are
//     ramped with an equal-power (cos/sin) curve. The audible result is
//     at least as smooth; the mechanism differs from the original.
//   * RESOLUTION RECOVERY: the Kotlin ReplayPolicy re-prepares the same
//     item (max 2 automatic replays, the 2nd without YouTube). Here a
//     failed resolve or a player error drops the cached URL, re-resolves
//     (excluding YouTube on the last attempt when YouTube was involved),
//     and only then skips to the next queue track — no endless loop.
//   * No media cache / chunked ranged fetching (Kotlin: SimpleCache +
//     ChunkedDataSource), no DSP/EQ audio processors (Phase 3), no
//     autoplay/"Infinite play" radio appends, no home-screen widget.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../data/library.dart';
import '../data/play_stats.dart';
import '../data/settings_store.dart';
import '../models/track.dart';
import '../sources/music_source.dart';
import '../sources/source_manager.dart';
import 'audio_handler.dart';

/// Repeat modes, mirroring the Kotlin QueueSnapshot ints
/// (0 = off, 1 = all, 2 = one — the ExoPlayer repeat-mode values).
enum QueueRepeatMode {
  off(0),
  all(1),
  one(2);

  const QueueRepeatMode(this.kotlinValue);

  final int kotlinValue;

  static QueueRepeatMode fromKotlin(int v) =>
      values.firstWhere((m) => m.kotlinValue == v, orElse: () => off);
}

/// Sleep timer modes (Kotlin: logic.SleepTimer.Mode).
enum SleepMode { off, duration, endOfTrack, endOfQueue }

/// What is really playing for the current track (Kotlin: NowStream).
class NowStream {
  const NowStream({
    required this.trackId,
    required this.info,
    this.fallbackFrom,
    this.failures = const [],
  });

  final String trackId;
  final StreamInfo info;

  /// Set when YouTube was exhausted/excluded and this plays from another
  /// source (UI: "Playing from JioSaavn").
  final SourceKind? fallbackFrom;

  /// "Source: error" lines for the candidates that failed before this one
  /// resolved — the player UI shows them as a source switch note.
  final List<String> failures;
}

class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.manager,
    required this.settings,
    this.metered,
    this.library,
    this.playStats,
    this.queueStore,
    AudioPlayer? player,
    AudioPlayer? fadePlayer,
  })  : _playerA = player ?? AudioPlayer(),
        _playerB = fadePlayer ?? AudioPlayer() {
    _active = _playerA;
    _wirePlayer(_playerA);
    _wirePlayer(_playerB);
    // 250 ms housekeeping tick: sleep timer + sleep fade + queue saves
    // (the Kotlin service runs the same jobs on a 200 ms ticker).
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
  }

  /// Stream router: lazy per-track resolution with failover.
  final SourceManager manager;

  /// Live settings lookup (read at each use, like the Kotlin Graph).
  final AppSettings Function() settings;

  /// Whether the active network is metered (mobile data). When null,
  /// treated as unmetered. Quality = settings().effectiveQuality(metered).
  final bool Function()? metered;

  /// Optional persistence hooks (constructor-injected; all optional).
  final LibraryRepo? library;
  final PlayStatsRepo? playStats;
  final QueueStore? queueStore;

  // --- players -------------------------------------------------------------
  final AudioPlayer _playerA;
  final AudioPlayer _playerB;
  late AudioPlayer _active;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _ticker;
  bool _disposed = false;

  AudioPlayer get _standby => identical(_active, _playerA) ? _playerB : _playerA;

  // --- queue state -----------------------------------------------------------
  List<Track> _queue = const [];
  int _index = -1;

  /// Play order as queue indices (identity unless shuffle is on).
  List<int> _order = const [];
  int _orderPos = -1;
  bool _shuffle = false;
  QueueRepeatMode _repeatMode = QueueRepeatMode.off;

  // --- playback state --------------------------------------------------------
  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _lastError;
  NowStream? _nowStream;

  // --- resolution cache --------------------------------------------------------
  // Kotlin: urlCache, 30 min TTL, max 32 entries (insertion-ordered LRU).
  static const Duration _urlTtl = Duration(minutes: 30);
  final Map<String, (Resolved, DateTime)> _resolvedCache = {};
  final Map<String, Future<Resolved>> _inflight = {};

  /// Sources excluded per track id after refusals (Kotlin: ytExcluded).
  final Map<String, Set<SourceKind>> _excluded = {};

  /// Bumped on every load; stale async loads check it and bail out.
  int _loadToken = 0;

  /// Automatic recovery attempts for the current track (Kotlin:
  /// ReplayPolicy.MAX_AUTO_REPLAYS = 2).
  static const int _maxAutoRecoveries = 2;
  int _recoveries = 0;
  String? _recoveryForId;

  // --- play counting (Kotlin: ticker + Taste.countThresholdMs) -----------------
  String? _countedForId;
  int _countedToken = -1;
  bool _repeatPending = false;

  // --- crossfade -----------------------------------------------------------------
  bool _crossfading = false;
  Timer? _fadeTimer;
  double _fadeT = 0; // 0..1 progress of the active crossfade

  // --- sleep timer (port of logic/SleepTimer semantics) ---------------------------
  SleepMode _sleepMode = SleepMode.off;
  DateTime? _sleepEndsAt;
  Duration _sleepTotal = Duration.zero;

  // --- exposed streams (active-player position/duration/playing) -------------------
  final StreamController<Duration> _positionOut =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationOut =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingOut =
      StreamController<bool>.broadcast();

  // ===========================================================================
  // UI-facing state
  // ===========================================================================

  List<Track> get queue => List.unmodifiable(_queue);
  int get currentIndex => _index;
  Track? get currentTrack =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  bool get hasQueue => _queue.isNotEmpty;
  bool get playing => _playing;
  bool get buffering => _buffering;
  bool get shuffle => _shuffle;
  QueueRepeatMode get repeatMode => _repeatMode;
  Duration get position => _position;
  Duration get duration => _duration;
  String? get lastError => _lastError;
  NowStream? get nowStream => _nowStream;
  StreamInfo? get currentStreamInfo => _nowStream?.info;
  bool get crossfading => _crossfading;

  Stream<Duration> get positionStream => _positionOut.stream;
  Stream<Duration> get durationStream => _durationOut.stream;
  Stream<bool> get playingStream => _playingOut.stream;

  bool get hasNext => _step(1) != null;
  bool get hasPrevious => _step(-1) != null;

  // --- sleep state -------------------------------------------------------------
  SleepMode get sleepMode => _sleepMode;
  bool get sleepActive => _sleepMode != SleepMode.off;

  /// Remaining time for a duration sleep timer, else null.
  Duration? get sleepRemaining {
    if (_sleepMode != SleepMode.duration || _sleepEndsAt == null) return null;
    final r = _sleepEndsAt!.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  DateTime? get sleepEndsAt => _sleepEndsAt;
  Duration get sleepTotal => _sleepTotal;

  /// 0..1 fraction of a duration sleep timer elapsed (progress bar).
  double get sleepProgress {
    final r = sleepRemaining;
    if (r == null || _sleepTotal <= Duration.zero) return 0;
    return (1 - r.inMilliseconds / _sleepTotal.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  // --- like state ------------------------------------------------------------------
  bool isLiked(Track t) => library?.isLiked(t.id) ?? false;
  bool get currentLiked {
    final t = currentTrack;
    return t != null && isLiked(t);
  }

  /// Toggle like for [t] (defaults to the current track). Returns the new
  /// liked state, or null when no LibraryRepo is wired.
  bool? toggleLike([Track? t]) {
    final track = t ?? currentTrack;
    final repo = library;
    if (track == null || repo == null) return null;
    final now = !repo.isLiked(track.id);
    repo.setLiked(track, now);
    notifyListeners();
    return now;
  }

  // ===========================================================================
  // Queue commands (PlayerConnection equivalents)
  // ===========================================================================

  /// Play [tracks] starting at [index] (Kotlin: PlayerConnection.play).
  Future<void> playTrack(List<Track> tracks, int index,
      {bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    _cancelCrossfade(swap: false);
    _queue = List.of(tracks);
    _index = index.clamp(0, tracks.length - 1);
    _shuffle = shuffle;
    _rebuildOrder(keepCurrentFirst: shuffle);
    _recoveries = 0;
    _recoveryForId = null;
    _saveQueue();
    notifyListeners();
    await _loadCurrent(autoplay: true);
  }

  /// Play [tracks] paused (queue restore / preview).
  Future<void> setQueue(List<Track> tracks, int index,
      {bool shuffle = false,
      QueueRepeatMode repeat = QueueRepeatMode.off}) async {
    if (tracks.isEmpty) return;
    _cancelCrossfade(swap: false);
    _queue = List.of(tracks);
    _index = index.clamp(0, tracks.length - 1);
    _shuffle = shuffle;
    _repeatMode = repeat;
    _rebuildOrder(keepCurrentFirst: shuffle);
    _saveQueue();
    notifyListeners();
    await _loadCurrent(autoplay: false);
  }

  /// Restore a persisted queue snapshot (Kotlin: restoreQueue) — loaded
  /// paused at the saved position.
  Future<void> restoreSnapshot(QueueSnapshot snap) async {
    if (snap.tracks.isEmpty) return;
    await setQueue(
      snap.tracks,
      snap.index,
      shuffle: snap.shuffle,
      repeat: QueueRepeatMode.fromKotlin(snap.repeat),
    );
    if (snap.positionMs > 0) {
      await seek(Duration(milliseconds: snap.positionMs));
    }
  }

  /// Insert [t] right after the current track (Kotlin: playNext).
  void playNext(Track t) {
    if (_queue.isEmpty) {
      unawaited(playTrack([t], 0));
      return;
    }
    _insertAt(_index + 1, t);
    _saveQueue();
    notifyListeners();
  }

  /// Append tracks to the queue (Kotlin: addToQueue).
  void addToQueue(List<Track> tracks) {
    if (tracks.isEmpty) return;
    if (_queue.isEmpty) {
      unawaited(playTrack(tracks, 0));
      return;
    }
    for (final t in tracks) {
      _queue.add(t);
      if (!_shuffle) _order = [..._order, _queue.length - 1];
    }
    if (_shuffle) _rebuildOrder(keepCurrentFirst: false);
    _saveQueue();
    notifyListeners();
  }

  /// Jump to queue position [i] and play (Kotlin: skipTo, bounds-checked).
  Future<void> skipTo(int i) async {
    if (i < 0 || i >= _queue.length || i == _index) {
      if (i == _index) await play();
      return;
    }
    _cancelCrossfade(swap: false);
    _index = i;
    _orderPos = _order.indexOf(i);
    _recoveries = 0;
    _saveQueue();
    notifyListeners();
    await _loadCurrent(autoplay: true);
  }

  /// Move a queue item (Kotlin: move, bounds-checked).
  void move(int from, int to) {
    final n = _queue.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    final currentId = currentTrack?.id;
    final item = _queue.removeAt(from);
    _queue.insert(to, item);
    int remap(int idx) {
      if (idx == from) return to;
      var v = idx;
      if (v > from) v--;
      if (v >= to) v++;
      return v;
    }

    _order = _order.map(remap).toList();
    _index = _queue.indexWhere((t) => t.id == currentId);
    _orderPos = _order.indexOf(_index);
    _saveQueue();
    notifyListeners();
  }

  /// Remove a queue item (Kotlin: remove, bounds-checked). Removing the
  /// current track loads whatever slides into its place (keeping the
  /// playing state); removing the last track stops playback.
  Future<void> removeAt(int i) async {
    if (i < 0 || i >= _queue.length) return;
    final wasCurrent = i == _index;
    final wasPlaying = _playing;
    _queue.removeAt(i);
    _order = [
      for (final idx in _order)
        if (idx != i) idx > i ? idx - 1 : idx,
    ];
    if (_queue.isEmpty) {
      _index = -1;
      _orderPos = -1;
      await stop();
      notifyListeners();
      return;
    }
    if (i < _index) _index--;
    if (_index >= _queue.length) _index = _queue.length - 1;
    _orderPos = _order.indexOf(_index);
    _saveQueue();
    notifyListeners();
    if (wasCurrent) {
      _cancelCrossfade(swap: false);
      _recoveries = 0;
      await _loadCurrent(autoplay: wasPlaying);
    }
  }

  /// Drop everything after the current track (Kotlin: clearUpcoming).
  void clearUpcoming() {
    if (_index < 0 || _index >= _queue.length - 1) return;
    final keepIds = _queue.sublist(0, _index + 1).map((t) => t.id).toSet();
    _queue = _queue.sublist(0, _index + 1);
    _order = _order.where((idx) => idx <= _index).toList();
    if (!_order.contains(_index)) _order = [..._order, _index];
    _queue.removeWhere((t) => !keepIds.contains(t.id)); // no-op safeguard
    _orderPos = _order.indexOf(_index);
    _saveQueue();
    notifyListeners();
  }

  // ===========================================================================
  // Transport commands
  // ===========================================================================

  Future<void> play() async {
    if (_crossfading) {
      await _standby.play().catchError((_) {});
    }
    await _active.play().catchError((_) {});
  }

  Future<void> pause() async {
    await _active.pause();
    if (_crossfading) await _standby.pause();
  }

  /// Kotlin: toggle — play when paused, pause when playing; a stopped
  /// (idle/completed) player is re-prepared first.
  Future<void> toggle() async {
    if (_playing) {
      await pause();
    } else {
      if (currentTrack != null &&
          _active.processingState == ProcessingState.completed) {
        await _loadCurrent(autoplay: true);
        return;
      }
      await play();
    }
  }

  Future<void> stop() async {
    _cancelCrossfade(swap: false);
    _loadToken++;
    await _active.stop();
    _setPlaying(false);
    _nowStream = null;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    // A seek during a crossfade finishes the swap instantly, so the seek
    // lands unambiguously on the incoming track.
    if (_crossfading) _finishCrossfade();
    await _active.seek(position);
    _setPosition(position);
  }

  /// Next track in play order (Kotlin: seekToNext). Repeat-one does not
  /// intercept a *manual* skip, matching ExoPlayer.
  Future<void> next() async {
    final n = _step(1);
    if (n == null) return;
    await skipTo(n);
  }

  /// Previous track; restarts the current one when > 3 s in
  /// (ExoPlayer's seekToPrevious behaviour).
  Future<void> previous() async {
    if (_position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final p = _step(-1);
    if (p == null) {
      await seek(Duration.zero);
      return;
    }
    await skipTo(p);
  }

  void setShuffle(bool on) {
    if (_shuffle == on) return;
    _shuffle = on;
    _rebuildOrder(keepCurrentFirst: on);
    _saveQueue();
    notifyListeners();
  }

  /// off -> all -> one -> off (Kotlin: cycleRepeat).
  void cycleRepeat() {
    _repeatMode = switch (_repeatMode) {
      QueueRepeatMode.off => QueueRepeatMode.all,
      QueueRepeatMode.all => QueueRepeatMode.one,
      QueueRepeatMode.one => QueueRepeatMode.off,
    };
    _saveQueue();
    notifyListeners();
  }

  void setRepeat(QueueRepeatMode mode) {
    _repeatMode = mode;
    _saveQueue();
    notifyListeners();
  }

  // ===========================================================================
  // Sleep timer (Kotlin: PlayerConnection.sleep* + logic/SleepTimer)
  // ===========================================================================

  /// Pause after [minutes] (fades out first when settings.sleepFade is on;
  /// settings.sleepFinishSong delays the pause to the track's end).
  void startSleepTimer(int minutes) {
    if (minutes <= 0) return;
    _sleepMode = SleepMode.duration;
    _sleepTotal = Duration(minutes: minutes);
    _sleepEndsAt = DateTime.now().add(_sleepTotal);
    notifyListeners();
  }

  /// Pause using the settings default (AppSettings.sleepDefaultMin).
  void startSleepDefault() => startSleepTimer(settings().sleepDefaultMin);

  /// Pause when the current track ends.
  void sleepAfterThisTrack() {
    _sleepMode = SleepMode.endOfTrack;
    _sleepEndsAt = null;
    _sleepTotal = Duration.zero;
    notifyListeners();
  }

  /// Pause when the last queue track ends.
  void sleepAfterQueue() {
    _sleepMode = SleepMode.endOfQueue;
    _sleepEndsAt = null;
    _sleepTotal = Duration.zero;
    notifyListeners();
  }

  /// Add (or remove, when negative) minutes; never below one minute left
  /// (Kotlin: SleepTimer.adjust).
  void adjustSleep(int minutes) {
    if (_sleepMode != SleepMode.duration || _sleepEndsAt == null) return;
    var remaining = _sleepEndsAt!.difference(DateTime.now()) +
        Duration(minutes: minutes);
    if (remaining < const Duration(minutes: 1)) {
      remaining = const Duration(minutes: 1);
    }
    _sleepEndsAt = DateTime.now().add(remaining);
    if (remaining > _sleepTotal) _sleepTotal = remaining;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepMode = SleepMode.off;
    _sleepEndsAt = null;
    _sleepTotal = Duration.zero;
    _applyVolume(); // restore full volume if a sleep fade was in progress
    notifyListeners();
  }

  // ===========================================================================
  // Resolution (SourceManager, cached — Kotlin: urlCache / inflight)
  // ===========================================================================

  /// Resolve [track] through SourceManager, with the per-track cache and
  /// in-flight de-duplication the Kotlin service keeps. Public so the UI
  /// can pre-warm a track it is about to queue.
  Future<Resolved> resolveTrack(Track track) {
    final hit = _resolvedCache[track.id];
    if (hit != null && DateTime.now().difference(hit.$2) < _urlTtl) {
      // LRU touch.
      _resolvedCache.remove(track.id);
      _resolvedCache[track.id] = hit;
      return Future.value(hit.$1);
    }
    final pending = _inflight[track.id];
    if (pending != null) return pending;
    final failures = <String>[];
    final s = settings();
    final isMetered = metered?.call() ?? false;
    final future = manager.resolve(
      track,
      s.effectiveQuality(isMetered),
      isMetered,
      exclude: _excluded[track.id] ?? const {},
      onFailure: (cand, e) => failures.add('${cand.source.label}: $e'),
    );
    _inflight[track.id] = future;
    future.then((r) {
      _resolvedCache.remove(track.id);
      _resolvedCache[track.id] = (r, DateTime.now());
      while (_resolvedCache.length > 32) {
        _resolvedCache.remove(_resolvedCache.keys.first);
      }
      _lastFailures[track.id] = failures;
    }).catchError((_) {
      _lastFailures[track.id] = failures;
    }).whenComplete(() => _inflight.remove(track.id));
    return future;
  }

  final Map<String, List<String>> _lastFailures = {};

  void _dropCached(String trackId) {
    _resolvedCache.remove(trackId);
    _inflight.remove(trackId);
  }

  /// Pre-resolve the next track in play order (Kotlin: prefetchUpcoming,
  /// PREFETCH_AHEAD = 2 — the second-next is warmed once the next is in).
  void _prefetchNext() {
    final n = _step(1);
    if (n == null) return;
    // Fire-and-forget warm-up; failures surface again on the real load.
    unawaited(() async {
      try {
        await resolveTrack(_queue[n]);
      } catch (_) {
        // Pre-resolution is best-effort (Kotlin logs and moves on).
      }
    }());
  }

  // ===========================================================================
  // Loading / advancing (internal)
  // ===========================================================================

  Future<void> _loadCurrent({required bool autoplay}) async {
    final track = currentTrack;
    if (track == null) return;
    final token = ++_loadToken;
    _countedForId = null;
    _setPosition(Duration.zero);
    _setDuration(
        track.durationMs > 0 ? Duration(milliseconds: track.durationMs) : Duration.zero);
    _lastError = null;
    _setBuffering(true);
    notifyListeners();
    try {
      final resolved = await resolveTrack(track);
      if (token != _loadToken || _disposed) return;
      _nowStream = NowStream(
        trackId: track.id,
        info: resolved.info,
        fallbackFrom: resolved.fallbackFrom,
        failures: _lastFailures[track.id] ?? const [],
      );
      await _active.setAudioSource(audioSourceFor(track, resolved));
      if (token != _loadToken || _disposed) return;
      _applyVolume();
      if (autoplay) await play();
      // History is recorded on the transition, like the Kotlin listener.
      library?.recordPlay(track, resolved.info.source.label);
      notifyListeners();
      _prefetchNext();
    } catch (e) {
      if (token != _loadToken || _disposed) return;
      await _recoverOrSkip(track, e);
    } finally {
      if (token == _loadToken) _setBuffering(false);
    }
  }

  /// Bounded automatic recovery (Kotlin: ReplayPolicy): re-resolve the
  /// same track up to [_maxAutoRecoveries] times — the last attempt
  /// without YouTube when YouTube was the track's source — then skip to
  /// the next track; if there is no next track, surface the error and stop.
  Future<void> _recoverOrSkip(Track track, Object error) async {
    _dropCached(track.id);
    if (_recoveryForId != track.id) {
      _recoveryForId = track.id;
      _recoveries = 0;
    }
    _recoveries++;
    if (_recoveries <= _maxAutoRecoveries) {
      if (_recoveries == _maxAutoRecoveries &&
          track.source == SourceKind.youtube) {
        // Last attempt goes without YouTube (Kotlin: REPLAY_WITHOUT_YOUTUBE).
        _excluded[track.id] = {
          ...?_excluded[track.id],
          SourceKind.youtube,
        };
      }
      await _loadCurrent(autoplay: true);
      return;
    }
    _lastError = '$error';
    final n = _step(1, ignoreRepeatOne: true);
    if (n != null) {
      _recoveries = 0;
      _recoveryForId = null;
      _index = n;
      _orderPos = _order.indexOf(n);
      notifyListeners();
      await _loadCurrent(autoplay: true);
    } else {
      _setPlaying(false);
      notifyListeners();
    }
  }

  /// The track at [delta] steps in play order, or null when playback
  /// should end there. Repeat-all wraps; repeat-one is ignored for
  /// manual skips when [ignoreRepeatOne] is set.
  int? _step(int delta, {bool ignoreRepeatOne = false}) {
    if (_queue.isEmpty || _orderPos < 0) return null;
    if (_repeatMode == QueueRepeatMode.one && !ignoreRepeatOne && delta != 0) {
      // Automatic advance handles repeat-one separately; a manual next
      // still moves (ExoPlayer behaviour), so only _advance uses this.
    }
    var pos = _orderPos + delta;
    if (pos < 0) return null;
    if (pos >= _order.length) {
      if (_repeatMode == QueueRepeatMode.all) {
        pos = 0;
      } else {
        return null;
      }
    }
    return _order[pos];
  }

  /// Automatic advance when the active player reports completion.
  Future<void> _onTrackEnded() async {
    if (_crossfading) return; // the fade already moved us on
    final track = currentTrack;
    if (track == null) return;

    // Sleep modes that end playback at a track boundary come first
    // (Kotlin: SleepTimer end-of-track pause happens on the transition).
    if (_sleepMode == SleepMode.endOfTrack ||
        (_sleepMode == SleepMode.duration &&
            settings().sleepFinishSong &&
            _sleepExpired()) ||
        (_sleepMode == SleepMode.endOfQueue && _step(1) == null)) {
      cancelSleepTimer();
      await _active.pause();
      await seek(Duration.zero);
      return;
    }

    if (_repeatMode == QueueRepeatMode.one) {
      // A consecutive replay of the same song counts as a repeat
      // (Kotlin: repeatPending), then stats counting re-arms.
      _repeatPending = _countedForId == track.id;
      _countedForId = null;
      await seek(Duration.zero);
      await play();
      return;
    }

    final n = _step(1);
    if (n == null) {
      // Queue finished: park on the last track, paused at the start.
      await seek(Duration.zero);
      await _active.pause();
      return;
    }
    _index = n;
    _orderPos = _order.indexOf(n);
    _recoveries = 0;
    _recoveryForId = null;
    _saveQueue();
    notifyListeners();
    await _loadCurrent(autoplay: true);
  }

  bool _sleepExpired() =>
      _sleepMode == SleepMode.duration &&
      _sleepEndsAt != null &&
      !DateTime.now().isBefore(_sleepEndsAt!);

  // ===========================================================================
  // Crossfade (two-player overlap; see header for the approximation note)
  // ===========================================================================

  /// Crossfade length in seconds: 0 when gapless is on (Kotlin rule) or
  /// the setting is off.
  int get _crossfadeSec {
    final s = settings();
    if (s.gapless) return 0;
    return s.crossfadeSec;
  }

  void _maybeStartCrossfade() {
    if (_crossfading || !_playing) return;
    final cf = _crossfadeSec;
    if (cf <= 0) return;
    if (_duration <= Duration(seconds: cf * 3)) return;
    if (_repeatMode == QueueRepeatMode.one) return;
    final remaining = _duration - _position;
    if (remaining <= Duration.zero || remaining > Duration(seconds: cf)) {
      return;
    }
    final n = _step(1);
    if (n == null) return;
    unawaited(_startCrossfade(n, Duration(seconds: cf)));
  }

  Future<void> _startCrossfade(int nextIndex, Duration fadeDur) async {
    final nextTrack = _queue[nextIndex];
    final token = _loadToken; // any explicit load cancels the fade
    _crossfading = true;
    _fadeT = 0;
    notifyListeners();
    Resolved resolved;
    try {
      resolved = await resolveTrack(nextTrack);
    } catch (_) {
      // Can't fade into an unresolvable track: let the normal
      // end-of-track path (with its recovery) handle it instead.
      _crossfading = false;
      notifyListeners();
      return;
    }
    if (token != _loadToken || _disposed || !_crossfading) return;
    final incoming = _standby;
    try {
      await incoming.setAudioSource(audioSourceFor(nextTrack, resolved));
      await incoming.setVolume(0);
      await incoming.play();
    } catch (_) {
      _crossfading = false;
      notifyListeners();
      return;
    }
    _fadeNextIndex = nextIndex;
    _fadeNextResolved = resolved;
    const step = Duration(milliseconds: 50);
    final steps = math.max(1, fadeDur.inMilliseconds ~/ step.inMilliseconds);
    var done = 0;
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(step, (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      done++;
      _fadeT = (done / steps).clamp(0.0, 1.0);
      _applyVolume();
      if (done >= steps) _finishCrossfade();
    });
  }

  int? _fadeNextIndex;
  Resolved? _fadeNextResolved;

  /// Completes the swap: the incoming player becomes the active one and
  /// the outgoing player is stopped.
  void _finishCrossfade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    if (!_crossfading) return;
    final nextIndex = _fadeNextIndex;
    final resolved = _fadeNextResolved;
    final outgoing = _active;
    _active = _standby;
    _crossfading = false;
    _fadeT = 0;
    _fadeNextIndex = null;
    _fadeNextResolved = null;
    unawaited(outgoing.stop());
    if (nextIndex != null) {
      _index = nextIndex;
      _orderPos = _order.indexOf(nextIndex);
      _recoveries = 0;
      _recoveryForId = null;
      final track = currentTrack;
      if (track != null && resolved != null) {
        _nowStream = NowStream(
          trackId: track.id,
          info: resolved.info,
          fallbackFrom: resolved.fallbackFrom,
          failures: _lastFailures[track.id] ?? const [],
        );
        library?.recordPlay(track, resolved.info.source.label);
      }
      _countedForId = null;
      _loadToken++; // the fade *was* the load for this track
      _saveQueue();
    }
    _applyVolume();
    notifyListeners();
    _prefetchNext();
  }

  /// Cancels a running fade. With [swap] the incoming track wins (used by
  /// seek); otherwise the incoming player is stopped and the current
  /// track keeps playing (used by explicit loads / stop).
  void _cancelCrossfade({required bool swap}) {
    if (!_crossfading) return;
    if (swap) {
      _finishCrossfade();
      return;
    }
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _crossfading = false;
    _fadeT = 0;
    _fadeNextIndex = null;
    _fadeNextResolved = null;
    unawaited(_standby.stop());
    _applyVolume();
  }

  // ===========================================================================
  // Volume: crossfade curve × sleep fade (Kotlin ticker volume logic)
  // ===========================================================================

  /// Sleep-fade multiplier for right now: settings.sleepFade fades the
  /// last 30 s of a duration sleep timer (Kotlin: SleepTimer.fadeFactor).
  double get _sleepFactor {
    if (_sleepMode != SleepMode.duration || !settings().sleepFade) return 1;
    final r = sleepRemaining;
    if (r == null) return 1;
    const window = Duration(seconds: 30);
    if (r >= window) return 1;
    return (r.inMilliseconds / window.inMilliseconds).clamp(0.0, 1.0);
  }

  void _applyVolume() {
    final f = _sleepFactor;
    if (_crossfading) {
      // Equal-power crossfade: cos for the outgoing, sin for the incoming.
      final angle = _fadeT * math.pi / 2;
      unawaited(_active.setVolume((math.cos(angle) * f).clamp(0.0, 1.0)));
      unawaited(_standby.setVolume((math.sin(angle) * f).clamp(0.0, 1.0)));
    } else {
      unawaited(_active.setVolume(f.clamp(0.0, 1.0)));
    }
  }

  // ===========================================================================
  // Player wiring / ticker
  // ===========================================================================

  void _wirePlayer(AudioPlayer p) {
    _subs.add(p.playerStateStream.listen((st) {
      if (!identical(p, _active) && !_crossfading) return;
      if (identical(p, _active)) {
        _setPlaying(st.playing);
        _setBuffering(st.processingState == ProcessingState.loading ||
            st.processingState == ProcessingState.buffering);
        if (st.processingState == ProcessingState.completed) {
          unawaited(_onTrackEnded());
        }
      }
    }, onError: (Object e) {
      if (identical(p, _active)) {
        final t = currentTrack;
        if (t != null) unawaited(_recoverOrSkip(t, e));
      }
    }));
    _subs.add(p.positionStream.listen((pos) {
      if (!identical(p, _active)) return;
      _setPosition(pos);
      _maybeStartCrossfade();
      _maybeCountPlay(pos);
    }));
    _subs.add(p.durationStream.listen((dur) {
      if (!identical(p, _active)) return;
      if (dur != null && dur > Duration.zero) _setDuration(dur);
    }));
  }

  /// Play counting (Kotlin ticker): after ~30 s of a track (half of a
  /// short one), counted once per load; a consecutive replay of the same
  /// song counts as a repeat.
  void _maybeCountPlay(Duration pos) {
    final repo = playStats;
    final track = currentTrack;
    if (repo == null || track == null || !_playing) return;
    if (_countedForId == track.id && _countedToken == _loadToken) return;
    final durMs = _duration.inMilliseconds;
    // Taste.countThresholdMs: half the duration for songs under 60 s.
    final thresholdMs =
        (durMs > 0 && durMs < 60000) ? durMs ~/ 2 : 30000;
    if (pos.inMilliseconds < thresholdMs) return;
    _countedForId = track.id;
    _countedToken = _loadToken;
    repo.count(track, repeat: _repeatPending);
    _repeatPending = false;
  }

  int _tickCount = 0;

  void _tick() {
    if (_disposed) return;
    // Sleep timer: a plain duration expiry pauses now (with
    // sleepFinishSong it waits for the track end — handled in
    // _onTrackEnded).
    if (_sleepMode == SleepMode.duration && _sleepExpired()) {
      if (!settings().sleepFinishSong) {
        cancelSleepTimer();
        unawaited(pause());
        return;
      }
    }
    if (_sleepMode != SleepMode.off) {
      _applyVolume(); // keep the sleep fade smooth
      notifyListeners(); // sleepRemaining is ticking
    }
    // Queue position save every ~5 s while playing (Kotlin: 25 × 200 ms).
    if (++_tickCount >= 20) {
      _tickCount = 0;
      if (_playing) _saveQueue();
    }
  }

  void _saveQueue() {
    final store = queueStore;
    if (store == null || _queue.isEmpty) return;
    store.save(QueueSnapshot(
      tracks: _queue.take(500).toList(),
      index: _index < 0 ? 0 : _index,
      positionMs: _position.inMilliseconds,
      shuffle: _shuffle,
      repeat: _repeatMode.kotlinValue,
    ));
  }

  // --- order helpers -----------------------------------------------------------

  void _rebuildOrder({required bool keepCurrentFirst}) {
    final ids = List<int>.generate(_queue.length, (i) => i);
    if (_shuffle && _queue.isNotEmpty) {
      ids.shuffle(math.Random());
      if (keepCurrentFirst && _index >= 0) {
        ids.remove(_index);
        ids.insert(0, _index);
      }
    }
    _order = ids;
    _orderPos = _order.indexOf(_index);
  }

  void _insertAt(int at, Track t) {
    final pos = at.clamp(0, _queue.length);
    _queue.insert(pos, t);
    _order = [
      for (final idx in _order) idx >= pos ? idx + 1 : idx,
    ];
    // Insert into the play order right after the current position (or at
    // the matching linear spot when shuffle is off).
    final insertPos = _shuffle ? _orderPos + 1 : _order.indexOf(pos - 1) + 1;
    _order.insert(insertPos.clamp(0, _order.length), pos);
    _orderPos = _order.indexOf(_index);
  }

  // --- small state setters (stream fan-out + notify) ------------------------------

  void _setPlaying(bool v) {
    if (_playing == v) return;
    _playing = v;
    _playingOut.add(v);
    notifyListeners();
  }

  void _setBuffering(bool v) {
    if (_buffering == v) return;
    _buffering = v;
    notifyListeners();
  }

  void _setPosition(Duration v) {
    _position = v;
    _positionOut.add(v);
  }

  void _setDuration(Duration v) {
    if (_duration == v) return;
    _duration = v;
    _durationOut.add(v);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _fadeTimer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_playerA.dispose());
    unawaited(_playerB.dispose());
    unawaited(_positionOut.close());
    unawaited(_durationOut.close());
    unawaited(_playingOut.close());
    super.dispose();
  }
}
