// UpZe Flutter UI — theme + shared glass/track widgets.
//
// Palette and glass grades port the Kotlin originals:
//   ui/theme/Theme.kt — Ms dark palette (canvas #141317, soft-rose accent
//   #E7A9B0) / MsLight palette; softScheme() builds from an accent seed.
//   ui/glass/Glass.kt — glass grades driven by GlassStyle: Liquid lens film
//   alpha ~0.38 (strong 0.62), Frosted ~0.58 (strong 0.72), Water = clear aqua
//   (lighter film, more blur), Solid = no blur, ~0.94 film. Every grade has a
//   white edge highlight (rim ~0.32 alpha at the top).
// Flutter equivalent of the backdrop grades is BackdropFilter blur, which is
// what GlassContainer below does.

import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
// ThemeMode here is UpZe's own (data/settings_store.dart), not Material's.
import 'package:flutter/material.dart' hide ThemeMode;

import '../data/settings_store.dart';
import '../models/track.dart';

/// Raw palette values from Kotlin's Ms / MsLight objects.
abstract final class UpZePalette {
  // Dark (Ms)
  static const Color canvasDark = Color(0xFF141317);
  static const Color surface1Dark = Color(0xFF1A191E);
  static const Color surface2Dark = Color(0xFF221F26);
  static const Color surface3Dark = Color(0xFF2B282F);
  static const Color accentDark = Color(0xFFE7A9B0); // soft rose
  static const Color onAccentDark = Color(0xFF2B1314);
  static const Color textDark = Color(0xFFE9E5E7);
  static const Color textSecondaryDark = Color(0xFFB7B2B9);
  static const Color textTertiaryDark = Color(0xFF9A98A0);

  // Light (MsLight)
  static const Color canvasLight = Color(0xFFF7F4F2);
  static const Color surface1Light = Color(0xFFF1EDEA);
  static const Color surface2Light = Color(0xFFE9E4E1);
  static const Color surface3Light = Color(0xFFE0DAD7);
  static const Color accentLight = Color(0xFF9A4F5A);
  static const Color onAccentLight = Color(0xFFFFFFFF);
  static const Color textLight = Color(0xFF1C1B1F);
  static const Color textSecondaryLight = Color(0xFF4A4850);
}

/// Builds the app [ThemeData] from [AppSettings] (Kotlin: softScheme /
/// softLightScheme). [accentSeed] — e.g. the current track's artwork colour —
/// is only used when the user has dynamic colour on, mirroring the original's
/// album-art-seeded scheme.
ThemeData buildUpZeTheme(AppSettings settings, {Color? accentSeed}) {
  final dark = settings.themeMode != ThemeMode.light;
  final pureBlack = settings.themeMode == ThemeMode.pureBlack;
  final accent = settings.dynamicColor && accentSeed != null
      ? accentSeed
      : (dark ? UpZePalette.accentDark : UpZePalette.accentLight);

  final canvas = pureBlack
      ? Colors.black
      : (dark ? UpZePalette.canvasDark : UpZePalette.canvasLight);
  final s1 = pureBlack
      ? const Color(0xFF0B0B0D)
      : (dark ? UpZePalette.surface1Dark : UpZePalette.surface1Light);
  final s2 = pureBlack
      ? const Color(0xFF141417)
      : (dark ? UpZePalette.surface2Dark : UpZePalette.surface2Light);
  final s3 = pureBlack
      ? const Color(0xFF1C1C20)
      : (dark ? UpZePalette.surface3Dark : UpZePalette.surface3Light);
  final onSurface = dark ? UpZePalette.textDark : UpZePalette.textLight;
  final onSurfaceVariant =
      dark ? UpZePalette.textSecondaryDark : UpZePalette.textSecondaryLight;

  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: accent,
    onPrimary: dark ? UpZePalette.onAccentDark : UpZePalette.onAccentLight,
    surface: s1,
    onSurface: onSurface,
    onSurfaceVariant: onSurfaceVariant,
    surfaceContainerLow: s1,
    surfaceContainer: s1,
    surfaceContainerHigh: s2,
    surfaceContainerHighest: s3,
    outlineVariant: dark ? const Color(0xFF312E36) : const Color(0xFFCAC4C2),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: onSurface,
      elevation: 0,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
    ),
    visualDensity: VisualDensity.standard,
  );
}

/// Blur radius + film alpha for one [GlassStyle] grade (from Glass.kt).
class GlassSpec {
  const GlassSpec({required this.blur, required this.alpha, required this.strongAlpha});

  final double blur;
  final double alpha;
  final double strongAlpha;

  static GlassSpec of(GlassStyle style) => switch (style) {
        GlassStyle.liquid => const GlassSpec(blur: 28, alpha: 0.36, strongAlpha: 0.55),
        GlassStyle.frosted => const GlassSpec(blur: 20, alpha: 0.52, strongAlpha: 0.68),
        GlassStyle.water => const GlassSpec(blur: 36, alpha: 0.26, strongAlpha: 0.40),
        GlassStyle.solid => const GlassSpec(blur: 0, alpha: 0.94, strongAlpha: 0.96),
      };
}

/// Frosted-glass surface: backdrop blur + translucent tinted film + a light
/// edge highlight and a faint top sheen (Kotlin: Modifier.glass).
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.glassStyle = GlassStyle.liquid,
    this.strong = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    this.tint,
    this.margin,
  });

  final Widget child;
  final GlassStyle glassStyle;

  /// Stronger film (sheets, docks, the mini player).
  final bool strong;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = GlassSpec.of(glassStyle);
    final base = tint ?? scheme.surfaceContainerHigh;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final alpha = strong ? spec.strongAlpha : spec.alpha;
    final edgeTop = Colors.white.withValues(alpha: dark ? 0.32 : 0.55);
    final edgeRest = Colors.white.withValues(alpha: dark ? 0.10 : 0.22);

    Widget content = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: spec.blur, sigmaY: spec.blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(
                  edgeTop.withValues(alpha: 0.10),
                  base.withValues(alpha: (alpha + 0.08).clamp(0.0, 1.0)),
                ),
                base.withValues(alpha: alpha),
              ],
            ),
            // Uniform border colour only: Flutter forbids per-side colours
            // together with borderRadius (paint-time assert, caught by the
            // boot widget test). The brighter top edge lives in the
            // gradient above (edgeTop is mixed into its first stop).
            border: Border.all(color: edgeRest, width: 0.75),
          ),
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            child: child,
          ),
        ),
      ),
    );
    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }
    return content;
  }
}

/// "3:45" / "1:02:03" clock label for a millisecond duration.
String formatClock(int ms) {
  if (ms <= 0) return '0:00';
  final totalSec = ms ~/ 1000;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Square artwork with a graceful placeholder (Kotlin: CoverBox fallback).
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.url,
    required this.size,
    this.radius = 10,
  });

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.42,
        color: scheme.onSurfaceVariant,
      ),
    );
    final u = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: (u == null || u.isEmpty)
            ? placeholder
            : CachedNetworkImage(
                imageUrl: u,
                width: size,
                height: size,
                fit: BoxFit.cover,
                placeholder: (_, __) => placeholder,
                errorWidget: (_, __, ___) => placeholder,
              ),
      ),
    );
  }
}

/// Small "E" box shown next to explicit tracks.
class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'E',
        style: TextStyle(
          fontSize: 8,
          height: 1,
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Pill naming the track's source ("YouTube Music", "JioSaavn", …).
class SourceChip extends StatelessWidget {
  const SourceChip({super.key, required this.source});

  final SourceKind source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        source.label,
        maxLines: 1,
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Standard track row: artwork, title (+ explicit badge), artist, source
/// chip, duration. Used by Search, Library, Explore and the player queue.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.trailing,
    this.isCurrent = false,
    this.showSourceChip = true,
  });

  final Track track;
  final VoidCallback? onTap;

  /// Extra widget after the source chip / duration (e.g. a menu button).
  final Widget? trailing;

  /// Highlights the row as the currently playing track.
  final bool isCurrent;
  final bool showSourceChip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      onTap: onTap,
      selected: isCurrent,
      selectedTileColor: scheme.primary.withValues(alpha: 0.10),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: ArtworkImage(url: track.artUrl, size: 52),
      title: Row(
        children: [
          Flexible(
            child: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                color: isCurrent ? scheme.primary : null,
              ),
            ),
          ),
          if (track.explicit) ...[
            const SizedBox(width: 6),
            const ExplicitBadge(),
          ],
        ],
      ),
      subtitle: Text(
        track.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSourceChip) SourceChip(source: track.source),
          if (track.durationMs > 0) ...[
            const SizedBox(width: 8),
            Text(
              formatClock(track.durationMs),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Vertical card for horizontal shelves (Home / Explore): square artwork
/// over title + artist.
class TrackCard extends StatelessWidget {
  const TrackCard({
    super.key,
    required this.track,
    this.onTap,
    this.width = 148,
  });

  final Track track;
  final VoidCallback? onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ArtworkImage(url: track.artUrl, size: width - 8, radius: 14),
              const SizedBox(height: 8),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (track.explicit) ...[
                    const SizedBox(width: 4),
                    const ExplicitBadge(),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vertical card for a [Collection] (album / playlist / artist) on shelves.
class CollectionCard extends StatelessWidget {
  const CollectionCard({
    super.key,
    required this.collection,
    this.onTap,
    this.width = 148,
  });

  final Collection collection;
  final VoidCallback? onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ArtworkImage(url: collection.artUrl, size: width - 8, radius: 14),
              const SizedBox(height: 8),
              Text(
                collection.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                collection.subtitle ?? collection.kind.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shelf / section title row with an optional "See all" action
/// (Kotlin: Home.kt Header).
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onSeeAll,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onSeeAll;

  /// Replaces the "See all" button when provided (e.g. an add button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null)
            trailing!
          else if (onSeeAll != null)
            TextButton(onPressed: onSeeAll, child: const Text('See all')),
        ],
      ),
    );
  }
}
