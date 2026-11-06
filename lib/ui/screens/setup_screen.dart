// First-run setup (Kotlin: ui/setup/SetupFlow.kt + ArtistPicker.kt).
//
// Welcome + the artist picker. The data layer's only baked-in catalogue
// is SeedArtists.popularQueries — 12 popular artist NAMES with no
// catalogue ids (artists are normally discovered live through YT Music
// search, see lib/data/seed_artists.dart). This screen therefore shows
// those names; the picked names are saved through
// AccountsStore.setSeedArtistIds and setup is marked done
// (AccountsStore.setSetupDone). A name the host later resolves through
// artist search can be replaced by its "yt:UC…" id without changing
// this screen.
//
// Pick at least 3 to continue; Skip finishes setup with no picks (the
// picker is optional in the original too).

import 'package:flutter/material.dart' hide ThemeMode;

import '../../data/accounts_store.dart';
import '../../data/seed_artists.dart';
import '../../data/settings_store.dart';
import '../theme.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.accounts,
    required this.onDone,
  });

  final AccountsStore accounts;

  /// Setup finished (continue or skip) — the host swaps this screen out.
  final VoidCallback onDone;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  /// Picked seed ids (here: the popular-query names, see header).
  late final Set<String> _selected;

  static const int _minPicks = 3;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.accounts.seedArtistIds};
  }

  void _toggle(String name) {
    setState(() {
      if (!_selected.add(name)) _selected.remove(name);
    });
  }

  void _continue() {
    widget.accounts.setSeedArtistIds(_selected.toList());
    widget.accounts.setSetupDone(true);
    widget.onDone();
  }

  void _skip() {
    widget.accounts.setSetupDone(true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enough = _selected.length >= _minPicks;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome to UpZe',
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pick at least $_minPicks artists you like. Home '
                    'tunes its shelves around them — you can change '
                    'this later.',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.82,
                ),
                itemCount: seedPopularQueries.length,
                itemBuilder: (_, i) {
                  final name = seedPopularQueries[i];
                  final picked = _selected.contains(name);
                  return _ArtistCard(
                    artist: SeedArtist(id: name, name: name),
                    picked: picked,
                    onTap: () => _toggle(name),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _skip,
                    child: const Text('Skip'),
                  ),
                  const Spacer(),
                  Text(
                    '${_selected.length} picked',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: enough ? _continue : null,
                    child: const Text('Continue'),
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

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({
    required this.artist,
    required this.picked,
    required this.onTap,
  });

  final SeedArtist artist;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: GlassContainer(
        glassStyle: GlassStyle.frosted,
        strong: picked,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              children: [
                ArtworkImage(
                  url: artist.thumbnailUrl,
                  size: 56,
                  radius: 28,
                ),
                if (picked)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(
                      radius: 10,
                      backgroundColor: scheme.primary,
                      child: Icon(Icons.check,
                          size: 13, color: scheme.onPrimary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              artist.name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: picked ? FontWeight.w800 : FontWeight.w500,
                color: picked ? scheme.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
