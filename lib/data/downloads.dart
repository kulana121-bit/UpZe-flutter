// Port of data/Downloads.kt (UpZe v1.0.1, com.ravi.musicspot.data).
//
// Real downloads: actual audio files on disk, an index JSON of downloaded
// tracks, and a `downloaded(trackId)` lookup whose signature matches the
// SourceManager `downloaded` callback used in main.dart, so a finished
// download plays from its local file before any source is consulted.
//
// WHAT DIFFERS FROM THE KOTLIN ORIGINAL (platform, not behaviour):
//   * No WorkManager / foreground-service notifications. The Kotlin worker's
//     job runs here as a plain async [DownloadsRepo.download] call in the
//     app process; if the app is killed mid-download the entry is left
//     RUNNING and [DownloadsRepo.load] demotes it back to QUEUED, exactly
//     like the original. The resumable `.part` file means a retry continues
//     where it stopped, again like the original.
//   * No wifi-only constraint (the Kotlin enqueue's NetworkType.UNMETERED
//     has no dart:io equivalent); the caller decides when to start.
//   * The worker resolved the track itself through the source router; here
//     the caller hands in a `resolve` callback (normally
//     `(t) => manager.resolve(t, settings.downloadQuality, false)`), which
//     keeps this repo decoupled from SourceManager.
//
// The fetch itself is a faithful port of DownloadWorker.fetchRanged:
// 1 MiB ranged GETs with the Resolved headers, resume from an existing
// `.part`, restart-from-zero when a server ignores Range on a resume, a
// Content-Range start check on 206, and the "empty download" guard.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/track.dart';
import '../sources/music_source.dart';

/// (Kotlin: DownloadEntry.State)
enum DownloadState { queued, running, done, failed }

/// (Kotlin: DownloadEntry) — one track's download record.
class DownloadEntry {
  const DownloadEntry({
    required this.track,
    this.state = DownloadState.queued,
    this.path,
    this.bytes = 0,
    this.total = 0,
    this.info,
    this.error,
    required this.atMs,
  });

  final Track track;
  final DownloadState state;

  /// Absolute path of the finished file (DONE only).
  final String? path;
  final int bytes;
  final int total;
  final StreamInfo? info;
  final String? error;

  /// Epoch millis when the entry was created.
  final int atMs;

  /// Kotlin: DownloadEntry.progress
  double get progress =>
      total > 0 ? (bytes / total).clamp(0.0, 1.0).toDouble() : 0.0;

  DownloadEntry copyWith({
    Track? track,
    DownloadState? state,
    Object? path = _unset,
    int? bytes,
    int? total,
    Object? info = _unset,
    Object? error = _unset,
    int? atMs,
  }) =>
      DownloadEntry(
        track: track ?? this.track,
        state: state ?? this.state,
        path: identical(path, _unset) ? this.path : path as String?,
        bytes: bytes ?? this.bytes,
        total: total ?? this.total,
        info: identical(info, _unset) ? this.info : info as StreamInfo?,
        error: identical(error, _unset) ? this.error : error as String?,
        atMs: atMs ?? this.atMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'track': track.toJson(),
        'state': state.name.toUpperCase(),
        if (path != null) 'path': path,
        'bytes': bytes,
        'total': total,
        if (info != null) 'info': info!.toJson(),
        if (error != null) 'error': error,
        'atMs': atMs,
      };

  factory DownloadEntry.fromJson(Map<String, dynamic> json) => DownloadEntry(
        track: Track.fromJson(json['track'] as Map<String, dynamic>),
        state: DownloadState.values.firstWhere(
          (s) => s.name.toUpperCase() == (json['state'] as String? ?? ''),
          orElse: () => DownloadState.queued,
        ),
        path: json['path'] as String?,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        info: json['info'] is Map<String, dynamic>
            ? StreamInfo.fromJson(json['info'] as Map<String, dynamic>)
            : null,
        error: json['error'] as String?,
        atMs: (json['atMs'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is DownloadEntry &&
      other.track == track &&
      other.state == state &&
      other.path == path &&
      other.bytes == bytes &&
      other.total == total &&
      other.info == info &&
      other.error == error &&
      other.atMs == atMs;

  @override
  int get hashCode =>
      Object.hash(track, state, path, bytes, total, info, error, atMs);
}

const Object _unset = Object();

/// (Kotlin: DownloadsRepo)
class DownloadsRepo {
  /// [baseDirPath] is the app's files directory; downloads live in its
  /// `downloads/` subfolder with the index at `downloads/index.json`
  /// (Kotlin: filesDir/downloads + filesDir/downloads/index.json).
  DownloadsRepo(String baseDirPath)
      : dirPath = '$baseDirPath/downloads',
        _indexFile = File('$baseDirPath/downloads/index.json');

  /// Directory holding the audio files, `.part` files and index.json.
  final String dirPath;
  final File _indexFile;

  Map<String, DownloadEntry> _items = {};
  Timer? _saveTimer;
  final List<void Function()> _listeners = [];

  /// Track id → entry. Unmodifiable snapshot of current state.
  Map<String, DownloadEntry> get items => Map.unmodifiable(_items);

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Kotlin: DownloadsRepo.load — reads the index and repairs states:
  /// a DONE entry whose file vanished becomes FAILED ("File missing"),
  /// a RUNNING entry (app died mid-download) goes back to QUEUED.
  Future<void> load() async {
    try {
      if (!await _indexFile.exists()) return;
      final decoded = jsonDecode(await _indexFile.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final entries = decoded['entries'];
      if (entries is! Map) return;
      _items = entries.map((k, v) => MapEntry(
            k as String,
            DownloadEntry.fromJson(v as Map<String, dynamic>),
          ));
      _items = _items.map((id, e) {
        if (e.state == DownloadState.done &&
            (e.path == null || !File(e.path!).existsSync())) {
          return MapEntry(
              id,
              e.copyWith(
                  state: DownloadState.failed, error: 'File missing'));
        }
        if (e.state == DownloadState.running) {
          return MapEntry(id, e.copyWith(state: DownloadState.queued));
        }
        return MapEntry(id, e);
      });
      _notify();
    } catch (_) {
      // A corrupt index must not sink startup (same spirit as JsonFile.read).
    }
  }

  void _edit(Map<String, DownloadEntry> Function(Map<String, DownloadEntry>)
      f) {
    _items = f(_items);
    _notify();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
  }

  /// Persist the index now (the Kotlin JsonFile debounces at 500 ms;
  /// [_edit] schedules this, call directly before shutdown).
  Future<void> flush() async {
    _saveTimer?.cancel();
    try {
      await _indexFile.parent.create(recursive: true);
      final data = <String, dynamic>{
        'entries': _items.map((k, v) => MapEntry(k, v.toJson())),
      };
      await _indexFile.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  void _update(String id, DownloadEntry Function(DownloadEntry) f) =>
      _edit((m) => m[id] == null ? m : {...m, id: f(m[id]!)});

  /// Kotlin: DownloadsRepo.isDownloaded
  bool isDownloaded(String id) => _items[id]?.state == DownloadState.done;

  /// A finished download as a playable file:// source.
  ///
  /// THIS is the function to hand to SourceManager's `downloaded:` callback:
  /// `downloaded: downloads.downloaded` (its signature is exactly
  /// `Resolved? Function(String trackId)`).
  ///
  /// Kotlin: DownloadsRepo.resolvedFor
  Resolved? downloaded(String id) {
    final e = _items[id];
    if (e == null || e.state != DownloadState.done) return null;
    final p = e.path;
    if (p == null || !File(p).existsSync()) return null;
    final info = (e.info ?? StreamInfo(source: e.track.source))
        .copyWith(sourceTrackId: id);
    return Resolved(
      uri: Uri.file(p).toString(),
      info: info,
      cacheKey: 'file:$id',
    );
  }

  /// Download [track]: resolve it through [resolve] (the caller's source
  /// router), then stream the bytes to disk with progress callbacks.
  ///
  /// Mirrors DownloadWorker.doWork minus WorkManager: marks the entry
  /// RUNNING, streams, marks DONE (or FAILED with the error message) and
  /// returns the final entry. A track that is already DONE is returned
  /// as-is (Kotlin: enqueue() no-ops on DONE).
  Future<DownloadEntry> download(
    Track track,
    Future<Resolved> Function(Track track) resolve, {
    void Function(int bytesDone, int totalBytes)? onProgress,
  }) async {
    final existing = _items[track.id];
    if (existing?.state == DownloadState.done) return existing!;
    _edit((m) => {
          ...m,
          track.id: DownloadEntry(
            track: track,
            atMs: DateTime.now().millisecondsSinceEpoch,
          ),
        });
    _update(track.id,
        (e) => e.copyWith(state: DownloadState.running, error: null));
    try {
      final r = await resolve(track);
      await downloadResolved(track, r, onProgress: onProgress);
      return _items[track.id]!;
    } catch (e) {
      _update(
          track.id,
          (en) => en.copyWith(
              state: DownloadState.failed, error: _errorText(e)));
      rethrow;
    }
  }

  /// Stream an already-[Resolved] stream to disk (the fetch half of
  /// [download]). Only https:// streams can be downloaded, exactly like
  /// the Kotlin worker.
  Future<void> downloadResolved(
    Track track,
    Resolved r, {
    void Function(int bytesDone, int totalBytes)? onProgress,
  }) async {
    final id = track.id;
    if (!r.uri.startsWith('https://')) {
      throw HttpException(
          "This source can't be downloaded (${r.info.source.label})");
    }
    final ext = switch (r.info.codec?.toLowerCase()) {
      'opus' => 'webm',
      'aac' => 'm4a',
      'flac' => 'flac',
      'mp3' => 'mp3',
      _ => 'audio',
    };
    final dir = Directory(dirPath);
    await dir.create(recursive: true);
    final part = File('$dirPath/${safe(id)}.part');
    final out = File('$dirPath/${safe(id)}.$ext');
    await _fetchRanged(r, part, (done, total) {
      _update(id, (e) => e.copyWith(bytes: done, total: total < 0 ? 0 : total));
      onProgress?.call(done, total);
    });
    if (await part.length() < 1024) {
      throw const HttpException('Download was empty');
    }
    try {
      await part.rename(out.path);
    } catch (_) {
      throw const HttpException("Couldn't save the file");
    }
    final len = await out.length();
    _update(
        id,
        (e) => e.copyWith(
              state: DownloadState.done,
              path: out.path,
              bytes: len,
              total: len,
              info: r.info,
              error: null,
            ));
  }

  /// Port of DownloadWorker.fetchRanged: 1 MiB ranged requests, resuming
  /// from the `.part` file's current length. [progress] receives
  /// (bytesDone, totalBytes) with totalBytes = -1 while unknown
  /// (the Kotlin callback passes -1 the same way).
  Future<void> _fetchRanged(
    Resolved r,
    File part,
    void Function(int done, int total) progress,
  ) async {
    const chunk = 1 << 20; // 1 MiB, Kotlin CHUNK
    var offset = await part.exists() ? await part.length() : 0;
    var total = -1;
    final client = http.Client();
    // Append when resuming, truncate when starting fresh (Kotlin:
    // FileOutputStream(part, offset > 0)).
    var sink = part.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write);
    try {
      while (total < 0 || offset < total) {
        final end = offset + chunk - 1;
        final request = http.Request('GET', Uri.parse(r.uri))
          ..headers['Range'] = 'bytes=$offset-$end'
          ..headers.addAll(r.headers);
        // Per-request timeout standing in for the Kotlin download client's
        // 3-minute callTimeout, so one stalled range can't hang forever.
        final resp = await client
            .send(request)
            .timeout(const Duration(minutes: 3));
        if (resp.statusCode == 416) {
          total = offset;
          await resp.stream.drain<void>();
          break;
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          await resp.stream.drain<void>();
          throw HttpException('HTTP ${resp.statusCode}');
        }
        // Server ignored Range on a resume → restart the .part from zero.
        if (resp.statusCode == 200 && offset > 0) {
          await sink.flush();
          await sink.close();
          await part.writeAsBytes(const []);
          offset = 0;
          sink = part.openWrite(mode: FileMode.write);
        }
        // A 206 must start exactly where we asked.
        String? contentRange = resp.headers['content-range'];
        if (resp.statusCode == 206) {
          final start = contentRange
              ?.replaceFirst('bytes ', '')
              .split('-')
              .first
              .trim();
          final startVal = start == null ? null : int.tryParse(start);
          if (startVal != null && startVal != offset) {
            await resp.stream.drain<void>();
            throw HttpException(
                'Content-Range starts at $startVal, expected $offset');
          }
        }
        final rangeTotalText = contentRange?.split('/').last.trim();
        final rangeTotal =
            rangeTotalText == null ? null : int.tryParse(rangeTotalText);
        if (rangeTotal != null) {
          total = rangeTotal;
        } else if (resp.statusCode == 200 && resp.contentLength != null) {
          total = resp.contentLength! + offset;
        }
        var n = 0;
        await for (final bytes in resp.stream) {
          sink.add(bytes);
          n += bytes.length;
        }
        offset += n;
        if (resp.statusCode == 200) total = offset; // Range ignored, got all
        if (n == 0) total = offset;
        progress(offset, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
      client.close();
    }
  }

  /// Kotlin: DownloadsRepo.cancel — cancels the job and deletes the entry.
  /// (Here there is no background job to cancel; an in-flight [download]
  /// future is the caller's to abandon — its `.part` stays for resume.)
  void cancel(String id) => delete(id);

  /// Kotlin: DownloadsRepo.delete — removes the file, the `.part`
  /// and the index entry.
  void delete(String id) {
    final p = _items[id]?.path;
    if (p != null) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    try {
      File('$dirPath/${safe(id)}.part').deleteSync();
    } catch (_) {}
    _edit((m) => {...m}..remove(id));
  }

  /// Kotlin: DownloadsRepo.deleteAll (which cancels every entry).
  void deleteAll() {
    for (final id in _items.keys.toList()) {
      delete(id);
    }
  }

  /// Remove every download (alias of [deleteAll], kept for call-site
  /// clarity where the UI says "clear").
  void clear() => deleteAll();

  /// Kotlin: DownloadsRepo.usedBytes — total size of everything under
  /// the downloads directory (audio files, `.part`s and the index).
  Future<int> usedBytes() async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;
    var sum = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) sum += await e.length();
    }
    return sum;
  }

  /// Kotlin: DownloadsRepo.safe — file-name-safe form of a track id.
  static String safe(String id) {
    final s = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  static String _errorText(Object e) {
    if (e is HttpException) return e.message;
    if (e is SourceUnavailableException) return e.message;
    return e.toString();
  }
}
