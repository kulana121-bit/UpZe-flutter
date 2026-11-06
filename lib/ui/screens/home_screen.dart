// Home screen (Kotlin: ui/screens/Home.kt — ClassicHomeScreen).
//
// Four looks, one data contract (Settings → HomeStyle):
//  - classic: greeting, a Recently played row, then one horizontal shelf
//    per Shelf (Kotlin ClassicHomeScreen).
//  - aura: classic, but the shelves use larger glass cards and a big
//    glass hero card (first track of the first shelf) leads the page
//    (Kotlin HomeAura).
//  - bento: a 2-column grid of mixed tiles — a wide "Continue listening"
//    tile, Liked / Recently played blocks, then track tiles — with the
//    classic shelves below (Kotlin HomeBento).
//  - spotlight: the first shelf becomes a full-width hero pager of its
//    top tracks above the classic shelves (Kotlin HomeSpotlight).
//
// All data arrives through the constructor — this widget owns no fetching
// and no singletons; every variant plays through the same [onPlay].

import 'package:flutter/material.dart';

import '../../data/settings_store.dart';
import '../../models/track.dart';
import '../theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.shelves,
    required this.recentlyPlayed,
    required this.onPlay,
    this.onOpenCollection,
    this.glassStyle = GlassStyle.liquid,
    this.onRefresh,
    this.userName,
    this.style = HomeStyle.classic,
  });

  /// Shelves to render, in order (from the home feed layer).
  final List<Shelf> shelves;

  /// Most recently played tracks, newest first (LibraryRepo.recentlyPlayed).
  final List<Track> recentlyPlayed;

  /// Play [Track] with its shelf/row list as the queue context.
  final void Function(Track track, List<Track> queue) onPlay;

  final void Function(Collection collection)? onOpenCollection;
  final GlassStyle glassStyle;

  /// Pull-to-refresh hook; when null no refresh indicator is shown.
  final Future<void> Function()? onRefresh;

  /// Optional name for the greeting ("Good evening, Ravi").
  final String? userName;

  /// Which of the four home designs to render.
  final HomeStyle style;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  /// Tracks for hero spots: the first non-empty shelf's tracks, falling
  /// back to recently played. Returns (tracks, queue context), which is
  /// the same list — heroes play inside their own row.
  List<Track> get _heroTracks {
    for (final s in shelves) {
      if (s.tracks.isNotEmpty) return s.tracks;
    }
    return recentlyPlayed;
  }

  @override
  Widget build(BuildContext context) {
    final children = switch (style) {
      HomeStyle.classic => _classicChildren(context),
      HomeStyle.aura => _auraChildren(context),
      HomeStyle.bento => _bentoChildren(context),
      HomeStyle.spotlight => _spotlightChildren(context),
    };
    final list = ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: children,
    );
    final refresh = onRefresh;
    if (refresh == null) return list;
    return RefreshIndicator(onRefresh: refresh, child: list);
  }

  // ---------------------------------------------------------------- styles

  List<Widget> _classicChildren(BuildContext context) {
    return [
      _greetingBlock(context),
      ..._shelfChildren(context),
    ];
  }

  List<Widget> _auraChildren(BuildContext context) {
    final hero = _heroTracks;
    return [
      _greetingBlock(context),
      if (hero.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: _HeroCard(
            track: hero.first,
            glassStyle: glassStyle,
            onTap: () => onPlay(hero.first, hero),
          ),
        ),
      ..._shelfChildren(context, cardWidth: 176, rowHeight: 236),
    ];
  }

  List<Widget> _bentoChildren(BuildContext context) {
    final theme = Theme.of(context);
    final likedShelf = _shelfTitled('Liked');
    final liked = likedShelf?.tracks ?? const <Track>[];
    // Track tiles for the grid: first shelf's tracks, else recent.
    final gridTracks = _heroTracks;
    return [
      _greetingBlock(context),
      if (recentlyPlayed.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: _BentoWideTile(
            track: recentlyPlayed.first,
            label: 'Continue listening',
            glassStyle: glassStyle,
            onTap: () =>
                onPlay(recentlyPlayed.first, recentlyPlayed),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.35,
          ),
          itemCount: 2 + (gridTracks.length > 6 ? 6 : gridTracks.length),
          itemBuilder: (context, i) {
            if (i == 0) {
              return _BentoStatTile(
                icon: Icons.favorite,
                title: 'Liked songs',
                subtitle: liked.isEmpty
                    ? 'Nothing liked yet'
                    : '${liked.length} songs',
                glassStyle: glassStyle,
                onTap: liked.isEmpty
                    ? null
                    : () => onPlay(liked.first, liked),
              );
            }
            if (i == 1) {
              return _BentoStatTile(
                icon: Icons.history,
                title: 'Recently played',
                subtitle: recentlyPlayed.isEmpty
                    ? 'Nothing played yet'
                    : '${recentlyPlayed.length} tracks',
                glassStyle: glassStyle,
                onTap: recentlyPlayed.isEmpty
                    ? null
                    : () => onPlay(recentlyPlayed.first, recentlyPlayed),
              );
            }
            final t = gridTracks[i - 2];
            return _BentoTrackTile(
              track: t,
              glassStyle: glassStyle,
              onTap: () => onPlay(t, gridTracks),
            );
          },
        ),
      ),
      if (shelves.isEmpty && recentlyPlayed.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Text(
            'Your home feed is empty — search for a song and play it.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ..._shelfChildren(context),
    ];
  }

  List<Widget> _spotlightChildren(BuildContext context) {
    final hero = _heroTracks;
    if (hero.isEmpty) return _classicChildren(context);
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _SpotlightHero(
          tracks: hero.take(5).toList(),
          onPlay: onPlay,
        ),
      ),
      ..._shelfChildren(context),
    ];
  }

  // ---------------------------------------------------------------- pieces

  Widget _greetingBlock(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            userName == null ? _greeting : '$_greeting, $userName',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            'What do you want to hear today?',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Recently played + every shelf (+ the empty state), shared by all
  /// styles; [cardWidth]/[rowHeight] grow the cards for the Aura look.
  List<Widget> _shelfChildren(
    BuildContext context, {
    double cardWidth = 148,
    double rowHeight = 204,
  }) {
    final theme = Theme.of(context);
    return [
      if (recentlyPlayed.isNotEmpty) ...[
        const SectionHeader(title: 'Recently played'),
        _TrackRow(
          tracks: recentlyPlayed,
          onTap: (t) => onPlay(t, recentlyPlayed),
          cardWidth: cardWidth,
          height: rowHeight,
        ),
      ],
      for (final shelf in shelves) ...[
        SectionHeader(title: shelf.title, subtitle: shelf.subtitle),
        if (shelf.tracks.isNotEmpty)
          _TrackRow(
            tracks: shelf.tracks,
            onTap: (t) => onPlay(t, shelf.tracks),
            cardWidth: cardWidth,
            height: rowHeight,
          ),
        if (shelf.collections.isNotEmpty)
          _CollectionRow(
            collections: shelf.collections,
            onTap: onOpenCollection,
            height: rowHeight,
          ),
        if (shelf.tracks.isEmpty && shelf.collections.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Nothing here yet.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
      if (shelves.isEmpty && recentlyPlayed.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
          child: GlassContainer(
            glassStyle: glassStyle,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Icon(
                  Icons.library_music_outlined,
                  size: 40,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  'Your home feed is empty',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Search for a song and play it — your shelves and '
                  'recently played will fill in here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 24),
    ];
  }

  Shelf? _shelfTitled(String needle) {
    for (final s in shelves) {
      if (s.title.toLowerCase().contains(needle.toLowerCase())) return s;
    }
    return null;
  }
}

/// Aura's lead card: big artwork + "Featured" label + play affordance,
/// all inside one glass panel.
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.track,
    required this.glassStyle,
    required this.onTap,
  });

  final Track track;
  final GlassStyle glassStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassContainer(
      glassStyle: glassStyle,
      strong: true,
      borderRadius: const BorderRadius.all(Radius.circular(26)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              ArtworkImage(url: track.artUrl, size: 104, radius: 18),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FEATURED',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(12),
                ),
                onPressed: onTap,
                child: const Icon(Icons.play_arrow, size: 26),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bento's wide "Continue listening" tile.
class _BentoWideTile extends StatelessWidget {
  const _BentoWideTile({
    required this.track,
    required this.label,
    required this.glassStyle,
    required this.onTap,
  });

  final Track track;
  final String label;
  final GlassStyle glassStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassContainer(
      glassStyle: glassStyle,
      strong: true,
      borderRadius: const BorderRadius.all(Radius.circular(22)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ArtworkImage(url: track.artUrl, size: 72, radius: 14),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.play_circle_fill, size: 34),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bento stat block (Liked / Recently played).
class _BentoStatTile extends StatelessWidget {
  const _BentoStatTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.glassStyle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final GlassStyle glassStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassContainer(
      glassStyle: glassStyle,
      borderRadius: const BorderRadius.all(Radius.circular(22)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: scheme.primary, size: 26),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bento square-ish track tile (art left, text right, compact).
class _BentoTrackTile extends StatelessWidget {
  const _BentoTrackTile({
    required this.track,
    required this.glassStyle,
    required this.onTap,
  });

  final Track track;
  final GlassStyle glassStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassContainer(
      glassStyle: glassStyle,
      borderRadius: const BorderRadius.all(Radius.circular(22)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ArtworkImage(url: track.artUrl, size: 56, radius: 12),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            track.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
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
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Spotlight's hero: a swipeable pager of big-artwork pages with a
/// gradient scrim, title/artist and a play button, plus page dots.
class _SpotlightHero extends StatefulWidget {
  const _SpotlightHero({required this.tracks, required this.onPlay});

  final List<Track> tracks;
  final void Function(Track track, List<Track> queue) onPlay;

  @override
  State<_SpotlightHero> createState() => _SpotlightHeroState();
}

class _SpotlightHeroState extends State<_SpotlightHero> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = MediaQuery.of(context).size.width;
    final artSize = width - 24;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: artSize + 8,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.tracks.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) {
              final t = widget.tracks[i];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: ArtworkImage(
                          url: t.artUrl,
                          size: artSize,
                          radius: 24,
                        ),
                      ),
                      // Whole page is tappable to play (under the info
                      // row, so the play button keeps its own taps;
                      // PageView drags still win the gesture arena).
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () => widget.onPlay(t, widget.tracks),
                          behavior: HitTestBehavior.opaque,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.45, 1.0],
                            colors: [
                              Colors.transparent,
                              scheme.surface.withValues(alpha: 0.88),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 14,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'SPOTLIGHT',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    t.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge
                                        ?.copyWith(
                                            fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    t.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: scheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                shape: const CircleBorder(),
                                padding: const EdgeInsets.all(14),
                              ),
                              onPressed: () => widget.onPlay(t, widget.tracks),
                              child: const Icon(Icons.play_arrow, size: 28),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (widget.tracks.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.tracks.length; i++)
                  Container(
                    width: i == _page ? 18 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: i == _page
                          ? scheme.primary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One horizontal row of track cards (fixed height: card art + 2 lines).
class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.tracks,
    required this.onTap,
    this.cardWidth = 148,
    this.height = 204,
  });

  final List<Track> tracks;
  final void Function(Track track) onTap;
  final double cardWidth;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: tracks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (_, i) => TrackCard(
          track: tracks[i],
          width: cardWidth,
          onTap: () => onTap(tracks[i]),
        ),
      ),
    );
  }
}

class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    required this.collections,
    required this.onTap,
    this.height = 204,
  });

  final List<Collection> collections;
  final void Function(Collection collection)? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: collections.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (_, i) => CollectionCard(
          collection: collections[i],
          onTap: onTap == null ? null : () => onTap!(collections[i]),
        ),
      ),
    );
  }
}
