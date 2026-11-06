// Update sheet (Kotlin: update/UpdateSheet.kt).
//
// Shown when Updater.check finds a newer release. Downloading goes
// through the host's [onDownload] (Updater.downloadApk in the app) with
// byte progress mapped to 0..1; once the APK is on disk, Install hands
// the file back to the host ([onInstall]) because the actual install
// intent + FileProvider step is Android-native. Skip / Later just
// report out and close.

import 'dart:io';

import 'package:flutter/material.dart' hide ThemeMode;

import '../update/updater.dart';
import 'theme.dart';

Future<void> showUpdateSheet(
  BuildContext context, {
  required UpdateInfo info,
  required Future<File> Function(void Function(double) onProgress) onDownload,
  required VoidCallback onSkip,
  required VoidCallback onLater,
  required void Function(File apk) onInstall,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => UpdateSheet(
      info: info,
      onDownload: onDownload,
      onSkip: onSkip,
      onLater: onLater,
      onInstall: onInstall,
    ),
  );
}

class UpdateSheet extends StatefulWidget {
  const UpdateSheet({
    super.key,
    required this.info,
    required this.onDownload,
    required this.onSkip,
    required this.onLater,
    required this.onInstall,
  });

  final UpdateInfo info;

  /// Start the APK download; report progress as 0..1; resolves with the
  /// downloaded file.
  final Future<File> Function(void Function(double) onProgress) onDownload;

  /// "Skip this version" — host persists Updater.skip's version string.
  final VoidCallback onSkip;

  /// "Later" — host dismisses until the next check.
  final VoidCallback onLater;

  /// Hand the downloaded APK to the Android installer (host/native).
  final void Function(File apk) onInstall;

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

enum _Phase { idle, downloading, done, failed }

class _UpdateSheetState extends State<UpdateSheet> {
  _Phase _phase = _Phase.idle;
  double? _progress;
  File? _apk;
  String? _error;

  UpdateInfo get info => widget.info;

  Future<void> _startDownload() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = null;
      _error = null;
    });
    try {
      final file = await widget.onDownload((p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _phase = _Phase.done;
        _apk = file;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
        child: GlassContainer(
          strong: true,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.system_update,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Update available · v${info.version}',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                info.apkSize > 0
                    ? '${info.name} · ${_formatBytes(info.apkSize)}'
                    : info.name,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: Text(info.notes),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_phase == _Phase.downloading) ...[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text(
                  _progress == null
                      ? 'Downloading…'
                      : 'Downloading · ${(_progress! * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              if (_phase == _Phase.failed) ...[
                Text(
                  'Download failed${_error != null ? ': $_error' : ''}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  TextButton(
                    onPressed: _phase == _Phase.downloading
                        ? null
                        : () {
                            widget.onSkip();
                            Navigator.of(context).pop();
                          },
                    child: const Text('Skip this version'),
                  ),
                  TextButton(
                    onPressed: _phase == _Phase.downloading
                        ? null
                        : () {
                            widget.onLater();
                            Navigator.of(context).pop();
                          },
                    child: const Text('Later'),
                  ),
                  const Spacer(),
                  if (_phase == _Phase.done && _apk != null)
                    FilledButton.icon(
                      icon: const Icon(Icons.install_mobile),
                      label: const Text('Install'),
                      onPressed: () => widget.onInstall(_apk!),
                    )
                  else
                    FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(
                          _phase == _Phase.failed ? 'Retry' : 'Download'),
                      onPressed:
                          _phase == _Phase.downloading ? null : _startDownload,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
