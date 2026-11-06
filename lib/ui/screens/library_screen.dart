// Library screen (Kotlin: ui/screens/Library.kt).
//
// Shortcut tiles (Liked / Playlists / Saved / History) over the playlist
// list, saved collections and recent history — all read straight from the
// injected [LibraryRepo], which notifies on every edit, so this screen and
// its detail pages rebuild via [_RepoBuilder]. Playlist create / rename /
// delete go through the repo (and persist) exactly like the original.

import 'package:flutter/material.dart';

import '../../data/library.dart';
import '../../data/settings_store.dart';
import '../../models/track.dart';
import '../theme.dart';

/// Rebuilds [builder] whenever [repo] notifies a change.
class _RepoBuilder extends StatefulWidget {
  const _RepoBuilder({required this.repo, required this.builder});

  final LibraryRepo repo;
  final Widget Function(BuildContext context) builder;

  @override
  State<_RepoBuilder> createState() => _RepoBuilderState();
}

class _RepoBuilderState extends State<_RepoBuilder> {
  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.repo.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({
    super.key,
    required this.library,
    required this.onPlay,
    this.onOpenCollection,
    this.glassStyle = GlassStyle.liquid,
  });

  final LibraryRepo library;

  /// Play [Track] with [queue] as its queue context.
  final void Function(Track track, List<Track> queue) onPlay;
  final void Function(Collection collection)? onOpenCollection;
  final GlassStyle glassStyle;

  @override
  Widget build(BuildContext context) {
    return _RepoBuilder(
      repo: library,
      builder: (context) {
        final data = library.data;
        return ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Your library',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.4,
              children: [
                _Tile(
                  icon: Icons.favorite,
                  title: 'Liked songs',
                  subtitle: '${data.liked.length} tracks',
                  glassStyle: glassStyle,
                  onTap: () => _push(
                    context,
                    _LikedPage(library: library, onPlay: onPlay),
                  ),
                ),
                _Tile(
                  icon: Icons.queue_music,
                  title: 'Playlists',
                  subtitle: '${data.playlists.length} playlists',
                  glassStyle: glassStyle,
                  onTap: null, // the list is right below
                ),
                _Tile(
                  icon: Icons.bookmark,
                  title: 'Saved',
                  subtitle: '${data.saved.length} collections',
                  glassStyle: glassStyle,
                  onTap: null,
                ),
                _Tile(
                  icon: Icons.history,
                  title: 'History',
                  subtitle: '${data.history.length} plays',
                  glassStyle: glassStyle,
                  onTap: () => _push(
                    context,
                    _HistoryPage(library: library, onPlay: onPlay),
                  ),
                ),
              ],
            ),
            SectionHeader(
              title: 'Playlists',
              trailing: IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New playlist',
                onPressed: () => _createPlaylist(context),
              ),
            ),
            if (data.playlists.isEmpty)
              const _EmptyLine('No playlists yet — tap + to create one.')
            else
              for (final p in data.playlists)
                _PlaylistRow(
                  playlist: p,
                  onTap: () => _push(
                    context,
                    _PlaylistPage(
                      library: library,
                      playlistId: p.id,
                      onPlay: onPlay,
                    ),
                  ),
                  onRename: p.isSynced
                      ? null
                      : () => _renamePlaylist(context, p),
                  onDelete: () => _deletePlaylist(context, p),
                ),
            const SectionHeader(title: 'Saved'),
            if (data.saved.isEmpty)
              const _EmptyLine('Nothing saved yet.')
            else
              for (final c in data.saved)
                ListTile(
                  leading: ArtworkImage(url: c.artUrl, size: 48),
                  title: Text(c.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    c.subtitle ?? c.kind.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.bookmark),
                    tooltip: 'Remove from saved',
                    onPressed: () => library.toggleSaved(c),
                  ),
                  onTap:
                      onOpenCollection == null ? null : () => onOpenCollection!(c),
                ),
            SectionHeader(
              title: 'Recently played',
              trailing: data.history.isEmpty
                  ? null
                  : TextButton(
                      onPressed: library.clearHistory,
                      child: const Text('Clear'),
                    ),
            ),
            if (data.history.isEmpty)
              const _EmptyLine('Play a song and it will show up here.')
            else
              for (final h in data.history.take(15))
                TrackTile(
                  track: h.track,
                  onTap: () => onPlay(h.track, library.recentlyPlayed),
                ),
          ],
        );
      },
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final name = await _nameDialog(context, title: 'New playlist');
    if (name != null && name.trim().isNotEmpty) {
      library.createPlaylist(name);
    }
  }

  Future<void> _renamePlaylist(BuildContext context, LocalPlaylist p) async {
    final name =
        await _nameDialog(context, title: 'Rename playlist', initial: p.name);
    if (name != null && name.trim().isNotEmpty) {
      library.renamePlaylist(p.id, name);
    }
  }

  Future<void> _deletePlaylist(BuildContext context, LocalPlaylist p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('"${p.name}" will be removed. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) library.deletePlaylist(p.id);
  }
}

/// Name prompt used for playlist create/rename (Kotlin: NameDialog).
Future<String?> _nameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
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
    final scheme = Theme.of(context).colorScheme;
    return GlassContainer(
      glassStyle: glassStyle,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
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

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final LocalPlaylist playlist;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final art = playlist.artUrl ??
        (playlist.tracks.isNotEmpty ? playlist.tracks.first.artUrl : null);
    return ListTile(
      leading: ArtworkImage(url: art, size: 52),
      title: Text(playlist.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        playlist.isSynced
            ? '${playlist.tracks.length} tracks · Synced'
            : '${playlist.tracks.length} tracks',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'rename') onRename?.call();
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => [
          if (onRename != null)
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: onTap,
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

/// Liked songs page.
class _LikedPage extends StatelessWidget {
  const _LikedPage({required this.library, required this.onPlay});

  final LibraryRepo library;
  final void Function(Track track, List<Track> queue) onPlay;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Liked songs')),
      body: _RepoBuilder(
        repo: library,
        builder: (context) {
          final liked = library.liked;
          if (liked.isEmpty) {
            return const Center(child: Text('No liked songs yet.'));
          }
          return ListView.builder(
            itemCount: liked.length,
            itemBuilder: (_, i) => TrackTile(
              track: liked[i],
              onTap: () => onPlay(liked[i], liked),
              trailing: IconButton(
                icon: const Icon(Icons.favorite),
                tooltip: 'Unlike',
                onPressed: () => library.setLiked(liked[i], false),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Full history page.
class _HistoryPage extends StatelessWidget {
  const _HistoryPage({required this.library, required this.onPlay});

  final LibraryRepo library;
  final void Function(Track track, List<Track> queue) onPlay;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear history',
            onPressed: library.clearHistory,
          ),
        ],
      ),
      body: _RepoBuilder(
        repo: library,
        builder: (context) {
          final history = library.history;
          if (history.isEmpty) {
            return const Center(child: Text('Nothing played yet.'));
          }
          final tracks = library.recentlyPlayed;
          return ListView.builder(
            itemCount: history.length,
            itemBuilder: (_, i) => TrackTile(
              track: history[i].track,
              onTap: () => onPlay(history[i].track, tracks),
            ),
          );
        },
      ),
    );
  }
}

/// One playlist's tracks, with remove + play.
class _PlaylistPage extends StatelessWidget {
  const _PlaylistPage({
    required this.library,
    required this.playlistId,
    required this.onPlay,
  });

  final LibraryRepo library;
  final String playlistId;
  final void Function(Track track, List<Track> queue) onPlay;

  @override
  Widget build(BuildContext context) {
    return _RepoBuilder(
      repo: library,
      builder: (context) {
        final p = library.playlist(playlistId);
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This playlist was deleted.')),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(p.name)),
          body: p.tracks.isEmpty
              ? const Center(child: Text('No tracks in this playlist yet.'))
              : ListView.builder(
                  itemCount: p.tracks.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.icon(
                          onPressed: () => onPlay(p.tracks.first, p.tracks),
                          icon: const Icon(Icons.play_arrow),
                          label: Text('Play ${p.tracks.length} tracks'),
                        ),
                      );
                    }
                    final t = p.tracks[i - 1];
                    return TrackTile(
                      track: t,
                      onTap: () => onPlay(t, p.tracks),
                      trailing: IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        tooltip: 'Remove from playlist',
                        onPressed: () =>
                            library.removeFromPlaylist(p.id, t.id),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
