// Background audio integration for the UpZe Flutter rewrite.
//
// WHY THIS FILE IS *NOT* A BaseAudioHandler
// -----------------------------------------
// A hand-written `BaseAudioHandler` (package:audio_service) owns its own
// player and its own queue/media-item state. just_audio_background already
// ships exactly such a handler internally (its `SwitchAudioHandler`): once
// [JustAudioBackground.init] has run, *every* just_audio `AudioPlayer`
// automatically gets a media notification, lock-screen controls and
// headset/media-button handling, driven by the `MediaItem` tag attached to
// each `AudioSource`. Writing a second BaseAudioHandler on top would mean
// two handlers fighting over the same media session and two copies of the
// queue state to keep in sync — the conflict the task brief anticipated.
//
// So this file implements the documented just_audio_background approach:
//
//   1. [initBackgroundAudio] — one guarded call from `main()`.
//   2. [mediaItemFor] / [audioSourceFor] — the Track (+ Resolved) ->
//      MediaItem / AudioSource mapping the PlayerController uses for every
//      track it loads, so the notification always shows the right song and
//      the stream-info label the Kotlin app shows in its player
//      ("Playing from JioSaavn · 320 kbps" etc.).
//
// Media3 comparison: this replaces PlaybackService's MediaSession +
// DefaultMediaNotification.Provider. Equivalent for notification /
// lock-screen / media-button purposes; it does NOT give the app a
// MediaSession other Android apps can browse (the Kotlin service didn't
// expose a browsable tree either — its callback only normalised items).

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../models/track.dart';
import '../sources/music_source.dart';

/// Keys used in [MediaItem.extras]. Values are Strings (extras values must
/// be int/String/bool/double for the platform channel).
abstract final class UpZeMediaExtras {
  /// The resolved stream's human label, e.g. "JioSaavn · aac · 320 kbps".
  /// (Kotlin: NowStream.info.label, shown in the player UI.)
  static const String streamInfo = 'upze.streamInfo';

  /// Serialized [SourceKind] name of the source actually playing
  /// ("YOUTUBE", "JIOSAAVN", ...) — may differ from the track's own source
  /// after a cross-source failover.
  static const String streamSource = 'upze.streamSource';

  /// Set when YouTube was exhausted/excluded and another source plays
  /// instead; value is that source's display label. Absent otherwise.
  /// (Kotlin: NowStream.fallbackFrom — UI shows "Playing from …".)
  static const String fallbackFrom = 'upze.fallbackFrom';

  /// Cache key of the exact rendition playing (Resolved.cacheKey).
  static const String cacheKey = 'upze.cacheKey';

  /// The full Track as a JSON string, so a future browsable handler /
  /// notification tap can recover it without a lookup.
  /// (Kotlin: the track JSON stored in the MediaItem extras bundle.)
  static const String trackJson = 'upze.trackJson';
}

/// Initialise just_audio_background. Call once from `main()` *before*
/// `runApp`, and await it there.
///
/// Guarded: on platforms without the audio_service plugin (desktop unit
/// tests, `flutter test`, web) the init throws — the caller in main.dart
/// catches that and the app still runs with foreground-only playback.
/// Returns true when background playback is active.
Future<bool> initBackgroundAudio() async {
  try {
    await JustAudioBackground.init(
      // Channel id only needs to be unique within the app; it is NOT the
      // applicationId (which stays com.ravi.musicspot in the Android
      // scaffold, unchanged by this layer).
      androidNotificationChannelId: 'com.ravi.musicspot.channel.audio',
      androidNotificationChannelName: 'Music playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    );
    return true;
  } catch (_) {
    // No background plugin on this platform/build: foreground playback
    // still works; the controller does not depend on this succeeding.
    return false;
  }
}

/// Map a [Track] to the [MediaItem] tag just_audio_background puts in the
/// notification / lock screen. When [resolved] is known (it always is by
/// the time the controller loads a track), its stream info rides along in
/// the extras; before resolution, pass null and only the track's own
/// metadata is shown.
MediaItem mediaItemFor(Track track, [Resolved? resolved]) {
  return MediaItem(
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration:
        track.durationMs > 0 ? Duration(milliseconds: track.durationMs) : null,
    artUri: track.artUrl == null ? null : Uri.tryParse(track.artUrl!),
    displayTitle: track.title,
    displaySubtitle: track.artist,
    extras: <String, dynamic>{
      UpZeMediaExtras.trackJson: track.toJsonString(),
      if (resolved != null) ...{
        UpZeMediaExtras.streamInfo: resolved.info.label,
        UpZeMediaExtras.streamSource: resolved.info.source.serializedName,
        UpZeMediaExtras.cacheKey: resolved.cacheKey,
        if (resolved.fallbackFrom != null)
          UpZeMediaExtras.fallbackFrom: resolved.fallbackFrom!.label,
      },
    },
  );
}

/// The [AudioSource] the controller hands to just_audio for one resolved
/// track: the stream URI + the resolver's headers (a googlevideo URL must
/// be fetched as the client that minted it — same rule as the Kotlin
/// ResolvingDataSource), tagged with [mediaItemFor] so background controls
/// follow the song.
AudioSource audioSourceFor(Track track, Resolved resolved) {
  return AudioSource.uri(
    Uri.parse(resolved.uri),
    headers: resolved.headers.isEmpty ? null : resolved.headers,
    tag: mediaItemFor(track, resolved),
  );
}
