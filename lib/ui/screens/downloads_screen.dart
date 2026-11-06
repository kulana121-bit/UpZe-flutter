// Downloads manager screen.
//
// The download ACTION lives on track menus / the player (the host calls
// DownloadsRepo.download there); this screen manages what exists: it
// lists every entry in the repo with its state and progress, plays
// finished downloads, retries unfinished ones (through the host's
// [DownloadsScreen.resolveFor], which is SourceManager.resolve in the
// app), and deletes entries. Storage used is shown in the header.

import 'package:flutter/material.dart' hide ThemeMode;

import '../../data/downloads.dart';
import '../../models/track.dart';
import '../../sources/music_source.dart';
import '../theme.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({
    super.key,
    required this.repo,
    required this.onPlay,
    required this.resolveFor,
  });

  final DownloadsRepo repo;

  /// Play a finished download (the host routes it to the player; the
  /// repo's downloaded() lookup makes it play from the local file).
  final Future<void> Function(Track track) onPlay;

  /// Resolve a track to a fresh stream — passed to DownloadsRepo.download
  /// for retries.
  final Future<Resolved> Function(Track track) resolveFor;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  DownloadsRepo get _repo => widget.repo;
  int _usedBytes = 0;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onChange);
    _refreshUsed();
  }

  @override
  void dispose() {
    _repo.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _refreshUsed();
  }

  Future<void> _refreshUsed() async {
    final b = await _repo.usedBytes();
    if (mounted) setState(() => _usedBytes = b);
  }

  Future<void> _retry(DownloadEntry e) async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await _repo.download(e.track, widget.resolveFor);
    } catch (_) {
      // The entry itself records the failure state; nothing else to do.
    }
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _repo.items.values.toList()
      ..sort((a, b) => b.atMs.compareTo(a.atMs));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Delete all downloads',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete all downloads?'),
                    content: Text(
                        '${entries.length} downloaded song(s) will be removed.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Delete all'),
                      ),
                    ],
                  ),
                );
                if (ok == true) _repo.deleteAll();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                entries.isEmpty
                    ? 'No storage used yet'
                    : '${entries.length} song(s) · ${_formatBytes(_usedBytes)} used',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Nothing downloaded yet.\n'
                        'Use Download on a song and it will appear here, '
                        'ready to play offline.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (_, i) => _entryTile(entries[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _entryTile(DownloadEntry e) {
    final theme = Theme.of(context);
    final done = e.state == DownloadState.done;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TrackTile(
          track: e.track,
          onTap: done ? () => widget.onPlay(e.track) : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!done)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Retry download',
                  onPressed: _retrying ? null : () => _retry(e),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete download',
                onPressed: () => _repo.delete(e.track.id),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(88, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: switch (e.state) {
              DownloadState.done => Text(
                  'Downloaded · ${_formatBytes(e.bytes)}'
                  '${e.info != null ? ' · ${e.info!.label}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              DownloadState.running => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: e.progress),
                    const SizedBox(height: 4),
                    Text(
                      'Downloading · ${_formatBytes(e.bytes)}'
                      '${e.total > 0 ? ' of ${_formatBytes(e.total)}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              DownloadState.queued => Text(
                  'Queued',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              DownloadState.failed => Text(
                  'Failed${e.error != null ? ' · ${e.error}' : ''}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
            },
          ),
        ),
      ],
    );
  }

  static String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
