// Settings screen (Kotlin: ui/settings/SettingsHome.kt + SettingsPages.kt
// + SourcesPage.kt).
//
// Everything reads/writes the injected [SettingsStore]; the store notifies
// on update, and this screen listens, so pickers always show live values.
// The sleep timer is an engine concern, so the chosen minutes go out
// through [SettingsScreen.onSleepTimer] (0 = off) and are also remembered
// as the settings default (AppSettings.sleepDefaultMin).

// ThemeMode here is UpZe's own (data/settings_store.dart), not Material's.
import 'package:flutter/material.dart' hide ThemeMode;

import '../../data/settings_store.dart';
import '../../models/track.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    this.onSleepTimer,
    this.onOpenAccounts,
    this.onOpenEq,
    this.onOpenDownloads,
  });

  final SettingsStore settings;

  /// Sleep timer chosen by the user, in minutes; 0 = timer off.
  final void Function(int minutes)? onSleepTimer;

  /// Opens the Accounts & servers screen; tile hidden when null.
  final VoidCallback? onOpenAccounts;

  /// Opens the Sound / Equalizer screen; tile hidden when null.
  final VoidCallback? onOpenEq;

  /// Opens the Downloads manager screen; tile hidden when null.
  final VoidCallback? onOpenDownloads;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Currently armed sleep timer in this session; null = off.
  int? _sleepMinutes;

  SettingsStore get _store => widget.settings;
  AppSettings get _s => _store.value;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChange);
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _update(AppSettings Function(AppSettings) f) => _store.update(f);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Settings',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        const _SectionTitle('Playback'),
        _PickerTile(
          icon: Icons.high_quality,
          title: 'Streaming quality',
          value: _s.quality.label,
          subtitle: _s.quality.detail,
          onTap: () => _pickQuality(
            title: 'Streaming quality',
            current: _s.quality,
            onPick: (q) => _update((s) => s.copyWith(quality: q)),
          ),
        ),
        _PickerTile(
          icon: Icons.signal_cellular_alt,
          title: 'Mobile data quality',
          value: _s.mobileQuality.label,
          subtitle: _s.mobileQuality.detail,
          onTap: () => _pickQuality(
            title: 'Mobile data quality',
            current: _s.mobileQuality,
            onPick: (q) => _update((s) => s.copyWith(mobileQuality: q)),
          ),
        ),
        _PickerTile(
          icon: Icons.download,
          title: 'Download quality',
          value: _s.downloadQuality.label,
          subtitle: _s.downloadQuality.detail,
          onTap: () => _pickQuality(
            title: 'Download quality',
            current: _s.downloadQuality,
            onPick: (q) => _update((s) => s.copyWith(downloadQuality: q)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Crossfade'),
          subtitle: Text(
            _s.crossfadeSec == 0
                ? 'Off'
                : '${_s.crossfadeSec} s between songs'
                    '${_s.gapless ? ' (gapless is on, so it stays unused)' : ''}',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: _s.crossfadeSec.toDouble(),
            min: 0,
            max: 12,
            divisions: 12,
            label: _s.crossfadeSec == 0 ? 'Off' : '${_s.crossfadeSec} s',
            onChanged: (v) =>
                _update((s) => s.copyWith(crossfadeSec: v.round())),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.all_inclusive),
          title: const Text('Gapless playback'),
          value: _s.gapless,
          onChanged: (v) => _update((s) => s.copyWith(gapless: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.play_circle_outline),
          title: const Text('Autoplay similar songs'),
          value: _s.autoplay,
          onChanged: (v) => _update((s) => s.copyWith(autoplay: v)),
        ),
        const _SectionTitle('Sleep timer'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Off'),
                selected: _sleepMinutes == null,
                onSelected: (_) => _setSleep(null),
              ),
              for (final m in const [5, 10, 15, 20, 30, 45, 60, 90])
                ChoiceChip(
                  label: Text('$m min'),
                  selected: _sleepMinutes == m,
                  onSelected: (_) => _setSleep(m),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Default offered first: ${_s.sleepDefaultMin} min'
            '${_s.sleepFade ? ' · fades out at the end' : ''}'
            '${_s.sleepFinishSong ? ' · finishes the current song' : ''}',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const _SectionTitle('Source priority'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Drag to reorder. UpZe tries sources in this order and falls '
            'over to the next one when a song cannot be played.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: true,
          onReorder: _reorderSources,
          children: [
            for (var i = 0; i < _s.sourcePriority.length; i++)
              ListTile(
                key: ValueKey(_s.sourcePriority[i]),
                leading: CircleAvatar(
                  radius: 14,
                  child: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                ),
                title: Text(_s.sourcePriority[i].label),
                trailing: const Icon(Icons.drag_handle),
              ),
          ],
        ),
        _PickerTile(
          icon: Icons.key,
          title: 'Jamendo client ID',
          value: (_s.jamendoClientId == null || _s.jamendoClientId!.isEmpty)
              ? 'Not set'
              : 'Set',
          subtitle: 'Needed for Jamendo search and FLAC streams',
          onTap: _editJamendoId,
        ),
        const _SectionTitle('Appearance'),
        _PickerTile(
          icon: Icons.blur_on,
          title: 'Glass style',
          value: _s.glass.label,
          onTap: () => _pickEnum<GlassStyle>(
            title: 'Glass style',
            values: GlassStyle.values,
            labelOf: (v) => v.label,
            current: _s.glass,
            onPick: (v) => _update((s) => s.copyWith(glass: v)),
          ),
        ),
        _PickerTile(
          icon: Icons.dark_mode,
          title: 'Theme',
          value: _s.themeMode.label,
          onTap: () => _pickEnum<ThemeMode>(
            title: 'Theme',
            values: ThemeMode.values,
            labelOf: (v) => v.label,
            current: _s.themeMode,
            onPick: (v) => _update((s) => s.copyWith(themeMode: v)),
          ),
        ),
        _PickerTile(
          icon: Icons.music_note,
          title: 'Player style',
          value: _s.playerStyle.label,
          onTap: () => _pickEnum<PlayerStyle>(
            title: 'Player style',
            values: PlayerStyle.values,
            labelOf: (v) => v.label,
            current: _s.playerStyle,
            onPick: (v) => _update((s) => s.copyWith(playerStyle: v)),
          ),
        ),
        _PickerTile(
          icon: Icons.dock,
          title: 'Dock style',
          value: _s.dockStyle.label,
          onTap: () => _pickEnum<DockStyle>(
            title: 'Dock style',
            values: DockStyle.values,
            labelOf: (v) => v.label,
            current: _s.dockStyle,
            onPick: (v) => _update((s) => s.copyWith(dockStyle: v)),
          ),
        ),
        _PickerTile(
          icon: Icons.dashboard,
          title: 'Home style',
          value: _s.homeStyle.label,
          onTap: () => _pickEnum<HomeStyle>(
            title: 'Home style',
            values: HomeStyle.values,
            labelOf: (v) => v.label,
            current: _s.homeStyle,
            onPick: (v) => _update((s) => s.copyWith(homeStyle: v)),
          ),
        ),
        _PickerTile(
          icon: Icons.navigation,
          title: 'Navigation bar',
          value: _s.navMode.label,
          onTap: () => _pickEnum<NavBarMode>(
            title: 'Navigation bar',
            values: NavBarMode.values,
            labelOf: (v) => v.label,
            current: _s.navMode,
            onPick: (v) => _update((s) => s.copyWith(navBarMode: v)),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.palette),
          title: const Text('Dynamic colour from artwork'),
          value: _s.dynamicColor,
          onChanged: (v) => _update((s) => s.copyWith(dynamicColor: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.vibration),
          title: const Text('Haptics'),
          value: _s.haptics,
          onChanged: (v) => _update((s) => s.copyWith(haptics: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.motion_photos_off),
          title: const Text('Reduce motion'),
          value: _s.reduceMotion,
          onChanged: (v) => _update((s) => s.copyWith(reduceMotion: v)),
        ),
        if (widget.onOpenAccounts != null ||
            widget.onOpenEq != null ||
            widget.onOpenDownloads != null) ...[
          const _SectionTitle('Accounts, sound & downloads'),
          if (widget.onOpenAccounts != null)
            ListTile(
              leading: const Icon(Icons.cloud_circle),
              title: const Text('Accounts & servers'),
              subtitle: const Text(
                  'Subsonic, Jellyfin, Spotify and Jamendo sign-ins'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenAccounts,
            ),
          if (widget.onOpenEq != null)
            ListTile(
              leading: const Icon(Icons.equalizer),
              title: const Text('Sound / Equalizer'),
              subtitle: const Text('Graphic EQ, preamp and parametric bands'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenEq,
            ),
          if (widget.onOpenDownloads != null)
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Downloads'),
              subtitle: const Text('Manage downloaded songs and storage'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenDownloads,
            ),
        ],
        const _SectionTitle('Downloads'),
        SwitchListTile(
          secondary: const Icon(Icons.wifi),
          title: const Text('Wi-Fi only downloads'),
          value: _s.wifiOnlyDownloads,
          onChanged: (v) => _update((s) => s.copyWith(wifiOnlyDownloads: v)),
        ),
      ],
    );
  }

  void _setSleep(int? minutes) {
    setState(() => _sleepMinutes = minutes);
    if (minutes != null) {
      _update((s) => s.copyWith(sleepDefaultMin: minutes));
    }
    widget.onSleepTimer?.call(minutes ?? 0);
  }

  void _reorderSources(int oldIndex, int newIndex) {
    final list = [..._s.sourcePriority];
    if (newIndex > oldIndex) newIndex -= 1;
    list.insert(newIndex, list.removeAt(oldIndex));
    _update((s) => s.copyWith(sourcePriority: list));
  }

  Future<void> _pickQuality({
    required String title,
    required Quality current,
    required void Function(Quality) onPick,
  }) =>
      _pickEnum<Quality>(
        title: title,
        values: Quality.values,
        labelOf: (q) => q.label,
        subtitleOf: (q) => q.detail,
        current: current,
        onPick: onPick,
      );

  Future<void> _pickEnum<T>({
    required String title,
    required List<T> values,
    required String Function(T) labelOf,
    String Function(T)? subtitleOf,
    required T current,
    required void Function(T) onPick,
  }) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            for (final v in values)
              ListTile(
                title: Text(labelOf(v)),
                subtitle:
                    subtitleOf == null ? null : Text(subtitleOf(v)),
                trailing: v == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) onPick(picked);
  }

  Future<void> _editJamendoId() async {
    final controller =
        TextEditingController(text: _s.jamendoClientId ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Jamendo client ID'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Client ID from your Jamendo developer account',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      final v = controller.text.trim();
      _update((s) => s.copyWith(jamendoClientId: v.isEmpty ? null : v));
    }
    controller.dispose();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? Text(value) : Text('$value · $subtitle'),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
