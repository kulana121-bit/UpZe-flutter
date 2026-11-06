// Equalizer screen (Kotlin: ui/settings/SoundPage.kt EQ half).
//
// Edits the graphic 10-band EQ, preamp and parametric bands held in
// [AppSettings.eq] through the injected [SettingsStore]. The store is the
// single source of truth: every change is written with
// SettingsStore.update, the screen listens and rebuilds, and
// [EqScreen.onEqChanged] lets the host re-apply the curve to the player
// (the system-EQ bridge in lib/dsp/eq_controller.dart).
//
// Honest scope: the parametric section edits exactly the fields
// [ParamBandSetting] holds (type, freqHz, gainDb, q, enabled) — no extra
// knobs are invented.

import 'dart:math' as math;

import 'package:flutter/material.dart' hide ThemeMode;

import '../../data/auto_eq.dart';
import '../../data/settings_store.dart';

class EqScreen extends StatefulWidget {
  const EqScreen({
    super.key,
    required this.settings,
    this.onEqChanged,
  });

  final SettingsStore settings;

  /// Called after any EQ change has been persisted, so the host can
  /// re-apply the curve to the live players.
  final VoidCallback? onEqChanged;

  @override
  State<EqScreen> createState() => _EqScreenState();
}

class _EqScreenState extends State<EqScreen> {
  SettingsStore get _store => widget.settings;
  AppSettings get _s => _store.value;
  EqSetting get _eq => _s.eq;

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

  void _setEq(EqSetting eq) {
    _store.update((s) => s.copyWith(eq: eq));
    widget.onEqChanged?.call();
  }

  void _setBand(int i, double db) {
    final graphic = [..._eq.graphic];
    while (graphic.length < 10) {
      graphic.add(0.0);
    }
    graphic[i] = db;
    _setEq(_eq.copyWith(graphic: graphic, preset: 'Custom'));
  }

  void _applyPreset(String name) {
    final gains = EqPresets.graphic[name];
    if (gains == null) return;
    _setEq(_eq.copyWith(graphic: [...gains], preset: name));
  }

  void _setParam(int i, ParamBandSetting band) {
    final bands = [..._eq.parametric];
    bands[i] = band;
    _setEq(_eq.copyWith(parametric: bands));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final eq = _eq;
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.equalizer),
            title: const Text('Equalizer'),
            subtitle: const Text('Turn the whole EQ on or off'),
            value: eq.enabled,
            onChanged: (v) => _setEq(eq.copyWith(enabled: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.flip),
            title: const Text('Bypass (B side)'),
            subtitle: const Text('Hear the sound without EQ, for A/B checks'),
            value: eq.bypassB,
            onChanged: (v) => _setEq(eq.copyWith(bypassB: v)),
          ),
          const _SectionTitle('Presets'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final name in EqPresets.graphic.keys)
                  ChoiceChip(
                    label: Text(name),
                    selected: eq.preset == name,
                    onSelected: (_) => _applyPreset(name),
                  ),
                if (eq.preset == 'Custom')
                  const ChoiceChip(
                    label: Text('Custom'),
                    selected: true,
                    onSelected: null,
                  ),
              ],
            ),
          ),
          const _SectionTitle('Graphic EQ'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Drag each band between −15 and +15 dB. Applied through the '
              'phone\'s system equalizer, so the audible result follows '
              'your device\'s bands.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 216,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 10; i++)
                  _BandSlider(
                    freqHz: i < EqPresets.graphicFreqs.length
                        ? EqPresets.graphicFreqs[i]
                        : 0,
                    value: i < eq.graphic.length ? eq.graphic[i] : 0.0,
                    enabled: eq.enabled && !eq.bypassB,
                    onChanged: (v) => _setBand(i, v),
                  ),
              ],
            ),
          ),
          const _SectionTitle('Preamp'),
          _DbSliderRow(
            label: 'Preamp',
            value: eq.preampDb,
            onChanged: (v) => _setEq(eq.copyWith(preampDb: v)),
          ),
          const _SectionTitle('Parametric bands'),
          SwitchListTile(
            title: const Text('Use parametric bands'),
            subtitle: const Text(
                'Fine filters on top of the graphic EQ (peak / shelf / pass)'),
            value: eq.parametricOn,
            onChanged: (v) => _setEq(eq.copyWith(parametricOn: v)),
          ),
          for (var i = 0; i < eq.parametric.length; i++)
            _ParamBandCard(
              key: ValueKey('param-$i'),
              band: eq.parametric[i],
              active: eq.enabled && eq.parametricOn,
              onChanged: (b) => _setParam(i, b),
            ),
        ],
      ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.freqHz,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final double freqHz;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 32,
      child: Column(
        children: [
          Text(
            value == 0 ? '0' : value.toStringAsFixed(1),
            style: theme.textTheme.labelSmall,
          ),
          SizedBox(
            height: 160,
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: value.clamp(-15.0, 15.0),
                min: -15,
                max: 15,
                divisions: 60,
                onChanged: enabled
                    ? (v) => onChanged(
                        double.parse(v.toStringAsFixed(1)))
                    : null,
              ),
            ),
          ),
          Text(
            _freqLabel(freqHz),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _freqLabel(double hz) {
    if (hz <= 0) return '—';
    if (hz >= 1000) return '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)}k';
    return hz.toStringAsFixed(0);
  }
}

class _DbSliderRow extends StatelessWidget {
  const _DbSliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  static const double _min = -15;
  static const double _max = 15;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          SizedBox(width: 64, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.clamp(_min, _max),
              min: _min,
              max: _max,
              divisions: ((_max - _min) * 2).round(),
              onChanged: (v) =>
                  onChanged(double.parse(v.toStringAsFixed(1))),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)} dB',
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _ParamBandCard extends StatelessWidget {
  const _ParamBandCard({
    super.key,
    required this.band,
    required this.active,
    required this.onChanged,
  });

  final ParamBandSetting band;
  final bool active;
  final ValueChanged<ParamBandSetting> onChanged;

  static String _typeLabel(FilterType t) => switch (t) {
        FilterType.peak => 'Peak',
        FilterType.lowShelf => 'Low shelf',
        FilterType.highShelf => 'High shelf',
        FilterType.lowPass => 'Low pass',
        FilterType.highPass => 'High pass',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usable = active && band.enabled;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_typeLabel(band.type)} · '
                    '${band.freqHz >= 1000 ? '${(band.freqHz / 1000).toStringAsFixed(band.freqHz % 1000 == 0 ? 0 : 2)} kHz' : '${band.freqHz.toStringAsFixed(0)} Hz'}',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Switch(
                  value: band.enabled,
                  onChanged: active
                      ? (v) => onChanged(band.copyWith(enabled: v))
                      : null,
                ),
              ],
            ),
            _MiniSlider(
              label: 'Gain',
              text: '${band.gainDb >= 0 ? '+' : ''}'
                  '${band.gainDb.toStringAsFixed(1)} dB',
              value: band.gainDb.clamp(-15.0, 15.0),
              min: -15,
              max: 15,
              enabled: usable,
              onChanged: (v) => onChanged(band.copyWith(
                  gainDb: double.parse(v.toStringAsFixed(1)))),
            ),
            _MiniSlider(
              label: 'Freq',
              text: band.freqHz >= 1000
                  ? '${(band.freqHz / 1000).toStringAsFixed(2)} kHz'
                  : '${band.freqHz.toStringAsFixed(0)} Hz',
              // Log-scale slider: position 0..1 maps to 20 Hz..20 kHz.
              value: _freqToPos(band.freqHz),
              min: 0,
              max: 1,
              enabled: usable,
              onChanged: (v) =>
                  onChanged(band.copyWith(freqHz: _posToFreq(v))),
            ),
            _MiniSlider(
              label: 'Q',
              text: band.q.toStringAsFixed(2),
              value: band.q.clamp(0.3, 10.0),
              min: 0.3,
              max: 10,
              enabled: usable,
              onChanged: (v) => onChanged(
                  band.copyWith(q: double.parse(v.toStringAsFixed(2)))),
            ),
          ],
        ),
      ),
    );
  }

  static double _freqToPos(double hz) {
    const lo = 20.0, hi = 20000.0;
    final c = hz.clamp(lo, hi);
    return (math.log(c) - math.log(lo)) / (math.log(hi) - math.log(lo));
  }

  static double _posToFreq(double pos) {
    const lo = 20.0, hi = 20000.0;
    final v = lo * math.exp(pos * (math.log(hi) - math.log(lo)));
    return double.parse(v.toStringAsFixed(v < 100 ? 1 : 0));
  }
}

class _MiniSlider extends StatelessWidget {
  const _MiniSlider({
    required this.label,
    required this.text,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String text;
  final double value;
  final double min;
  final double max;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 40, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: enabled ? onChanged : null,
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(text, textAlign: TextAlign.right),
        ),
      ],
    );
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
