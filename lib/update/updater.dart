// Port of update/UpdateLogic.kt + update/Updater.kt (UpZe v1.0.1,
// com.ravi.musicspot.update). Pure Dart + package:http + dart:io — no
// Flutter imports, so the logic is unit-testable like the Kotlin original.
//
// What the Kotlin does, and what is ported here:
//   * Asks GitHub for the latest release of kulana121-bit/UpZe-music
//     (unauthenticated, User-Agent "UpZe", ETag-cached so an unchanged
//     answer is a 304 that does not count against the rate limit), at
//     most once every 12 h on app start and on demand from Settings.
//   * A release only counts when it is NOT a draft, NOT a pre-release,
//     its tag parses as a version, and it has an .apk asset — the FIRST
//     asset whose name ends in ".apk" (case-insensitive) is used, and
//     its browser_download_url must start with https://.
//   * The update is offered only when the release version is strictly
//     newer than the installed one, and (for automatic checks) only when
//     the user has not skipped that exact version
//     (AppSettings.skippedUpdate in data/Settings.kt).
//   * The APK downloads into an "updates" folder as
//     "UpZe-v<version>.apk" (sanitised), via a ".part" file whose size
//     is verified against the asset size before it replaces the target.
//
// WHAT IS STILL ANDROID-NATIVE (not faked here):
//   Opening the downloaded APK in the system package installer is an
//   Android-side step that still has to be wired:
//     1. The APK must be exposed through a FileProvider content:// URI
//        (authority "<package>.updates", cache-path for the updates
//        folder) — AndroidManifest provider entry + res/xml paths file.
//     2. An ACTION_VIEW intent with MIME type
//        "application/vnd.android.package-archive" plus
//        FLAG_GRANT_READ_URI_PERMISSION must be fired (platform channel
//        or a plugin such as open_filex / android_intent_plus).
//     3. On API 26+ the app first needs canRequestPackageInstalls();
//        when false, the user must be sent to
//        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES for this package
//        (Kotlin: Updater.ensureInstallPermission / install).
//   Android itself refuses an APK not signed with the same key, exactly
//   as in the Kotlin build. downloadApk() below stops at a verified
//   file on disk; install hand-off is the remaining native wiring.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The release the updater offers, or null. Port of Kotlin
/// `UpdateLogic.Release`, plus [publishedAt] from the GitHub payload
/// (the Kotlin model does not carry it; the API field is `published_at`).
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.name,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
    required this.pageUrl,
    required this.publishedAt,
  });

  /// Raw GitHub tag, e.g. "v1.0.1".
  final String tag;

  /// [tag] without the leading "v"/"V", e.g. "1.0.1".
  final String version;

  /// Release title; falls back to [tag] when blank.
  final String name;

  /// Release notes with markdown reduced to plain text (see
  /// [UpdateLogic.cleanNotes]).
  final String notes;

  /// browser_download_url of the chosen .apk asset (https only).
  final String apkUrl;

  /// File name of the chosen .apk asset.
  final String apkName;

  /// Asset size in bytes, or -1 when GitHub did not report one.
  final int apkSize;

  /// html_url of the release page, when present.
  final String? pageUrl;

  /// published_at of the release, when present and parseable.
  final DateTime? publishedAt;
}

/// A semantic version: numeric core plus an optional pre-release
/// ("1.2.0-beta.1"); build metadata is ignored.
/// Port of Kotlin `UpdateLogic.SemVer`.
class SemVer implements Comparable<SemVer> {
  const SemVer(this.core, this.pre);

  final List<int> core;
  final List<String> pre;

  @override
  int compareTo(SemVer other) {
    final n = core.length > other.core.length ? core.length : other.core.length;
    for (var i = 0; i < n; i++) {
      final a = i < core.length ? core[i] : 0;
      final b = i < other.core.length ? other.core[i] : 0;
      final c = a.compareTo(b);
      if (c != 0) return c;
    }
    // A release ranks above any of its pre-releases.
    if (pre.isEmpty || other.pre.isEmpty) {
      final a = other.pre.length > 1 ? 1 : other.pre.length;
      final b = pre.length > 1 ? 1 : pre.length;
      return a - b;
    }
    final m = pre.length > other.pre.length ? pre.length : other.pre.length;
    for (var i = 0; i < m; i++) {
      if (i >= pre.length) return -1;
      if (i >= other.pre.length) return 1;
      final a = pre[i];
      final b = other.pre[i];
      final an = int.tryParse(a);
      final bn = int.tryParse(b);
      final int c;
      if (an != null && bn != null) {
        c = an.compareTo(bn);
      } else if (an != null) {
        c = -1; // numeric identifiers rank below alphanumeric ones
      } else if (bn != null) {
        c = 1;
      } else {
        c = a.compareTo(b);
      }
      if (c != 0) return c;
    }
    return 0;
  }

  @override
  String toString() =>
      core.join('.') + (pre.isEmpty ? '' : '-${pre.join('.')}');
}

/// Pure parts of the updater: version comparison, GitHub release JSON
/// parsing, notes cleanup. Port of Kotlin `UpdateLogic` (unit-tested
/// there; the same cases are mirrored here).
abstract final class UpdateLogic {
  /// The GitHub repository releases are checked against.
  static const String repo = 'kulana121-bit/UpZe-music';
  static const String latestUrl =
      'https://api.github.com/repos/$repo/releases/latest';
  static const String releasesPage = 'https://github.com/$repo/releases';

  /// "v1.0.1", "1.0.1", "V2.3", "1.0.0-rc.1+build5" → [SemVer];
  /// null when it has no leading number.
  static SemVer? parseVersion(String? raw) {
    var s = raw?.trim();
    if (s == null) return null;
    if (s.startsWith('v')) s = s.substring(1);
    if (s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first; // substringBefore('+'): build metadata ignored
    if (s.isEmpty) return null;
    final dash = s.indexOf('-');
    final coreStr = dash < 0 ? s : s.substring(0, dash);
    final pre = dash < 0
        ? const <String>[]
        : s
            .substring(dash + 1)
            .split('.')
            .where((p) => p.isNotEmpty)
            .toList();
    final core = <int>[];
    for (final part in coreStr.split('.')) {
      // Kotlin: part.takeWhile { it.isDigit() } — leading digits only.
      final digits = StringBuffer();
      for (final u in part.codeUnits) {
        if (u < 0x30 || u > 0x39) break;
        digits.writeCharCode(u);
      }
      final v = int.tryParse(digits.toString());
      if (v == null) return null;
      core.add(v);
    }
    if (core.isEmpty) return null;
    return SemVer(core, pre);
  }

  /// True when [remote] is a strictly newer version than [current].
  /// Unparseable versions never count as newer (an unparseable
  /// [current] counts as older than any parseable [remote]).
  static bool isNewer(String? remote, String? current) {
    final r = parseVersion(remote);
    if (r == null) return false;
    final c = parseVersion(current);
    if (c == null) return true;
    return r.compareTo(c) > 0;
  }

  /// Parses GitHub's "latest release" JSON body. Returns null for
  /// drafts, pre-releases, unparseable tags, or a release without a
  /// usable .apk asset (the first asset whose name ends with .apk is
  /// used; its download URL must be https).
  static UpdateInfo? parseRelease(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final o = decoded.cast<String, Object?>();
    String? str(String k) => o[k] is String ? o[k] as String : null;
    if (o['draft'] == true || o['prerelease'] == true) return null;
    final tag = str('tag_name')?.trim();
    if (tag == null || tag.isEmpty) return null;
    var version = tag;
    if (version.startsWith('v')) version = version.substring(1);
    if (version.startsWith('V')) version = version.substring(1);
    if (parseVersion(version) == null) return null;
    Map<String, Object?>? asset;
    final assets = o['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is Map) {
          final m = a.cast<String, Object?>();
          final name = m['name'];
          if (name is String && name.toLowerCase().endsWith('.apk')) {
            asset = m;
            break;
          }
        }
      }
    }
    if (asset == null) return null;
    final url = asset['browser_download_url'];
    if (url is! String || !url.startsWith('https://')) return null;
    final rawName = str('name');
    final size = asset['size'];
    final published = str('published_at');
    return UpdateInfo(
      tag: tag,
      version: version,
      name: (rawName != null && rawName.trim().isNotEmpty) ? rawName : tag,
      notes: cleanNotes(str('body') ?? ''),
      apkUrl: url,
      apkName: asset['name'] as String,
      apkSize: size is num ? size.toInt() : -1,
      pageUrl: str('html_url'),
      publishedAt: published == null ? null : DateTime.tryParse(published),
    );
  }

  static final RegExp _imgRe = RegExp(r'!\[([^\]]*)]\([^)]*\)');
  static final RegExp _linkRe = RegExp(r'\[([^\]]+)]\([^)]*\)');
  static final RegExp _headingRe = RegExp(r'^\s{0,3}#{1,6}\s*');
  static final RegExp _bulletRe = RegExp(r'^(\s*)[*+-]\s+');
  static final RegExp _boldRe = RegExp(r'(\*\*|__)(.+?)\1');
  static final RegExp _italicRe =
      RegExp(r'(?<![\w*])[*_](?!\s)(.+?)(?<!\s)[*_](?![\w*])');
  static final RegExp _blankRunRe = RegExp(r'\n{3,}');

  /// Release notes as plain text: markdown headings, emphasis, code
  /// ticks, links and images reduced to their text.
  static String cleanNotes(String md) {
    final lines = md.replaceAll('\r\n', '\n').split('\n').map((line) {
      var l = line;
      l = l.replaceAllMapped(_imgRe, (m) => m[1] ?? '');
      l = l.replaceAllMapped(_linkRe, (m) => m[1] ?? '');
      l = l.replaceAll(_headingRe, '');
      l = l.replaceAllMapped(_bulletRe, (m) => '${m[1]}• ');
      l = l.replaceAllMapped(_boldRe, (m) => m[2] ?? '');
      l = l.replaceAllMapped(_italicRe, (m) => m[1] ?? '');
      l = l.replaceAll('`', '');
      return l.trimRight();
    });
    return lines.join('\n').replaceAll(_blankRunRe, '\n\n').trim();
  }
}

/// Outcome of an update check. Port of Kotlin `Updater.Result`, with
/// the offered release / failure message attached.
enum UpdateCheckStatus { update, upToDate, failed }

class UpdateCheckOutcome {
  const UpdateCheckOutcome(this.status, {this.info, this.message});

  final UpdateCheckStatus status;

  /// The newer release; non-null exactly when [status] is
  /// [UpdateCheckStatus.update].
  final UpdateInfo? info;

  /// Failure detail when [status] is [UpdateCheckStatus.failed].
  final String? message;
}

/// Failure raised by [Updater.downloadApk] (HTTP error, size
/// mismatch, IO error). The Kotlin surfaces these as a Failed state in
/// the sheet; here they are thrown so the caller decides.
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);
  final String message;
  @override
  String toString() => 'UpdateDownloadException: $message';
}

class _CheckCache {
  const _CheckCache({this.etag, this.body, this.checkedAtMs = 0});
  final String? etag;
  final String? body;
  final int checkedAtMs;
}

/// GitHub Releases update checker + APK downloader.
/// Port of Kotlin `Updater` (the Compose sheet, UpdateSheet.kt, is UI
/// and lives with the Flutter UI layer, not here).
class Updater {
  Updater({
    this.currentVersion = defaultCurrentVersion,
    this.skippedUpdate,
    String? Function()? skippedUpdateProvider,
    http.Client? client,
    this.cacheFile,
    this.log,
  })  : _skippedUpdateProvider = skippedUpdateProvider,
        _client = client ?? http.Client();

  /// The pubspec version this port ships as: `version: 1.0.1+22` in
  /// pubspec.yaml. Only the version NAME ("1.0.1") is compared — the
  /// "+22" build number is ignored, exactly like the Kotlin comparing
  /// against BuildConfig.VERSION_NAME. Callers should pass the running
  /// app's real version name (e.g. from package_info_plus) as
  /// [currentVersion] once they have it; this constant is only the
  /// documented default so a stale value is never silently assumed to
  /// be something else.
  static const String defaultCurrentVersion = '1.0.1';

  /// Kotlin: checks at most once every 12 h on app start.
  static const Duration checkInterval = Duration(hours: 12);

  /// Installed version name the checks compare against.
  final String currentVersion;

  /// Release version the user chose "Skip this version" for
  /// (AppSettings.skippedUpdate). Snapshot value; prefer
  /// `skippedUpdateProvider` when settings can change while the app
  /// runs.
  final String? skippedUpdate;

  final String? Function()? _skippedUpdateProvider;

  /// Optional file for the ETag/checked-at cache (Kotlin:
  /// filesDir/update-check.json). When null, the ETag cache is kept in
  /// memory only and the 12 h gate cannot persist across restarts.
  final File? cacheFile;

  /// Optional sink for the one-line failure notes the Kotlin writes to
  /// its playback log; failures are otherwise silent, as there.
  final void Function(String message)? log;

  final http.Client _client;

  UpdateInfo? _available;
  bool _checking = false;
  String? _memEtag;
  String? _memBody;
  int _memCheckedAtMs = 0;

  /// The newer release to offer (the UI shows its sheet while
  /// non-null). Port of Kotlin `Updater.available`.
  UpdateInfo? get available => _available;

  /// True while a [check] is in flight.
  bool get checking => _checking;

  String? get _effectiveSkipped => _skippedUpdateProvider?.call() ?? skippedUpdate;

  /// Whether [info] should be prompted to the user: it must be
  /// strictly newer than [currentVersion], and — unless this is a
  /// manual check — its version must not be the skipped one. Manual
  /// checks offer a skipped version again, exactly like the Kotlin.
  bool shouldPrompt(UpdateInfo info, {bool manual = false}) {
    if (!UpdateLogic.isNewer(info.version, currentVersion)) return false;
    if (!manual && _effectiveSkipped == info.version) return false;
    return true;
  }

  /// App-start gate (Kotlin: `checkOnStart`): true when the automatic
  /// check is enabled in settings and the last check is at least
  /// [checkInterval] old. Never throws.
  Future<bool> isStartCheckDue({required bool autoUpdateCheckEnabled}) async {
    if (!autoUpdateCheckEnabled) return false;
    final cache = await _readCache();
    final diffMs =
        DateTime.now().millisecondsSinceEpoch - cache.checkedAtMs;
    // Kotlin: skip only while 0 <= diff < INTERVAL.
    return !(diffMs >= 0 && diffMs < checkInterval.inMilliseconds);
  }

  Future<_CheckCache> _readCache() async {
    final f = cacheFile;
    if (f == null) {
      return _CheckCache(
          etag: _memEtag, body: _memBody, checkedAtMs: _memCheckedAtMs);
    }
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        final m = decoded.cast<String, Object?>();
        return _CheckCache(
          etag: m['etag'] as String?,
          body: m['body'] as String?,
          checkedAtMs: (m['checkedAt'] as num?)?.toInt() ?? 0,
        );
      }
    } catch (_) {
      // Missing/corrupt cache behaves like no cache, as in Kotlin.
    }
    return const _CheckCache();
  }

  Future<void> _writeCache(_CheckCache c) async {
    _memEtag = c.etag;
    _memBody = c.body;
    _memCheckedAtMs = c.checkedAtMs;
    final f = cacheFile;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'etag': c.etag,
        'body': c.body,
        'checkedAt': c.checkedAtMs,
      }));
    } catch (_) {
      // Cache persistence is best-effort, as in Kotlin (runCatching).
    }
  }

  /// Checks GitHub now. Manual checks also offer a version the user
  /// skipped before. On [UpdateCheckStatus.update], [available] holds
  /// the release. Never throws.
  Future<UpdateCheckOutcome> check({bool manual = false}) async {
    _checking = true;
    try {
      final cache = await _readCache();
      final headers = <String, String>{
        'User-Agent': 'UpZe',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        if (cache.etag != null && cache.body != null)
          'If-None-Match': cache.etag!,
      };
      final resp = await _client
          .get(Uri.parse(UpdateLogic.latestUrl), headers: headers)
          .timeout(const Duration(seconds: 20));
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final String body;
      if (resp.statusCode == 304 && cache.body != null) {
        body = cache.body!;
      } else if (resp.statusCode >= 200 && resp.statusCode < 300) {
        body = resp.body;
        await _writeCache(
            _CheckCache(etag: resp.headers['etag'], body: body, checkedAtMs: nowMs));
      } else if (resp.statusCode == 404) {
        log?.call('Updater: no published release yet (404)');
        await _writeCache(_CheckCache(
            etag: cache.etag, body: cache.body, checkedAtMs: nowMs));
        return const UpdateCheckOutcome(UpdateCheckStatus.upToDate);
      } else {
        log?.call('Updater: GitHub answered HTTP ${resp.statusCode}');
        return UpdateCheckOutcome(UpdateCheckStatus.failed,
            message: 'GitHub answered HTTP ${resp.statusCode}');
      }
      final after = await _readCache();
      await _writeCache(_CheckCache(
          etag: after.etag, body: after.body, checkedAtMs: nowMs));
      final rel = UpdateLogic.parseRelease(body);
      if (rel == null) {
        log?.call('Updater: latest release has no usable .apk asset');
        return const UpdateCheckOutcome(UpdateCheckStatus.upToDate);
      }
      if (!UpdateLogic.isNewer(rel.version, currentVersion)) {
        return const UpdateCheckOutcome(UpdateCheckStatus.upToDate);
      }
      if (!manual && _effectiveSkipped == rel.version) {
        log?.call('Updater: v${rel.version} skipped by the user');
        return const UpdateCheckOutcome(UpdateCheckStatus.upToDate);
      }
      log?.call(
          'Updater: v${rel.version} available (installed $currentVersion)');
      _available = rel;
      return UpdateCheckOutcome(UpdateCheckStatus.update, info: rel);
    } catch (e) {
      log?.call('Updater: check failed: $e');
      return UpdateCheckOutcome(UpdateCheckStatus.failed, message: '$e');
    } finally {
      _checking = false;
    }
  }

  /// Dismisses the current offer without skipping it
  /// (Kotlin: `later()`).
  void later() {
    _available = null;
  }

  /// The value the caller should persist into
  /// AppSettings.skippedUpdate for "Skip this version", and dismisses
  /// the offer (Kotlin: `skip(version)` — the settings write itself
  /// belongs to the settings store, which this file does not own).
  String skip(UpdateInfo info) {
    later();
    return info.version;
  }

  /// Downloads [info]'s APK into [directory] (Kotlin: cacheDir/updates)
  /// and returns the finished file. A complete earlier download of the
  /// exact asset size is re-used. Progress is reported through
  /// [onProgress] as (done, total) bytes; total is -1 when unknown.
  ///
  /// The returned file still has to be handed to the Android package
  /// installer — see the file header for the FileProvider + intent
  /// steps that remain Android-native. Throws [UpdateDownloadException]
  /// on HTTP errors and size mismatches.
  Future<File> downloadApk(
    UpdateInfo info,
    Directory directory, {
    void Function(int done, int total)? onProgress,
  }) async {
    await directory.create(recursive: true);
    final fileName =
        'UpZe-v${info.version}.apk'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final target = File('${directory.path}/$fileName');
    final part = File('${target.path}.part');
    // Kotlin clears older downloads/partials from the updates folder.
    await for (final e in directory.list()) {
      if (e is File && e.path != target.path && e.path != part.path) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    if (info.apkSize > 0 &&
        await target.exists() &&
        await target.length() == info.apkSize) {
      return target;
    }
    try {
      final request = http.Request('GET', Uri.parse(info.apkUrl));
      request.headers['User-Agent'] = 'UpZe';
      final resp = await _client.send(request);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw UpdateDownloadException('HTTP ${resp.statusCode}');
      }
      final total =
          info.apkSize > 0 ? info.apkSize : (resp.contentLength ?? -1);
      var done = 0;
      var lastEmit = 0;
      onProgress?.call(0, total);
      final sink = part.openWrite();
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          done += chunk.length;
          // Kotlin throttles progress emissions to every 128 KB.
          if (done - lastEmit > 128 * 1024) {
            lastEmit = done;
            onProgress?.call(done, total);
          }
        }
      } finally {
        await sink.close();
      }
      onProgress?.call(done, total);
      if (info.apkSize > 0 && done != info.apkSize) {
        throw UpdateDownloadException(
            'size mismatch ($done of ${info.apkSize} bytes)');
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      log?.call('Updater: downloaded $fileName ($done bytes)');
      return target;
    } on UpdateDownloadException {
      try {
        await part.delete();
      } catch (_) {}
      rethrow;
    } catch (e) {
      try {
        await part.delete();
      } catch (_) {}
      throw UpdateDownloadException('$e');
    }
  }
}
