// Port of core/CrashGuard.kt (UpZe v1.0.1, com.ravi.musicspot.core) —
// the logging half.
//
// The Kotlin is a crash safety net installed first in Application.onCreate:
// an uncaught-exception handler writes a full report (device info, stack,
// startup warnings) to filesDir/crash.txt and opens a dedicated CrashActivity
// in a separate ":crash" process, then kills the process.
//
// Flutter's error model is different, and this port covers what maps:
//  * FlutterError.onError — framework/build/layout/paint errors;
//  * PlatformDispatcher.onError — uncaught async errors on the root zone.
// Both append a timestamped entry to crash-log.txt (last [maxEntries] kept)
// and then CHAIN to the previously installed handlers, so the framework's
// own reporting still happens. What cannot map, and is NOT faked: the
// separate crash-process screen and the process kill (a Dart handler cannot
// relaunch the app into a crash UI), and native (Kotlin/JNI) crashes never
// reach Dart at all — those remain the platform's tombstone/Play report.
// The Kotlin's nonFatal() (startup warnings) maps to [recordNonFatal] here.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class CrashGuard {
  static const String fileName = 'crash-log.txt';
  static const int maxEntries = 50;
  static const String _separator = '\n===== UpZe crash log entry =====\n';

  static bool _installed = false;
  static File? _file;
  static final List<String> _entries = [];
  static Future<void> _pending = Future.value();

  /// Hooks the framework and platform error handlers, logging into
  /// `<dirPath>/crash-log.txt`. Call once, first thing in main(), with the
  /// app support directory path. Safe to call again (no-op).
  static void install(String dirPath) {
    if (_installed) return;
    _installed = true;
    _file = File('$dirPath/$fileName');
    // Pick up entries from earlier runs so the log stays one rolling file.
    unawaited(_loadExisting());

    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _append('FlutterError', details.exception, details.stack);
      previousFlutter?.call(details);
    };

    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _append('Uncaught async error', error, stack);
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Records a non-fatal problem caught by a guard (Kotlin:
  /// CrashGuard.nonFatal — logged and kept with the crash log so a later
  /// report carries the warnings too).
  static void recordNonFatal(String where, Object error, [StackTrace? stack]) {
    if (!_installed) return;
    _append('Non-fatal [$where]', error, stack);
  }

  /// The full current log (empty when nothing was ever recorded or the
  /// guard was not installed).
  static Future<String> readLog() async {
    final f = _file;
    if (f == null) return '';
    try {
      // Let any in-flight append land first.
      await _pending;
      return await f.exists() ? await f.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  /// Clears the log (Settings → About in the Kotlin archives the shown
  /// report instead; here the caller owns that flow).
  static Future<void> clear() async {
    _entries.clear();
    final f = _file;
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<void> _loadExisting() async {
    final f = _file;
    if (f == null) return;
    try {
      if (await f.exists()) {
        final text = await f.readAsString();
        _entries
          ..clear()
          ..addAll(
            text
                .split(_separator)
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty),
          );
        _trim();
      }
    } catch (_) {}
  }

  static void _append(String kind, Object error, StackTrace? stack) {
    final entry = StringBuffer()
      ..writeln('Time: ${_stamp(DateTime.now())}')
      ..writeln('Kind: $kind')
      ..writeln(error.toString());
    if (stack != null) {
      entry.write(stack.toString());
    }
    _entries.add(entry.toString().trim());
    _trim();
    // Serialise writes; a logging failure must never cascade.
    _pending = _pending.then((_) => _write()).catchError((_) {});
  }

  static void _trim() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  static Future<void> _write() async {
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(_entries.join(_separator));
    } catch (_) {}
  }

  /// "yyyy-MM-dd HH:mm:ss +0530" — the Kotlin's stamp pattern.
  static String _stamp(DateTime d) {
    String p2(int v) => v.toString().padLeft(2, '0');
    final off = d.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final abs = off.abs();
    return '${d.year}-${p2(d.month)}-${p2(d.day)} '
        '${p2(d.hour)}:${p2(d.minute)}:${p2(d.second)} '
        '$sign${p2(abs.inHours)}${p2(abs.inMinutes % 60)}';
  }
}
