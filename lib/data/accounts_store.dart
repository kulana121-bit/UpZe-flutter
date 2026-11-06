// Port of account/AccountStore.kt + the pure helpers of account/Sessions.kt
// (UpZe v1.0.1, com.ravi.musicspot.account).
//
// The Kotlin store keeps ONE account per service (Account: id, service,
// name/email/avatar, secret, extra) and persists the whole list as a single
// sealed blob. This port flattens that to the fields the Flutter sources
// actually consume — SubsonicConfig / JellyfinConfig for the server
// sources, the Spotify sp_dc cookie, the Jamendo client id — plus the
// first-run setup state (setup done + picked seed artists) that the Kotlin
// keeps in Settings / SeedArtists.
//
// ⚠️ ENCRYPTION — honest note, do not "fix" by faking it: the Kotlin seals
// this data with AES-256-GCM whose key lives in the Android Keystore
// (core/Crypto.kt GcmBox, alias "musicspot.accounts.v1"), and the backing
// file is excluded from cloud backup / device transfer. There is NO
// equivalent in this Flutter port: values are written as PLAIN JSON to
// accounts.json inside the app-private support directory (the filesDir
// equivalent — other apps cannot read it on a non-rooted device, but it is
// NOT encrypted at rest). Secrets are never logged and never shown in UI
// strings, matching the Kotlin's redacted Account.toString rule. If real
// at-rest encryption is wanted later, seal this file's contents with a
// Keystore-backed key via a platform channel and keep this same API.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sources/servers_source.dart';
import '../yt/innertube.dart';

/// Turns a cookie header captured by a sign-in WebView into saved-account
/// material. Only the pure parsing half of Sessions.kt lives here; the
/// sign-in flows themselves (cookie → profile fetch → upsert → sync) belong
/// to the account UI / sync layer.
abstract final class Sessions {
  /// True when a YouTube/Google cookie header carries a signed-in session
  /// (SAPISID or its __Secure variants). (Kotlin: Sessions.isYouTubeSession)
  static bool isYouTubeSession(String? cookieHeader) =>
      cookieHeader != null && Innertube.sapisidFrom(cookieHeader) != null;

  /// The sp_dc value from a cookie header, if present.
  /// (Kotlin: Sessions.spDcFrom)
  static String? spDcFrom(String? cookieHeader) {
    if (cookieHeader == null) return null;
    for (final part in cookieHeader.split(';')) {
      final p = part.trim();
      if (p.startsWith('sp_dc=')) {
        final v = p.substring('sp_dc='.length);
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }
}

/// Service accounts + first-run setup state (accounts.json).
///
/// Mirrors the Kotlin store's rules where they apply: one active account
/// per service (a setter replaces, null clears), every mutation notifies
/// listeners immediately and persists debounced, and a file that fails to
/// parse is dropped rather than crashing the boot. Persistence follows the
/// same manual-listener pattern as the other repos (PlayStatsRepo & co).
class AccountsStore {
  AccountsStore(String dirPath) : _file = File('$dirPath/accounts.json');

  final File _file;
  final List<void Function()> _listeners = [];
  Timer? _saveTimer;

  SubsonicConfig? _subsonic;
  JellyfinConfig? _jellyfin;
  String? _spotifyCookie;
  String? _jamendoClientId;
  bool _setupDone = false;
  List<String> _seedArtistIds = const [];

  // ---- accounts ------------------------------------------------------------

  /// Subsonic/Navidrome account == Kotlin Account(SUBSONIC) with
  /// extra = baseUrl, name = user, secret = password.
  SubsonicConfig? get subsonic => _subsonic;
  bool get hasSubsonic => _subsonic != null;

  /// Jellyfin account == Kotlin Account(JELLYFIN) with
  /// extra = "<server>|<userId>", secret = access token.
  JellyfinConfig? get jellyfin => _jellyfin;
  bool get hasJellyfin => _jellyfin != null;

  /// Spotify sp_dc cookie == Kotlin Account(SPOTIFY).secret.
  String? get spotifyCookie => _spotifyCookie;
  bool get hasSpotify => _spotifyCookie != null;

  /// Jamendo developer client_id (Settings → Sources in the Kotlin).
  String? get jamendoClientId => _jamendoClientId;

  // ---- setup state -----------------------------------------------------------

  /// First-run setup (welcome + artist picker) completed.
  bool get setupDone => _setupDone;

  /// Ids of the artists picked in the setup picker ("yt:UC…"),
  /// SeedArtists.state in the Kotlin.
  List<String> get seedArtistIds => List.unmodifiable(_seedArtistIds);
  bool isSeedSelected(String id) => _seedArtistIds.contains(id);

  // ---- listeners -------------------------------------------------------------

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  // ---- mutations (each notifies + persists) -----------------------------------

  void setSubsonic(SubsonicConfig? config) {
    _subsonic = config;
    _save();
  }

  void setJellyfin(JellyfinConfig? config) {
    _jellyfin = config;
    _save();
  }

  void setSpotifyCookie(String? cookie) {
    _spotifyCookie = (cookie?.trim().isEmpty ?? true) ? null : cookie!.trim();
    _save();
  }

  void setJamendoClientId(String? clientId) {
    _jamendoClientId =
        (clientId?.trim().isEmpty ?? true) ? null : clientId!.trim();
    _save();
  }

  void setSetupDone(bool done) {
    _setupDone = done;
    _save();
  }

  void setSeedArtistIds(List<String> ids) {
    _seedArtistIds = ids.toSet().toList();
    _save();
  }

  /// Toggle one seed artist (SeedArtists.toggle in the Kotlin).
  void toggleSeedArtist(String id) {
    _seedArtistIds = _seedArtistIds.contains(id)
        ? _seedArtistIds.where((e) => e != id).toList()
        : [..._seedArtistIds, id];
    _save();
  }

  /// Removes every account (setup state is kept). Kotlin: remove() per
  /// service.
  void clearAccounts() {
    _subsonic = null;
    _jellyfin = null;
    _spotifyCookie = null;
    _jamendoClientId = null;
    _save();
  }

  // ---- persistence -------------------------------------------------------------

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          final sub = decoded['subsonic'] as Map<String, dynamic>?;
          _subsonic = sub == null
              ? null
              : SubsonicConfig(
                  baseUrl: sub['baseUrl'] as String? ?? '',
                  user: sub['user'] as String? ?? '',
                  password: sub['password'] as String? ?? '',
                );
          final jel = decoded['jellyfin'] as Map<String, dynamic>?;
          _jellyfin = jel == null
              ? null
              : JellyfinConfig(
                  baseUrl: jel['baseUrl'] as String? ?? '',
                  userId: jel['userId'] as String? ?? '',
                  accessToken: jel['accessToken'] as String? ?? '',
                );
          _spotifyCookie = decoded['spotifyCookie'] as String?;
          _jamendoClientId = decoded['jamendoClientId'] as String?;
          _setupDone = decoded['setupDone'] as bool? ?? false;
          _seedArtistIds =
              ((decoded['seedArtistIds'] as List?) ?? const []).cast<String>();
        }
      }
    } catch (_) {
      // A value that fails to parse is dropped (Kotlin load() does the same
      // when decryption fails after a restore).
    }
  }

  void _save() {
    for (final l in List.of(_listeners)) {
      l();
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flush);
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(<String, dynamic>{
        'subsonic': _subsonic == null
            ? null
            : <String, dynamic>{
                'baseUrl': _subsonic!.baseUrl,
                'user': _subsonic!.user,
                'password': _subsonic!.password,
              },
        'jellyfin': _jellyfin == null
            ? null
            : <String, dynamic>{
                'baseUrl': _jellyfin!.baseUrl,
                'userId': _jellyfin!.userId,
                'accessToken': _jellyfin!.accessToken,
              },
        'spotifyCookie': _spotifyCookie,
        'jamendoClientId': _jamendoClientId,
        'setupDone': _setupDone,
        'seedArtistIds': _seedArtistIds,
      }));
    } catch (_) {}
  }

  /// Writes any pending debounced save immediately.
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _flush();
    }
  }
}
