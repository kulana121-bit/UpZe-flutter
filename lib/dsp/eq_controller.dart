// EQ bridge — settings_store.dart's EqSetting → just_audio's Android
// system equalizer (Phase 3).
//
// =====================================================================
// PLAIN STATEMENT: THIS IS AN APPROXIMATION OF THE KOTLIN DSP CHAIN.
// =====================================================================
// The Kotlin app runs its own DSP (dsp/Dsp.kt + dsp/Engine.kt): a full
// parametric EQ of arbitrary biquad filters (peaking / shelves / passes
// at any frequency, gain and Q), a 10-band graphic stage, bass boost,
// stereo widening, a limiter, dynamic processing and an honest upscaler
// (bandwidth extension that labels its output "Upscaled", never
// "Lossless"). NONE of that has a Flutter / just_audio equivalent, and
// NONE of it is ported here.
//
// What exists on this platform is Android's built-in Equalizer effect,
// exposed by just_audio as [AndroidEqualizer]: a FIXED set of device
// bands (usually 5, at device-chosen centre frequencies, with a
// device-chosen gain range, often ±15 dB). This file projects the
// EqSetting's curve onto those few bands as faithfully as that allows:
//
//   * Each device band gets the EqSetting curve's value at the band's
//     centre frequency: the 10-band graphic stage is sampled by nearest
//     band in log-frequency space; enabled parametric PEAK / LOW_SHELF /
//     HIGH_SHELF bands (when parametricOn) add their gain with a smooth
//     log-frequency falloff standing in for the real biquad shape;
//     bassBoostDb adds as a 90 Hz low shelf, as in the Kotlin chain.
//   * Parametric LOW_PASS / HIGH_PASS bands have no gain and no graphic
//     representation — they are DROPPED here.
//   * preampDb is applied through [AndroidLoudnessEnhancer]'s target
//     gain, and autoHeadroom is approximated by pulling the target down
//     by the largest positive band boost. There is no limiter behind it
//     (the Kotlin chain has one), so a large positive preamp can clip
//     where the original would not.
//   * limiter, widen and the upscaler/enhancer are NOT applied at all.
//
// The result should sound close to the original for gentle tonal
// shaping and AutoEq-style corrections; it is not the same processing.
// =====================================================================
//
// WIRING (done by the parent in player_controller / main, not here):
// one EqController per AudioPlayer — an AudioEffect instance cannot be
// attached to two players, and PlayerController owns two (crossfade) —
// so build one controller for player A and another for player B:
//
//   final eqA = EqController();
//   final playerA = AudioPlayer(audioPipeline: eqA.buildPipeline(settings.eq));
//   await eqA.apply(settings.eq); // re-call whenever the EQ settings change

import 'dart:async';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';

import '../data/auto_eq.dart';
import '../data/settings_store.dart';

class EqController {
  EqController({
    AndroidEqualizer? equalizer,
    AndroidLoudnessEnhancer? loudnessEnhancer,
  })  : equalizer = equalizer ?? AndroidEqualizer(),
        loudnessEnhancer = loudnessEnhancer ?? AndroidLoudnessEnhancer();

  /// The system equalizer this controller drives.
  final AndroidEqualizer equalizer;

  /// Carries the preamp (see the header: approximation).
  final AndroidLoudnessEnhancer loudnessEnhancer;

  /// Build the [AudioPipeline] to hand to `AudioPlayer(audioPipeline:)`.
  ///
  /// The pipeline always contains both effects; whether they are active
  /// follows [eq] (enabled && !bypassB). Gains themselves are pushed by
  /// [apply] once the player is live and the device bands are known.
  AudioPipeline buildPipeline(EqSetting eq) {
    final active = eq.enabled && !eq.bypassB;
    unawaited(equalizer.setEnabled(active));
    unawaited(loudnessEnhancer.setEnabled(active && eq.preampDb != 0));
    return AudioPipeline(
      androidAudioEffects: [equalizer, loudnessEnhancer],
    );
  }

  /// Apply [setting] to this controller's own effects.
  Future<void> apply(EqSetting setting) => applyTo(
        equalizer,
        setting,
        loudnessEnhancer: loudnessEnhancer,
      );

  /// Push [setting]'s curve onto [equalizer]'s device bands, and the
  /// preamp onto [loudnessEnhancer] when one is given.
  ///
  /// Must be called after the player owning [equalizer] has loaded a
  /// source — the device band list only exists once the platform effect
  /// is active; before that this throws a [StateError] after a short
  /// wait instead of hanging forever.
  Future<void> applyTo(
    AndroidEqualizer equalizer,
    EqSetting setting, {
    AndroidLoudnessEnhancer? loudnessEnhancer,
  }) async {
    final active = setting.enabled && !setting.bypassB;
    if (!active) {
      await equalizer.setEnabled(false);
      if (loudnessEnhancer != null) {
        await loudnessEnhancer.setTargetGain(0);
        await loudnessEnhancer.setEnabled(false);
      }
      return;
    }
    final AndroidEqualizerParameters params;
    try {
      params = await equalizer.parameters
          .timeout(const Duration(seconds: 3));
    } on TimeoutException {
      throw StateError(
        'AndroidEqualizer parameters unavailable — applyTo() must be '
        'called after the owning AudioPlayer has loaded a source.',
      );
    }
    final centers = params.bands.map((b) => b.centerFrequency).toList();
    final gains = mapToDeviceBands(setting, centers);
    for (var i = 0; i < params.bands.length; i++) {
      final clamped =
          gains[i].clamp(params.minDecibels, params.maxDecibels).toDouble();
      await params.bands[i].setGain(clamped);
    }
    await equalizer.setEnabled(true);

    if (loudnessEnhancer != null) {
      // Preamp via the loudness enhancer. Auto-headroom approximation:
      // never let preamp + the biggest band boost sum positive — pull
      // the target down by the peak boost, like the Kotlin chain's
      // headroom management (but with no limiter behind it).
      var target = setting.preampDb;
      if (setting.autoHeadroom && gains.isNotEmpty) {
        final peakBoost = gains.fold<double>(0, (a, g) => math.max(a, g));
        if (peakBoost > 0) target = math.min(target, -peakBoost);
      }
      await loudnessEnhancer.setTargetGain(target);
      await loudnessEnhancer.setEnabled(target != 0);
    }
  }

  /// The EqSetting curve's gain (dB) at each of [deviceCenters] (Hz).
  ///
  /// Pure and static so it can be unit-tested without a device: graphic
  /// stage by nearest band in log2 space, parametric peak/shelf bands
  /// (only when [EqSetting.parametricOn]) added with a smooth falloff,
  /// bass boost added as a 90 Hz low shelf (Kotlin: BASS_FREQ = 90).
  static List<double> mapToDeviceBands(
    EqSetting eq,
    List<double> deviceCenters,
  ) =>
      [for (final f in deviceCenters) curveGainAt(eq, f)];

  /// The curve's total gain (dB) at frequency [f] Hz.
  static double curveGainAt(EqSetting eq, double f) {
    if (f <= 0) return 0;
    var gain = 0.0;
    // Graphic stage: nearest of the 10 Kotlin bands in log-frequency.
    if (eq.graphic.isNotEmpty) {
      var best = 0;
      var bestDist = double.infinity;
      for (var i = 0; i < eq.graphic.length && i < EqPresets.graphicFreqs.length; i++) {
        final d = (log2(f) - log2(EqPresets.graphicFreqs[i])).abs();
        if (d < bestDist) {
          bestDist = d;
          best = i;
        }
      }
      gain += eq.graphic[best];
    }
    // Bass boost: low shelf at 90 Hz, as in EqConfig.bands().
    if (eq.bassBoostDb != 0) {
      gain += eq.bassBoostDb * _shelfWeight(f, 90.0, low: true);
    }
    // Parametric stage: peaks and shelves only — passes carry no gain
    // and are dropped (see header).
    if (eq.parametricOn) {
      for (final band in eq.parametric) {
        if (!band.enabled || band.gainDb == 0) continue;
        switch (band.type) {
          case FilterType.peak:
            // Lorentzian falloff in log2 space; at f == fc the weight
            // is 1, narrowing as Q grows — a stand-in for the biquad's
            // true magnitude response.
            final octaves = log2(f / band.freqHz);
            final x = 2 * band.q * octaves;
            gain += band.gainDb / (1 + x * x);
          case FilterType.lowShelf:
            gain += band.gainDb * _shelfWeight(f, band.freqHz, low: true);
          case FilterType.highShelf:
            gain += band.gainDb * _shelfWeight(f, band.freqHz, low: false);
          case FilterType.lowPass:
          case FilterType.highPass:
            break; // not representable on graphic bands
        }
      }
    }
    return gain;
  }

  /// 1 well inside the shelf's pass side, 0.5 at [fc], 0 outside.
  static double _shelfWeight(double f, double fc, {required bool low}) {
    final ratio = low ? f / fc : fc / f;
    return 1 / (1 + ratio * ratio);
  }

  static double log2(double x) => math.log(x) / math.ln2;
}
