// Full-screen player (Kotlin: ui/player/Player.kt PlayerScreen /
// FullPane.kt — the Classic pane).
//
// Four looks, one contract (Settings → PlayerStyle):
//  - classic: square artwork over title, seek, controls, queue list
//    (Kotlin FullPane).
//  - aura: the artwork becomes a blurred wash behind everything and the
//    controls float in one liquid-glass deck (Kotlin AuraPlayer).
//  - vinyl ("Deck"): the artwork is a spinning record with a tonearm;
//    seek + transport live in a glass deck panel, the queue collapses
//    behind an expansion tile (inspired by Kotlin VinylPlayer/Deck).
//  - minimal ("Poster"): the artwork fills the whole pane behind a
//    bottom scrim; only title, seek and transport sit at the bottom,
//    the queue opens as a sheet (Kotlin MinimalPlayer poster mode).
//
// This widget is deliberately "dumb": the current track, queue and
// StreamInfo arrive as values, the high-frequency position / duration /
// playing state arrives as streams, and every action leaves through a
// callback. The playback layer (lib/playback) is wired in by whoever hosts
// this widget — see AppShell for the reference wiring. Every style drives
// the exact same callbacks and streams.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../data/settings_store.dart';
import '../../models/track.dart';
import '../theme.dart';

class FullPlayer extends StatelessWidget {
  const FullPlayer({
    super.key,
    required this.track,
    required this.positionStream,
    required this.durationStream,
    required this.playingStream,
    required this.onSeek,
    required this.onNext,
    required this.onPrev,
    required this.onTogglePlay,
    required this.onToggleLike,
    required this.queue,
    required this.onJumpTo,
    this.streamInfo,
    this.currentIndex = -1,
    this.isLiked = false,
    this.onShowLyrics,
    this.onDownload,
    this.onClose,
    this.glassStyle = GlassStyle.liquid,
    this.style = PlayerStyle.classic,
  });

  /// The track on screen; null shows an empty state.
  final Track? track;

  /// What the player actually resolved for [track] — its label is the
  /// quality/source line ("YouTube Music · opus · 160 kbps · 48.0 kHz").
  final StreamInfo? streamInfo;

  final Stream<Duration> positionStream;
  final Stream<Duration?> durationStream;
  final Stream<bool> playingStream;

  final ValueChanged<Duration> onSeek;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onTogglePlay;

  /// Toggle like for the current [track].
  final VoidCallback onToggleLike;

  /// The active queue and the index of [track] inside it.
  final List<Track> queue;
  final int currentIndex;
  final ValueChanged<int> onJumpTo;

  final bool isLiked;

  /// Lyrics button action; null hides the button.
  final VoidCallback? onShowLyrics;

  /// Download-this-track action; null hides the button.
  final VoidCallback? onDownload;

  /// Collapse action (chevron); null hides it.
  final VoidCallback? onClose;

  final GlassStyle glassStyle;

  /// Which of the four player designs to render.
  final PlayerStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = track;
    if (t == null) {
      return Center(
        child: Text(
          'Nothing is playing',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return switch (style) {
      PlayerStyle.classic => _classic(context, t),
      PlayerStyle.aura => _aura(context, t),
      PlayerStyle.vinyl => _vinyl(context, t),
      PlayerStyle.minimal => _minimal(context, t),
    };
  }

  // ---------------------------------------------------------------- styles

  Widget _classic(BuildContext context, Track t) {
    final artSize = MediaQuery.of(context).size.width - 64;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _topBar(context, t),
          const SizedBox(height: 12),
          Center(
            child: ArtworkImage(url: t.artUrl, size: artSize, radius: 20),
          ),
          const SizedBox(height: 24),
          _titleBlock(context, t),
          const SizedBox(height: 8),
          _seekBar(t),
          const SizedBox(height: 4),
          _controls(context),
          _streamLine(context),
          ..._queueWidgets(),
        ],
      ),
    );
  }

  Widget _aura(BuildContext context, Track t) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    final artSize = width - 96;
    return Stack(
      children: [
        // Blurred artwork wash behind everything (AuraPlayer's aura).
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.45,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 46, sigmaY: 46),
                child: Transform.scale(
                  scale: 1.3,
                  child: Center(
                    child: ArtworkImage(url: t.artUrl, size: width, radius: 0),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surface.withValues(alpha: 0.30),
                  scheme.surface.withValues(alpha: 0.82),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _topBar(context, t),
              const SizedBox(height: 16),
              Center(
                child: GlassContainer(
                  glassStyle: glassStyle,
                  strong: true,
                  borderRadius: const BorderRadius.all(Radius.circular(30)),
                  padding: const EdgeInsets.all(10),
                  child: ArtworkImage(url: t.artUrl, size: artSize, radius: 22),
                ),
              ),
              const SizedBox(height: 20),
              _titleBlock(context, t),
              const SizedBox(height: 14),
              // One floating glass deck carries seek + transport + quality.
              GlassContainer(
                glassStyle: glassStyle,
                strong: true,
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _seekBar(t),
                    _controls(context),
                    _streamLine(context),
                  ],
                ),
              ),
              ..._queueWidgets(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _vinyl(BuildContext context, Track t) {
    final width = MediaQuery.of(context).size.width;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _topBar(context, t),
          const SizedBox(height: 6),
          Center(
            child: _SpinningDisc(
              track: t,
              playingStream: playingStream,
              size: width * 0.8,
            ),
          ),
          const SizedBox(height: 18),
          _titleBlock(context, t, center: true),
          const SizedBox(height: 12),
          // Deck panel: seek + transport on one glass plate.
          GlassContainer(
            glassStyle: glassStyle,
            strong: true,
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _seekBar(t),
                _controls(context),
              ],
            ),
          ),
          _streamLine(context),
          if (queue.length > 1) _queueExpansion(context),
        ],
      ),
    );
  }

  Widget _minimal(BuildContext context, Track t) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        // Poster: artwork fills the whole pane.
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, c) {
              final s = math.max(c.maxWidth, c.maxHeight);
              return Center(
                child: ArtworkImage(url: t.artUrl, size: s, radius: 0),
              );
            },
          ),
        ),
        // Bottom scrim so the controls stay readable.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.5, 0.82],
                colors: [
                  scheme.surface.withValues(alpha: 0.25),
                  scheme.surface.withValues(alpha: 0.45),
                  scheme.surface,
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: _topBar(context, t),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _titleBlock(context, t),
                    const SizedBox(height: 4),
                    _seekBar(t),
                    _controls(context),
                    _streamLine(context),
                    if (queue.length > 1)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.queue_music, size: 18),
                          label: Text('Up next · ${queue.length}'),
                          onPressed: () => _showQueue(context),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- pieces

  /// Collapse chevron, source/quality pill, lyrics button.
  Widget _topBar(BuildContext context, Track t) {
    final theme = Theme.of(context);
    return Row(
      children: [
        if (onClose != null)
          IconButton(
            icon: const Icon(Icons.expand_more),
            tooltip: 'Collapse',
            onPressed: onClose,
          )
        else
          const SizedBox(width: 48),
        Expanded(
          child: Center(
            child: GlassContainer(
              glassStyle: glassStyle,
              borderRadius: const BorderRadius.all(Radius.circular(99)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                streamInfo?.label ?? t.source.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ),
        if (onShowLyrics != null)
          IconButton(
            icon: const Icon(Icons.lyrics_outlined),
            tooltip: 'Lyrics',
            onPressed: onShowLyrics,
          ),
        if (onDownload != null)
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download',
            onPressed: onDownload,
          ),
        if (onShowLyrics == null && onDownload == null)
          const SizedBox(width: 48),
      ],
    );
  }

  /// Title / artist block with the like button.
  Widget _titleBlock(BuildContext context, Track t, {bool center = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisAlignment:
          center ? MainAxisAlignment.center : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: Column(
            crossAxisAlignment:
                center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max,
                mainAxisAlignment:
                    center ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: center ? TextAlign.center : TextAlign.start,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (t.explicit) ...[
                    const SizedBox(width: 6),
                    const ExplicitBadge(),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                t.album == null ? t.artist : '${t.artist} · ${t.album}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: center ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(
            isLiked ? Icons.favorite : Icons.favorite_border,
            color: isLiked ? scheme.primary : null,
          ),
          tooltip: isLiked ? 'Unlike' : 'Like',
          onPressed: onToggleLike,
        ),
      ],
    );
  }

  Widget _seekBar(Track t) => _SeekBar(
        track: t,
        positionStream: positionStream,
        durationStream: durationStream,
        onSeek: onSeek,
      );

  /// Prev / play-pause / next transport row.
  Widget _controls(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 34,
          icon: const Icon(Icons.skip_previous),
          onPressed: onPrev,
        ),
        const SizedBox(width: 12),
        StreamBuilder<bool>(
          stream: playingStream,
          initialData: false,
          builder: (context, snap) => FilledButton(
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(18),
            ),
            onPressed: onTogglePlay,
            child: Icon(
              (snap.data ?? false) ? Icons.pause : Icons.play_arrow,
              size: 32,
            ),
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          iconSize: 34,
          icon: const Icon(Icons.skip_next),
          onPressed: onNext,
        ),
      ],
    );
  }

  /// The resolved stream's quality line (nothing when unresolved).
  Widget _streamLine(BuildContext context) {
    final info = streamInfo;
    if (info == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Center(
        child: Text(
          info.label,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// "Up next" list section (classic + aura).
  List<Widget> _queueWidgets() {
    if (queue.length <= 1) return const [];
    return [
      const SectionHeader(title: 'Up next'),
      for (var i = 0; i < queue.length; i++)
        TrackTile(
          track: queue[i],
          isCurrent: i == currentIndex,
          onTap: () => onJumpTo(i),
        ),
    ];
  }

  /// The queue behind one expansion tile (vinyl).
  Widget _queueExpansion(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        title: const Text('Up next'),
        subtitle: Text('${queue.length} tracks'),
        children: [
          for (var i = 0; i < queue.length; i++)
            TrackTile(
              track: queue[i],
              isCurrent: i == currentIndex,
              onTap: () => onJumpTo(i),
            ),
        ],
      ),
    );
  }

  /// The queue as a modal sheet (minimal — no room for a list in-pane).
  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const SectionHeader(title: 'Up next'),
            for (var i = 0; i < queue.length; i++)
              TrackTile(
                track: queue[i],
                isCurrent: i == currentIndex,
                onTap: () {
                  onJumpTo(i);
                  Navigator.of(sheetCtx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// The Deck's record: circular artwork spinning while [playingStream] is
/// true, groove rings, a spindle hole, and a tonearm that swings in over
/// the record when playback starts.
class _SpinningDisc extends StatefulWidget {
  const _SpinningDisc({
    required this.track,
    required this.playingStream,
    required this.size,
  });

  final Track track;
  final Stream<bool> playingStream;
  final double size;

  @override
  State<_SpinningDisc> createState() => _SpinningDiscState();
}

class _SpinningDiscState extends State<_SpinningDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );
  StreamSubscription<bool>? _sub;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.playingStream.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
      if (p) {
        _spin.repeat();
      } else {
        _spin.stop();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          AnimatedBuilder(
            animation: _spin,
            builder: (context, child) => Transform.rotate(
              angle: _spin.value * 2 * math.pi,
              child: child,
            ),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF17171B),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Stack(
                children: [
                  for (final inset in [10.0, 22.0, 34.0])
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.all(inset),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: ArtworkImage(
                      url: widget.track.artUrl,
                      size: size * 0.62,
                      radius: size,
                    ),
                  ),
                  Center(
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.surface,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Tonearm: pivot at the top-right, rod swings over the record.
          Positioned(
            top: 2,
            right: size * 0.06,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: _playing ? 0.42 : 0.14),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOut,
              builder: (context, angle, child) => Transform.rotate(
                angle: angle,
                alignment: Alignment.topCenter,
                child: child,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.surfaceContainerHighest,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.20),
                      ),
                    ),
                    child: Icon(
                      Icons.circle,
                      size: 8,
                      color: scheme.primary,
                    ),
                  ),
                  Container(
                    width: 5,
                    height: size * 0.34,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Seek slider fed by the position/duration streams. Dragging only seeks
/// on release (onChangeEnd), like the original's slider.
class _SeekBar extends StatelessWidget {
  const _SeekBar({
    required this.track,
    required this.positionStream,
    required this.durationStream,
    required this.onSeek,
  });

  final Track track;
  final Stream<Duration> positionStream;
  final Stream<Duration?> durationStream;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<Duration>(
      stream: positionStream,
      initialData: Duration.zero,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: durationStream,
          builder: (context, durSnap) {
            final position = posSnap.data ?? Duration.zero;
            var total = durSnap.data ?? Duration.zero;
            if (total == Duration.zero && track.durationMs > 0) {
              total = Duration(milliseconds: track.durationMs);
            }
            final maxMs = total.inMilliseconds.toDouble();
            final valueMs =
                position.inMilliseconds.toDouble().clamp(0.0, maxMs);
            return Column(
              children: [
                Slider(
                  value: maxMs > 0 ? valueMs : 0,
                  max: maxMs > 0 ? maxMs : 1,
                  onChanged: maxMs > 0 ? (_) {} : null,
                  onChangeEnd: maxMs > 0
                      ? (v) => onSeek(Duration(milliseconds: v.round()))
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatClock(position.inMilliseconds),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        formatClock(total.inMilliseconds),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
