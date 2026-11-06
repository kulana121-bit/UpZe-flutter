// Mini player (Kotlin: ui/chrome/Chrome.kt MiniPlayer + MiniProgressLine).
//
// Compact glass bar that sits above the dock: artwork, title/artist,
// play-pause, next, and a thin progress line along the bottom edge. Same
// injection contract as FullPlayer — streams and callbacks in, no playback
// imports. Renders nothing when there is no current track.

import 'package:flutter/material.dart';

import '../../data/settings_store.dart';
import '../../models/track.dart';
import '../theme.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.track,
    required this.playingStream,
    required this.onTogglePlay,
    this.positionStream,
    this.durationStream,
    this.onNext,
    this.onTap,
    this.streamInfo,
    this.glassStyle = GlassStyle.liquid,
  });

  final Track? track;
  final Stream<bool> playingStream;
  final VoidCallback onTogglePlay;

  /// Optional: when both are provided a progress line is drawn.
  final Stream<Duration>? positionStream;
  final Stream<Duration?>? durationStream;

  final VoidCallback? onNext;

  /// Opens the full player.
  final VoidCallback? onTap;

  final StreamInfo? streamInfo;
  final GlassStyle glassStyle;

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: GlassContainer(
        glassStyle: glassStyle,
        strong: true,
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                child: Row(
                  children: [
                    ArtworkImage(url: t.artUrl, size: 44, radius: 9),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            streamInfo == null
                                ? t.artist
                                : '${t.artist} · ${streamInfo!.label}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream: playingStream,
                      initialData: false,
                      builder: (context, snap) => IconButton(
                        icon: Icon(
                          (snap.data ?? false)
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        onPressed: onTogglePlay,
                      ),
                    ),
                    if (onNext != null)
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        onPressed: onNext,
                      ),
                  ],
                ),
              ),
              if (positionStream != null && durationStream != null)
                StreamBuilder<Duration>(
                  stream: positionStream,
                  initialData: Duration.zero,
                  builder: (context, posSnap) => StreamBuilder<Duration?>(
                    stream: durationStream,
                    builder: (context, durSnap) {
                      final total = durSnap.data ?? Duration.zero;
                      final pos = posSnap.data ?? Duration.zero;
                      return LinearProgressIndicator(
                        value: total.inMilliseconds > 0
                            ? (pos.inMilliseconds / total.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : null,
                        minHeight: 2,
                        backgroundColor: Colors.transparent,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
