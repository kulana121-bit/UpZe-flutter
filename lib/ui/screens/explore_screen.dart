// Explore screen (Kotlin: ui/screens/Explore.kt).
//
// Source chips on top; below them, the selected source's suggestions and a
// Charts section — both fed entirely by the injected callbacks. Nothing is
// baked in: when a feed isn't wired (callback null) or comes back empty,
// the screen says so instead of showing demo content.

import 'package:flutter/material.dart';

import '../../data/settings_store.dart';
import '../../models/track.dart';
import '../theme.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({
    super.key,
    required this.onPlay,
    this.onLoadCharts,
    this.onLoadSourceSuggestions,
    this.onOpenCollection,
    this.glassStyle = GlassStyle.liquid,
  });

  /// Play [Track] with [queue] as its queue context.
  final void Function(Track track, List<Track> queue) onPlay;

  /// Charts shelves feed; null = charts not connected yet.
  final Future<List<Shelf>> Function()? onLoadCharts;

  /// Suggestions for one source (chip selection); null = not connected.
  final Future<List<Track>> Function(SourceKind source)?
      onLoadSourceSuggestions;

  final void Function(Collection collection)? onOpenCollection;
  final GlassStyle glassStyle;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  SourceKind? _selected;
  Future<List<Track>>? _suggestions;
  Future<List<Shelf>>? _charts;

  @override
  void initState() {
    super.initState();
    _charts = widget.onLoadCharts?.call();
  }

  void _select(SourceKind kind) {
    setState(() {
      _selected = kind;
      _suggestions = widget.onLoadSourceSuggestions?.call(kind);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Explore',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        const SectionHeader(title: 'Sources', subtitle: 'Pick one for suggestions'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in SourceKind.values)
                ChoiceChip(
                  label: Text(kind.label),
                  selected: _selected == kind,
                  onSelected: (_) => _select(kind),
                ),
            ],
          ),
        ),
        if (_selected != null) ...[
          SectionHeader(title: 'From ${_selected!.label}'),
          _suggestionsBody(theme),
        ],
        const SectionHeader(title: 'Charts'),
        _chartsBody(theme),
      ],
    );
  }

  Widget _suggestionsBody(ThemeData theme) {
    final loader = widget.onLoadSourceSuggestions;
    if (loader == null) {
      return _EmptyLine(
        'Suggestions from ${_selected!.label} are not connected yet.',
      );
    }
    return FutureBuilder<List<Track>>(
      future: _suggestions,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return _EmptyLine(
            'Could not load suggestions from ${_selected!.label}.',
          );
        }
        final tracks = snap.data ?? const <Track>[];
        if (tracks.isEmpty) {
          return _EmptyLine('No suggestions from ${_selected!.label} yet.');
        }
        return Column(
          children: [
            for (final t in tracks)
              TrackTile(track: t, onTap: () => widget.onPlay(t, tracks)),
          ],
        );
      },
    );
  }

  Widget _chartsBody(ThemeData theme) {
    if (widget.onLoadCharts == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: _EmptyLine(
          'Charts will appear here once a charts feed is connected.',
        ),
      );
    }
    return FutureBuilder<List<Shelf>>(
      future: _charts,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return const _EmptyLine('Could not load charts right now.');
        }
        final shelves = snap.data ?? const <Shelf>[];
        if (shelves.isEmpty) {
          return const _EmptyLine('No charts available right now.');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final shelf in shelves) ...[
              SectionHeader(title: shelf.title, subtitle: shelf.subtitle),
              if (shelf.tracks.isNotEmpty)
                SizedBox(
                  height: 204,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: shelf.tracks.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 4),
                    itemBuilder: (_, i) => TrackCard(
                      track: shelf.tracks[i],
                      onTap: () => widget.onPlay(shelf.tracks[i], shelf.tracks),
                    ),
                  ),
                ),
              if (shelf.collections.isNotEmpty)
                SizedBox(
                  height: 204,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: shelf.collections.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 4),
                    itemBuilder: (_, i) => CollectionCard(
                      collection: shelf.collections[i],
                      onTap: widget.onOpenCollection == null
                          ? null
                          : () => widget.onOpenCollection!(shelf.collections[i]),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
