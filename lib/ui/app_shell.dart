// App shell (Kotlin: ui/AppRoot.kt + ui/chrome/Chrome.kt DockChrome).
//
// Spatial layout: a soft gradient backdrop with two blurred accent glows
// (so the glass has something to refract), the tab body, the mini player,
// and a floating glass dock with the five tabs — Home, Explore, Library,
// Search, Settings. Dock behaviour follows AppSettings.navMode: Mini =
// dock always visible, Always = always visible, Hide = the dock slides
// away while scrolling down and returns on scroll up.
//
// EVERYTHING is constructor-injected (see the field docs): repos, data,
// streams and callbacks. main.dart creates the repos + playback layer and
// hands them here; this file imports nothing from lib/playback.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/library.dart';
import '../data/settings_store.dart';
import '../models/track.dart';
import 'player/full_player.dart';
import 'player/mini_player.dart';
import 'screens/explore_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    // Repos
    required this.settings,
    required this.library,
    // Playback state (owned by lib/playback, created in main)
    required this.currentTrackStream,
    required this.streamInfoStream,
    required this.positionStream,
    required this.durationStream,
    required this.playingStream,
    required this.queueStream,
    required this.currentIndexStream,
    // Playback actions
    required this.onTogglePlay,
    required this.onNext,
    required this.onPrev,
    required this.onSeek,
    required this.onJumpTo,
    required this.onToggleLike,
    // Data actions
    required this.onSearch,
    required this.onPlay,
    // Optional feeds / actions
    this.homeShelves = const [],
    this.onRefreshHome,
    this.onLoadCharts,
    this.onLoadSourceSuggestions,
    this.onOpenCollection,
    this.onShowLyrics,
    this.onSleepTimer,
    this.isLiked,
    this.userName,
    this.onOpenAccounts,
    this.onOpenEq,
    this.onOpenDownloads,
    this.onDownloadTrack,
  });

  final SettingsStore settings;
  final LibraryRepo library;

  /// Player state streams (just_audio-backed in the playback layer).
  final Stream<Track?> currentTrackStream;
  final Stream<StreamInfo?> streamInfoStream;
  final Stream<Duration> positionStream;
  final Stream<Duration?> durationStream;
  final Stream<bool> playingStream;
  final Stream<List<Track>> queueStream;
  final Stream<int?> currentIndexStream;

  final VoidCallback onTogglePlay;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<int> onJumpTo;

  /// Toggle like for a track (usually LibraryRepo.setLiked + state).
  final ValueChanged<Track> onToggleLike;

  /// Search across sources (SourceManager-backed).
  final Future<List<Track>> Function(String query) onSearch;

  /// Start playing [Track] with [queue] as its queue context; also used by
  /// every screen's track tap.
  final void Function(Track track, List<Track> queue) onPlay;

  /// Home shelves snapshot. The shell is stateless about feeds: when main
  /// has fresh shelves it rebuilds AppShell with the new list (e.g. from a
  /// StreamBuilder/FutureBuilder in main).
  final List<Shelf> homeShelves;
  final Future<void> Function()? onRefreshHome;

  /// Explore feeds (see ExploreScreen).
  final Future<List<Shelf>> Function()? onLoadCharts;
  final Future<List<Track>> Function(SourceKind source)?
      onLoadSourceSuggestions;

  final void Function(Collection collection)? onOpenCollection;

  /// Lyrics action for the full player; null hides its lyrics button.
  final void Function(Track track)? onShowLyrics;

  /// Sleep timer chosen in Settings (minutes; 0 = off).
  final void Function(int minutes)? onSleepTimer;

  /// Liked-state lookup for the full player; defaults to LibraryRepo.
  final bool Function(Track track)? isLiked;

  final String? userName;

  /// Settings sub-page openers, forwarded to [SettingsScreen]: accounts
  /// (source sign-ins), the EQ page, and the downloads page. Null hides
  /// the corresponding settings row.
  final VoidCallback? onOpenAccounts;
  final VoidCallback? onOpenEq;
  final VoidCallback? onOpenDownloads;

  /// Download the given track (full player's download button).
  final ValueChanged<Track>? onDownloadTrack;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  bool _dockHidden = false;

  static const _tabs = <(IconData, String)>[
    (Icons.home, 'Home'),
    (Icons.explore, 'Explore'),
    (Icons.library_music, 'Library'),
    (Icons.search, 'Search'),
    (Icons.settings, 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onChange);
    widget.library.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onChange);
    widget.library.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  bool _liked(Track t) =>
      widget.isLiked?.call(t) ?? widget.library.isLiked(t.id);

  bool _onScroll(UserScrollNotification n) {
    if (widget.settings.value.navMode != NavBarMode.hide) return false;
    if (n.direction == ScrollDirection.reverse && !_dockHidden) {
      setState(() => _dockHidden = true);
    } else if (n.direction == ScrollDirection.forward && _dockHidden) {
      setState(() => _dockHidden = false);
    }
    return false;
  }

  void _openFullPlayer() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => FractionallySizedBox(
        heightFactor: 0.96,
        child: GlassContainer(
          glassStyle: widget.settings.value.glass,
          strong: true,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
          child: StreamBuilder<Track?>(
            stream: widget.currentTrackStream,
            builder: (context, trackSnap) => StreamBuilder<List<Track>>(
              stream: widget.queueStream,
              initialData: const [],
              builder: (context, queueSnap) => StreamBuilder<int?>(
                stream: widget.currentIndexStream,
                builder: (context, indexSnap) => StreamBuilder<StreamInfo?>(
                  stream: widget.streamInfoStream,
                  builder: (context, infoSnap) {
                    final track = trackSnap.data;
                    return FullPlayer(
                      track: track,
                      streamInfo: infoSnap.data,
                      positionStream: widget.positionStream,
                      durationStream: widget.durationStream,
                      playingStream: widget.playingStream,
                      onSeek: widget.onSeek,
                      onNext: widget.onNext,
                      onPrev: widget.onPrev,
                      onTogglePlay: widget.onTogglePlay,
                      onToggleLike: track == null
                          ? () {}
                          : () => widget.onToggleLike(track),
                      isLiked: track != null && _liked(track),
                      queue: queueSnap.data ?? const [],
                      currentIndex: indexSnap.data ?? -1,
                      onJumpTo: widget.onJumpTo,
                      onShowLyrics: (widget.onShowLyrics == null ||
                              track == null)
                          ? null
                          : () => widget.onShowLyrics!(track),
                      onDownload: (widget.onDownloadTrack == null ||
                              track == null)
                          ? null
                          : () => widget.onDownloadTrack!(track),
                      onClose: () => Navigator.of(sheetCtx).pop(),
                      glassStyle: widget.settings.value.glass,
                      style: widget.settings.value.playerStyle,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings.value;
    final scheme = Theme.of(context).colorScheme;
    final screens = <Widget>[
      HomeScreen(
        shelves: widget.homeShelves,
        recentlyPlayed: widget.library.recentlyPlayed,
        onPlay: widget.onPlay,
        onOpenCollection: widget.onOpenCollection,
        glassStyle: settings.glass,
        onRefresh: widget.onRefreshHome,
        userName: widget.userName,
        style: settings.homeStyle,
      ),
      ExploreScreen(
        onPlay: widget.onPlay,
        onLoadCharts: widget.onLoadCharts,
        onLoadSourceSuggestions: widget.onLoadSourceSuggestions,
        onOpenCollection: widget.onOpenCollection,
        glassStyle: settings.glass,
      ),
      LibraryScreen(
        library: widget.library,
        onPlay: widget.onPlay,
        onOpenCollection: widget.onOpenCollection,
        glassStyle: settings.glass,
      ),
      SearchScreen(
        onSearch: widget.onSearch,
        onPlay: widget.onPlay,
        recentSearches: settings.recentSearches,
        glassStyle: settings.glass,
      ),
      SettingsScreen(
        settings: widget.settings,
        onSleepTimer: widget.onSleepTimer,
        onOpenAccounts: widget.onOpenAccounts,
        onOpenEq: widget.onOpenEq,
        onOpenDownloads: widget.onOpenDownloads,
      ),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.10), scheme.surface),
            scheme.surface,
          ],
        ),
      ),
      child: Stack(
        children: [
          // Blurred accent glows behind everything — the spatial backdrop
          // the glass surfaces refract.
          Positioned(
            top: -90,
            right: -70,
            child: _Glow(color: scheme.primary.withValues(alpha: 0.20)),
          ),
          Positioned(
            bottom: 40,
            left: -100,
            child: _Glow(color: scheme.tertiary.withValues(alpha: 0.14)),
          ),
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Expanded(
                    child: NotificationListener<UserScrollNotification>(
                      onNotification: _onScroll,
                      child: IndexedStack(index: _tab, children: screens),
                    ),
                  ),
                  StreamBuilder<Track?>(
                    stream: widget.currentTrackStream,
                    builder: (context, trackSnap) => StreamBuilder<StreamInfo?>(
                      stream: widget.streamInfoStream,
                      builder: (context, infoSnap) => MiniPlayer(
                        track: trackSnap.data,
                        streamInfo: infoSnap.data,
                        playingStream: widget.playingStream,
                        positionStream: widget.positionStream,
                        durationStream: widget.durationStream,
                        onTogglePlay: widget.onTogglePlay,
                        onNext: widget.onNext,
                        onTap: _openFullPlayer,
                        glassStyle: settings.glass,
                      ),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _dockHidden
                        ? const SizedBox.shrink()
                        : _buildDock(settings),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The bottom dock, rendered per [AppSettings.dockStyle]:
  /// classic = the wide floating glass bar, island = a narrower centred
  /// pill, capsule ("Orb") = a circular artwork button beside a compact
  /// pill, edge ("Split") = two separate glass islands (nav on the left,
  /// actions on the right). Hide-on-scroll applies to all of them — the
  /// caller swaps the whole dock for a shrink box.
  Widget _buildDock(AppSettings settings) {
    final key = ValueKey('dock-${settings.dockStyle.name}');
    void select(int i) => setState(() => _tab = i);
    return switch (settings.dockStyle) {
      DockStyle.classic => _Dock(
          key: key,
          tabs: _tabs,
          selected: _tab,
          glassStyle: settings.glass,
          onSelect: select,
        ),
      DockStyle.island => _IslandDock(
          key: key,
          tabs: _tabs,
          selected: _tab,
          glassStyle: settings.glass,
          onSelect: select,
        ),
      DockStyle.capsule => _CapsuleDock(
          key: key,
          tabs: _tabs,
          selected: _tab,
          glassStyle: settings.glass,
          onSelect: select,
          currentTrackStream: widget.currentTrackStream,
          playingStream: widget.playingStream,
          onTogglePlay: widget.onTogglePlay,
          onOpenPlayer: _openFullPlayer,
        ),
      DockStyle.edge => _EdgeDock(
          key: key,
          tabs: _tabs,
          selected: _tab,
          glassStyle: settings.glass,
          onSelect: select,
          playingStream: widget.playingStream,
          onTogglePlay: widget.onTogglePlay,
        ),
    };
  }
}

/// One blurred colour blob (pure decoration, no hit testing).
class _Glow extends StatelessWidget {
  const _Glow({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
        child: Container(
          width: 240,
          height: 240,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
      ),
    );
  }
}

/// Floating glass bottom dock with the five tabs.
class _Dock extends StatelessWidget {
  const _Dock({
    super.key,
    required this.tabs,
    required this.selected,
    required this.glassStyle,
    required this.onSelect,
  });

  final List<(IconData, String)> tabs;
  final int selected;
  final GlassStyle glassStyle;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: GlassContainer(
        glassStyle: glassStyle,
        strong: true,
        margin: const EdgeInsets.fromLTRB(12, 2, 12, 10),
        borderRadius: const BorderRadius.all(Radius.circular(24)),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => onSelect(i),
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          tabs[i].$1,
                          color: i == selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tabs[i].$2,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: i == selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: i == selected
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One tab inside a pill dock (island / capsule / edge): icon, with the
/// label shown beside it when [showLabel] (the island's active tab) —
/// selected tabs get a soft primary wash.
class _PillTab extends StatelessWidget {
  const _PillTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.showLabel = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 12 : 10, vertical: 8),
        decoration: selected
            ? BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(99),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            if (showLabel) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Island dock: a narrower, centred glass pill; only the active tab
/// carries its label (Kotlin: IslandDock's expanding active tab).
class _IslandDock extends StatelessWidget {
  const _IslandDock({
    super.key,
    required this.tabs,
    required this.selected,
    required this.glassStyle,
    required this.onSelect,
  });

  final List<(IconData, String)> tabs;
  final int selected;
  final GlassStyle glassStyle;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: GlassContainer(
              glassStyle: glassStyle,
              strong: true,
              borderRadius: const BorderRadius.all(Radius.circular(99)),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    _PillTab(
                      icon: tabs[i].$1,
                      label: tabs[i].$2,
                      selected: i == selected,
                      showLabel: i == selected,
                      onTap: () => onSelect(i),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Capsule ("Orb") dock: a circular artwork button — tap opens the full
/// player — beside a compact icon pill that also carries play/pause
/// (Kotlin: CapsuleDock's floating cover).
class _CapsuleDock extends StatelessWidget {
  const _CapsuleDock({
    super.key,
    required this.tabs,
    required this.selected,
    required this.glassStyle,
    required this.onSelect,
    required this.currentTrackStream,
    required this.playingStream,
    required this.onTogglePlay,
    required this.onOpenPlayer,
  });

  final List<(IconData, String)> tabs;
  final int selected;
  final GlassStyle glassStyle;
  final ValueChanged<int> onSelect;
  final Stream<Track?> currentTrackStream;
  final Stream<bool> playingStream;
  final VoidCallback onTogglePlay;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            StreamBuilder<Track?>(
              stream: currentTrackStream,
              builder: (context, snap) {
                final t = snap.data;
                return GestureDetector(
                  onTap: t == null ? null : onOpenPlayer,
                  child: Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.surfaceContainerHighest,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: t == null
                        ? Icon(
                            Icons.music_note,
                            color: scheme.onSurfaceVariant,
                          )
                        : ArtworkImage(url: t.artUrl, size: 54, radius: 27),
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            GlassContainer(
              glassStyle: glassStyle,
              strong: true,
              borderRadius: const BorderRadius.all(Radius.circular(99)),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    _PillTab(
                      icon: tabs[i].$1,
                      label: tabs[i].$2,
                      selected: i == selected,
                      onTap: () => onSelect(i),
                    ),
                  const SizedBox(width: 2),
                  StreamBuilder<bool>(
                    stream: playingStream,
                    initialData: false,
                    builder: (context, snap) => IconButton(
                      icon: Icon(
                        (snap.data ?? false)
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: scheme.primary,
                      ),
                      tooltip: (snap.data ?? false) ? 'Pause' : 'Play',
                      onPressed: onTogglePlay,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edge ("Split") dock: two separate glass islands — the nav tabs
/// (Home / Explore / Library) float on the left, the actions
/// (Search / Settings + play/pause) on the right (Kotlin: EdgeDock).
class _EdgeDock extends StatelessWidget {
  const _EdgeDock({
    super.key,
    required this.tabs,
    required this.selected,
    required this.glassStyle,
    required this.onSelect,
    required this.playingStream,
    required this.onTogglePlay,
  });

  final List<(IconData, String)> tabs;
  final int selected;
  final GlassStyle glassStyle;
  final ValueChanged<int> onSelect;
  final Stream<bool> playingStream;
  final VoidCallback onTogglePlay;

  Widget _island(BuildContext context, List<Widget> children) {
    return GlassContainer(
      glassStyle: glassStyle,
      strong: true,
      borderRadius: const BorderRadius.all(Radius.circular(99)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
        child: Row(
          children: [
            _island(context, [
              for (var i = 0; i < 3; i++)
                _PillTab(
                  icon: tabs[i].$1,
                  label: tabs[i].$2,
                  selected: i == selected,
                  showLabel: i == selected,
                  onTap: () => onSelect(i),
                ),
            ]),
            const Spacer(),
            _island(context, [
              for (var i = 3; i < tabs.length; i++)
                _PillTab(
                  icon: tabs[i].$1,
                  label: tabs[i].$2,
                  selected: i == selected,
                  showLabel: i == selected,
                  onTap: () => onSelect(i),
                ),
              StreamBuilder<bool>(
                stream: playingStream,
                initialData: false,
                builder: (context, snap) => IconButton(
                  icon: Icon(
                    (snap.data ?? false) ? Icons.pause : Icons.play_arrow,
                    color: scheme.primary,
                  ),
                  tooltip: (snap.data ?? false) ? 'Pause' : 'Play',
                  onPressed: onTogglePlay,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
