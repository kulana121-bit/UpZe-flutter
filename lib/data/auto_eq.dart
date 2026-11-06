// Port of data/AutoEq.kt (UpZe v1.0.1, com.ravi.musicspot.data).
//
// DATA ONLY, exactly like the original file: the built-in 10-band graphic
// preset table, plus the AutoEq headphone-correction lookup — fetch the
// AutoEq index once, cache it on disk for 14 days, search it, and parse a
// picked profile's ParametricEQ.txt into parametric bands + preamp.
// Nothing here touches audio; applying a profile is the DSP layer's job.

import 'dart:io';

import 'package:http/http.dart' as http;

import 'settings_store.dart';

/// (Kotlin: EqPresets) — 10-band graphic presets (32 Hz … 16 kHz).
/// Plain tonal curves, not measurements.
abstract final class EqPresets {
  /// Centre frequencies of the 10 graphic bands, Hz
  /// (Kotlin: dsp EqConfig.GRAPHIC_FREQS).
  static const List<double> graphicFreqs = [
    32.0,
    64.0,
    125.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    4000.0,
    8000.0,
    16000.0,
  ];

  /// Preset name → 10 gains in dB, one per [graphicFreqs] band.
  static const Map<String, List<double>> graphic = {
    'Flat': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    'Bass': [5.0, 4.0, 3.0, 1.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    'Warm': [2.0, 2.0, 1.5, 1.0, 0.0, 0.0, -0.5, -1.0, -1.5, -2.0],
    'Vocal': [-2.0, -1.5, -1.0, 0.0, 1.5, 2.5, 2.5, 1.5, 0.0, -1.0],
    'Bright': [0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 1.5, 2.5, 3.0, 3.0],
    'V-shape': [4.0, 3.0, 1.5, 0.0, -1.5, -1.5, 0.0, 1.5, 3.0, 3.5],
    'Loudness': [4.0, 3.0, 1.0, 0.0, -0.5, 0.0, 0.0, 1.0, 2.5, 3.0],
    'Late night': [-1.0, -0.5, 0.0, 0.5, 1.0, 1.0, 0.5, 0.0, -1.5, -2.5],
    'Treble cut': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0, -2.5, -4.0, -5.0],
  };
}

/// (Kotlin: AutoEq.Entry) — one headphone in the AutoEq index.
class AutoEqEntry {
  const AutoEqEntry({
    required this.name,
    required this.source,
    required this.path,
  });

  /// Headphone name, e.g. "Sennheiser HD 600".
  final String name;

  /// Who measured it, e.g. "oratory1990".
  final String source;

  /// Path of the profile folder under the AutoEq results base URL.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is AutoEqEntry &&
      other.name == name &&
      other.source == source &&
      other.path == path;

  @override
  int get hashCode => Object.hash(name, source, path);
}

/// (Kotlin: AutoEq.Profile) — a parsed ParametricEQ.txt.
class AutoEqProfile {
  const AutoEqProfile({
    required this.name,
    required this.preampDb,
    required this.bands,
  });

  final String name;
  final double preampDb;
  final List<ParamBandSetting> bands;

  /// The profile as an [EqSetting] parametric section, ready to store:
  /// preamp + parametric bands, parametric switched on.
  EqSetting toEqSetting(EqSetting base) => base.copyWith(
        parametric: bands,
        parametricOn: true,
        preampDb: preampDb,
      );
}

/// (Kotlin: AutoEq)
///
/// AutoEq (github.com/jaakkopasanen/AutoEq, MIT): headphone correction
/// profiles. The index (~850 KB) is fetched once and cached; a picked
/// profile's ParametricEQ.txt is parsed into parametric bands + preamp.
abstract final class AutoEq {
  static const String _base =
      'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/';

  /// In-memory copy of the parsed index (Kotlin: @Volatile index).
  static List<AutoEqEntry>? _index;

  static final RegExp _line =
      RegExp(r'^- \[(.+?)]\(\./(.+?)\) by (.+?)(?: on .*)?$');
  static final RegExp _filter = RegExp(
    r'Filter\s+\d+:\s+(ON|OFF)\s+(PK|LSC|HSC|LS|HS|LP|HP|LPQ|HPQ)\s+'
    r'Fc\s+([\d.]+)\s*Hz(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?',
    caseSensitive: false,
  );
  static final RegExp _preamp = RegExp(r'Preamp:\s*(-?[\d.]+)\s*dB');

  /// Kotlin: AutoEq.search — every space-separated term must appear in
  /// the headphone name (case-insensitive).
  static Future<List<AutoEqEntry>> search(
    String cacheDirPath,
    String query, {
    int limit = 40,
  }) async {
    final all = await _loadIndex(cacheDirPath);
    final terms = query
        .toLowerCase()
        .split(' ')
        .where((t) => t.trim().isNotEmpty)
        .toList();
    if (terms.isEmpty) return const [];
    return all
        .where((e) {
          final n = e.name.toLowerCase();
          return terms.every((t) => n.contains(t));
        })
        .take(limit)
        .toList();
  }

  static Future<List<AutoEqEntry>> _loadIndex(String cacheDirPath) async {
    final cached = _index;
    if (cached != null) return cached;
    final f = File('$cacheDirPath/autoeq-index.md');
    final fresh = await f.exists() &&
        DateTime.now().difference(await f.lastModified()) <
            const Duration(days: 14);
    final String text;
    if (fresh) {
      text = await f.readAsString();
    } else {
      text = await _getString('${_base}INDEX.md');
      try {
        await f.parent.create(recursive: true);
        await f.writeAsString(text);
      } catch (_) {}
    }
    final entries = <AutoEqEntry>[];
    for (final raw in text.split('\n')) {
      final m = _line.firstMatch(raw.trim());
      if (m != null) {
        entries.add(AutoEqEntry(
          name: m.group(1)!,
          source: m.group(3)!,
          path: m.group(2)!,
        ));
      }
    }
    _index = entries;
    return entries;
  }

  /// Kotlin: AutoEq.profile — fetch and parse one entry's ParametricEQ.txt.
  static Future<AutoEqProfile> profile(AutoEqEntry e) async {
    final folderName = Uri.decodeComponent(e.path.split('/').last);
    final fileName = Uri.encodeComponent('$folderName ParametricEQ.txt');
    final url = '$_base${e.path}/$fileName';
    return parse(e.name, await _getString(url));
  }

  /// Kotlin: AutoEq.parse — ParametricEQ.txt text → preamp + bands.
  /// Throws [FormatException] when the text carries no filters
  /// (Kotlin: require(bands.isNotEmpty())).
  static AutoEqProfile parse(String name, String text) {
    final pre = double.tryParse(_preamp.firstMatch(text)?.group(1) ?? '') ??
        0.0;
    final bands = <ParamBandSetting>[];
    for (final m in _filter.allMatches(text)) {
      final type = switch (m.group(2)!.toUpperCase()) {
        'PK' => FilterType.peak,
        'LSC' || 'LS' => FilterType.lowShelf,
        'HSC' || 'HS' => FilterType.highShelf,
        'LP' || 'LPQ' => FilterType.lowPass,
        'HP' || 'HPQ' => FilterType.highPass,
        _ => null,
      };
      if (type == null) continue;
      bands.add(ParamBandSetting(
        type: type,
        freqHz: double.parse(m.group(3)!),
        gainDb: double.tryParse(m.group(4) ?? '') ?? 0.0,
        q: double.tryParse(m.group(5) ?? '') ?? 0.71,
        enabled: m.group(1)!.toUpperCase() == 'ON',
      ));
    }
    if (bands.isEmpty) {
      throw const FormatException('No filters in this profile');
    }
    return AutoEqProfile(name: name, preampDb: pre, bands: bands);
  }

  /// Plain GET → body text (stands in for the Kotlin Http.getString).
  static Future<String> _getString(String url) async {
    final resp =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode} for $url');
    }
    return resp.body;
  }
}
