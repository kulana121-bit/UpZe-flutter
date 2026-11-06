// Search screen (Kotlin: ui/screens/Search.kt).
//
// The actual searching lives behind the injected [SearchScreen.onSearch]
// callback (wired to the SourceManager in main); this widget only owns the
// text field, debounce, result list and empty/error states.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/settings_store.dart';
import '../../models/track.dart';
import '../theme.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.onSearch,
    required this.onPlay,
    this.recentSearches = const [],
    this.glassStyle = GlassStyle.liquid,
  });

  /// Runs a search and returns the merged results.
  final Future<List<Track>> Function(String query) onSearch;

  /// Play [Track] with the current result list as the queue context.
  final void Function(Track track, List<Track> queue) onPlay;

  /// Shown as tappable chips while the field is empty
  /// (AppSettings.recentSearches).
  final List<String> recentSearches;
  final GlassStyle glassStyle;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Track> _results = const [];
  bool _loading = false;
  bool _failed = false;
  String _searchedQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _searchedQuery = '';
        _failed = false;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final found = await widget.onSearch(q);
      if (!mounted) return;
      setState(() {
        _results = found;
        _searchedQuery = q;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _searchedQuery = q;
        _failed = true;
        _loading = false;
      });
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _runSearch(value),
    );
    setState(() {}); // refresh the clear button
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: GlassContainer(
            glassStyle: widget.glassStyle,
            strong: true,
            borderRadius: const BorderRadius.all(Radius.circular(16)),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: _runSearch,
              decoration: InputDecoration(
                hintText: 'Search songs, artists, albums…',
                border: InputBorder.none,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : (_controller.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _controller.clear();
                              _onChanged('');
                            },
                          )),
              ),
            ),
          ),
        ),
        Expanded(child: _body(theme, scheme)),
      ],
    );
  }

  Widget _body(ThemeData theme, ColorScheme scheme) {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return const _Message(
        icon: Icons.wifi_off,
        text: 'Search failed — check your connection and try again.',
      );
    }
    if (_searchedQuery.isEmpty) {
      // Idle state: recent searches + a hint. No baked-in suggestions.
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          if (widget.recentSearches.isNotEmpty) ...[
            Text(
              'Recent searches',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final q in widget.recentSearches)
                  ActionChip(
                    avatar: const Icon(Icons.history, size: 16),
                    label: Text(q),
                    onPressed: () {
                      _controller.text = q;
                      _runSearch(q);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],
          Icon(Icons.search, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            'Search across all your sources',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    if (_results.isEmpty) {
      return _Message(
        icon: Icons.search_off,
        text: 'No results for "$_searchedQuery".',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _results.length,
      itemBuilder: (_, i) => TrackTile(
        track: _results[i],
        onTap: () => widget.onPlay(_results[i], _results),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
