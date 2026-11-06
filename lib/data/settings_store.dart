// Port of data/Settings.kt essentials (UpZe v1.0.1, com.ravi.musicspot.data).
// Pure Dart — AppSettings is a plain data class persisted as JSON to
// settings.json in a directory whose path is passed to the constructor.
//
// NOTE: FilterType and EnhanceLevel live in dsp/ in the Kotlin original
// (dsp/Dsp.kt, dsp/Engine.kt). They are reproduced here because EqSetting
// needs them; if a dsp port later defines them too, drop these copies and
// import from there instead.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/track.dart';

const Object _unset = Object();

T _enumBySerializedName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name.toUpperCase() == name) return v;
  }
  return fallback;
}

/// (Kotlin: ThemeMode)
enum ThemeMode {
  system('System'),
  dark('Dark'),
  light('Light'),
  pureBlack('Pure black');

  const ThemeMode(this.label);
  final String label;
  String get serializedName => this == ThemeMode.pureBlack ? 'PURE_BLACK' : name.toUpperCase();
  static ThemeMode fromSerializedName(String? v) => values.firstWhere(
      (e) => e.serializedName == v,
      orElse: () => ThemeMode.dark);
}

/// v2.0.6: what the phone dock does while a page scrolls down. (Kotlin: NavBarMode)
enum NavBarMode {
  mini('Mini'),
  hide('Hide'),
  always('Always visible');

  const NavBarMode(this.label);
  final String label;
  String get serializedName => name.toUpperCase();
  static NavBarMode fromSerializedName(String? v) =>
      _enumBySerializedName(values, v, NavBarMode.mini);
}

/// v2.0.10: which Now Playing design is used. (Kotlin: PlayerStyle)
enum PlayerStyle {
  classic('Classic'),
  aura('Aura (liquid glass)'),
  vinyl('Deck (cassette)'),
  minimal('Poster (big art)');

  const PlayerStyle(this.label);
  final String label;
  String get serializedName => name.toUpperCase();
  static PlayerStyle fromSerializedName(String? v) =>
      _enumBySerializedName(values, v, PlayerStyle.classic);
}

/// v2.0.10: which bottom dock design is used. (Kotlin: DockStyle)
enum DockStyle {
  classic('Classic'),
  island('Island (liquid glass)'),
  capsule('Orb (floating cover)'),
  edge('Split (two islands)');

  const DockStyle(this.label);
  final String label;
  String get serializedName => name.toUpperCase();
  static DockStyle fromSerializedName(String? v) =>
      _enumBySerializedName(values, v, DockStyle.classic);
}

/// v2.0.12: which Home dashboard design is used. (Kotlin: HomeStyle)
enum HomeStyle {
  classic('Classic'),
  aura('Aura (cards & glass)'),
  bento('Bento (grid tiles)'),
  spotlight('Spotlight (big artwork)');

  const HomeStyle(this.label);
  final String label;
  String get serializedName => name.toUpperCase();
  static HomeStyle fromSerializedName(String? v) =>
      _enumBySerializedName(values, v, HomeStyle.classic);
}

/// v2.0.14: WATER = clear aqua, see-through glass. (Kotlin: GlassStyle)
enum GlassStyle {
  liquid('Liquid (lens)'),
  frosted('Frosted'),
  water('Water (clear)'),
  solid('Solid (no blur)');

  const GlassStyle(this.label);
  final String label;
  String get serializedName => name.toUpperCase();
  static GlassStyle fromSerializedName(String? v) =>
      _enumBySerializedName(values, v, GlassStyle.liquid);
}

/// Kotlin: dsp.FilterType { PEAK, LOW_SHELF, HIGH_SHELF, LOW_PASS, HIGH_PASS }
enum FilterType {
  peak,
  lowShelf,
  highShelf,
  lowPass,
  highPass;

  String get serializedName => switch (this) {
        FilterType.peak => 'PEAK',
        FilterType.lowShelf => 'LOW_SHELF',
        FilterType.highShelf => 'HIGH_SHELF',
        FilterType.lowPass => 'LOW_PASS',
        FilterType.highPass => 'HIGH_PASS',
      };

  static FilterType fromSerializedName(String? v) => values.firstWhere(
      (e) => e.serializedName == v,
      orElse: () => FilterType.peak);
}

/// Kotlin: dsp.EnhanceLevel { OFF, LIGHT, STRONG } (bandwidth extension level)
enum EnhanceLevel {
  off,
  light,
  strong;

  String get serializedName => name.toUpperCase();
  static EnhanceLevel fromSerializedName(String? v) =>
      _enumBySerializedName(values, v, EnhanceLevel.off);
}

/// (Kotlin: ParamBandSetting)
class ParamBandSetting {
  const ParamBandSetting({
    required this.type,
    required this.freqHz,
    required this.gainDb,
    required this.q,
    this.enabled = true,
  });

  final FilterType type;
  final double freqHz;
  final double gainDb;
  final double q;
  final bool enabled;

  ParamBandSetting copyWith({
    FilterType? type,
    double? freqHz,
    double? gainDb,
    double? q,
    bool? enabled,
  }) =>
      ParamBandSetting(
        type: type ?? this.type,
        freqHz: freqHz ?? this.freqHz,
        gainDb: gainDb ?? this.gainDb,
        q: q ?? this.q,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.serializedName,
        'freqHz': freqHz,
        'gainDb': gainDb,
        'q': q,
        'enabled': enabled,
      };

  factory ParamBandSetting.fromJson(Map<String, dynamic> json) =>
      ParamBandSetting(
        type: FilterType.fromSerializedName(json['type'] as String?),
        freqHz: (json['freqHz'] as num).toDouble(),
        gainDb: (json['gainDb'] as num).toDouble(),
        q: (json['q'] as num).toDouble(),
        enabled: json['enabled'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      other is ParamBandSetting &&
      other.type == type &&
      other.freqHz == freqHz &&
      other.gainDb == gainDb &&
      other.q == q &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(type, freqHz, gainDb, q, enabled);
}

/// (Kotlin: EqSetting) — persisted form of the EQ configuration.
/// The original's toConfig() (→ dsp EqConfig) is not ported: it belongs
/// to the DSP layer, which is outside this assignment.
class EqSetting {
  const EqSetting({
    this.enabled = true,
    this.bypassB = false,
    this.graphic = const [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    this.parametric = defaultParams,
    this.parametricOn = false,
    this.preampDb = 0.0,
    this.autoHeadroom = true,
    this.bassBoostDb = 0.0,
    this.widen = 0.0,
    this.limiter = true,
    this.preset = 'Flat',
  });

  final bool enabled;

  /// Kotlin: bypassB — A/B bypass flag ("B" side).
  final bool bypassB;
  final List<double> graphic;
  final List<ParamBandSetting> parametric;
  final bool parametricOn;
  final double preampDb;
  final bool autoHeadroom;
  final double bassBoostDb;
  final double widen;
  final bool limiter;
  final String preset;

  /// Kotlin: EqSetting.DEFAULT_PARAMS
  static const List<ParamBandSetting> defaultParams = [
    ParamBandSetting(
        type: FilterType.highPass, freqHz: 25.0, gainDb: 0.0, q: 0.71, enabled: false),
    ParamBandSetting(type: FilterType.lowShelf, freqHz: 105.0, gainDb: 0.0, q: 0.71),
    ParamBandSetting(type: FilterType.peak, freqHz: 350.0, gainDb: 0.0, q: 1.4),
    ParamBandSetting(type: FilterType.peak, freqHz: 2500.0, gainDb: 0.0, q: 1.4),
    ParamBandSetting(type: FilterType.highShelf, freqHz: 10000.0, gainDb: 0.0, q: 0.71),
    ParamBandSetting(
        type: FilterType.lowPass, freqHz: 20000.0, gainDb: 0.0, q: 0.71, enabled: false),
  ];

  EqSetting copyWith({
    bool? enabled,
    bool? bypassB,
    List<double>? graphic,
    List<ParamBandSetting>? parametric,
    bool? parametricOn,
    double? preampDb,
    bool? autoHeadroom,
    double? bassBoostDb,
    double? widen,
    bool? limiter,
    String? preset,
  }) =>
      EqSetting(
        enabled: enabled ?? this.enabled,
        bypassB: bypassB ?? this.bypassB,
        graphic: graphic ?? this.graphic,
        parametric: parametric ?? this.parametric,
        parametricOn: parametricOn ?? this.parametricOn,
        preampDb: preampDb ?? this.preampDb,
        autoHeadroom: autoHeadroom ?? this.autoHeadroom,
        bassBoostDb: bassBoostDb ?? this.bassBoostDb,
        widen: widen ?? this.widen,
        limiter: limiter ?? this.limiter,
        preset: preset ?? this.preset,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'bypassB': bypassB,
        'graphic': graphic,
        'parametric': parametric.map((p) => p.toJson()).toList(),
        'parametricOn': parametricOn,
        'preampDb': preampDb,
        'autoHeadroom': autoHeadroom,
        'bassBoostDb': bassBoostDb,
        'widen': widen,
        'limiter': limiter,
        'preset': preset,
      };

  factory EqSetting.fromJson(Map<String, dynamic> json) => EqSetting(
        enabled: json['enabled'] as bool? ?? true,
        bypassB: json['bypassB'] as bool? ?? false,
        graphic: json['graphic'] is List
            ? (json['graphic'] as List)
                .map((e) => (e as num).toDouble())
                .toList()
            : const [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        parametric: json['parametric'] is List
            ? (json['parametric'] as List)
                .map((e) => ParamBandSetting.fromJson(e as Map<String, dynamic>))
                .toList()
            : defaultParams,
        parametricOn: json['parametricOn'] as bool? ?? false,
        preampDb: (json['preampDb'] as num?)?.toDouble() ?? 0.0,
        autoHeadroom: json['autoHeadroom'] as bool? ?? true,
        bassBoostDb: (json['bassBoostDb'] as num?)?.toDouble() ?? 0.0,
        widen: (json['widen'] as num?)?.toDouble() ?? 0.0,
        limiter: json['limiter'] as bool? ?? true,
        preset: json['preset'] as String? ?? 'Flat',
      );

  @override
  bool operator ==(Object other) =>
      other is EqSetting &&
      other.enabled == enabled &&
      other.bypassB == bypassB &&
      other.parametricOn == parametricOn &&
      other.preampDb == preampDb &&
      other.autoHeadroom == autoHeadroom &&
      other.bassBoostDb == bassBoostDb &&
      other.widen == widen &&
      other.limiter == limiter &&
      other.preset == preset &&
      _doubleListsEqual(other.graphic, graphic) &&
      _bandListsEqual(other.parametric, parametric);

  @override
  int get hashCode => Object.hash(
      enabled,
      bypassB,
      parametricOn,
      preampDb,
      autoHeadroom,
      bassBoostDb,
      widen,
      limiter,
      preset,
      Object.hashAll(graphic),
      Object.hashAll(parametric));
}

bool _doubleListsEqual(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _bandListsEqual(List<ParamBandSetting> a, List<ParamBandSetting> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// (Kotlin: AppSettings) — field names and defaults match the original.
class AppSettings {
  const AppSettings({
    this.onboarded = false,
    this.guest = true,
    this.quality = Quality.auto,
    this.mobileQuality = Quality.high,
    this.downloadQuality = Quality.max,
    this.sourcePriority = defaultPriority,
    this.enabledSources = const {SourceKind.youtube, SourceKind.jiosaavn},
    this.jamendoClientId,
    this.lyricsOrder = const ['lrclib', 'lyricsplus', 'kugou', 'netease', 'ytmusic'],
    this.lyricsEnabled = const {'lrclib', 'lyricsplus', 'kugou', 'netease', 'ytmusic'},
    this.lyricsOffsetMs = 0,
    this.romanize = false,
    this.crossfadeSec = 0,
    this.gapless = true,
    this.sleepDefaultMin = 30,
    this.autoplay = true,
    this.sleepFade = true,
    this.sleepFinishSong = false,
    this.cacheLimitMb = 1024,
    this.wifiOnlyDownloads = false,
    this.glass = GlassStyle.liquid,
    this.reduceMotion = false,
    this.hideNavOnScroll = true,
    this.navBarMode,
    this.dynamicColor = true,
    this.playerStyle = PlayerStyle.classic,
    this.dockStyle = DockStyle.classic,
    this.homeStyle = HomeStyle.classic,
    this.themeMode = ThemeMode.dark,
    this.haptics = true,
    this.pureHiRes = false,
    this.bitPerfectUsb = false,
    this.eq = const EqSetting(),
    this.upscaleRate = 0,
    this.bwe = EnhanceLevel.off,
    this.transientRestore = false,
    this.region,
    this.recentSearches = const [],
    this.setupDone = false,
    this.autoUpdateCheck = true,
    this.skippedUpdate,
  });

  final bool onboarded;
  final bool guest;
  final Quality quality;

  /// Used instead of [quality] while the active network is metered
  /// (mobile data / metered hotspot).
  final Quality mobileQuality;
  final Quality downloadQuality;
  final List<SourceKind> sourcePriority;
  final Set<SourceKind> enabledSources;
  final String? jamendoClientId;
  final List<String> lyricsOrder;
  final Set<String> lyricsEnabled;
  final int lyricsOffsetMs;
  final bool romanize;
  final int crossfadeSec;

  /// Gapless playback. While on, crossfade is not applied.
  final bool gapless;

  /// Duration offered first in the sleep timer.
  final int sleepDefaultMin;
  final bool autoplay;
  final bool sleepFade;
  final bool sleepFinishSong;
  final int cacheLimitMb;
  final bool wifiOnlyDownloads;
  final GlassStyle glass;
  final bool reduceMotion;

  /// v2.0.3: phones only — bottom nav pill slides away while scrolling.
  final bool hideNavOnScroll;

  /// v2.0.6: replaces [hideNavOnScroll]; null = not chosen yet
  /// (read through [navMode]).
  final NavBarMode? navBarMode;
  final bool dynamicColor;
  final PlayerStyle playerStyle;
  final DockStyle dockStyle;
  final HomeStyle homeStyle;

  /// v2.0.2: System / Dark / Light / Pure black (AMOLED).
  final ThemeMode themeMode;
  final bool haptics;

  /// Float output path for hi-res sources (24-bit/96k+).
  final bool pureHiRes;

  /// Android 14+: bit-perfect mixer behaviour on a USB DAC.
  final bool bitPerfectUsb;
  final EqSetting eq;

  /// Upscale target sample rate; 0 = keep source rate.
  final int upscaleRate;

  /// Bandwidth extension level.
  final EnhanceLevel bwe;
  final bool transientRestore;
  final String? region;
  final List<String> recentSearches;

  /// v2.0.15: first-time design setup finished or skipped.
  final bool setupDone;

  /// 1.0.0: look for a newer GitHub release on app start.
  final bool autoUpdateCheck;

  /// 1.0.0: release version the user chose "Skip this version" for.
  final String? skippedUpdate;

  /// The quality the router should aim for right now.
  Quality effectiveQuality(bool metered) => metered ? mobileQuality : quality;

  /// v2.0.6 dock behaviour; before the choice existed, "hide on scroll"
  /// off meant always visible, on → Mini.
  NavBarMode get navMode =>
      navBarMode ?? (hideNavOnScroll ? NavBarMode.mini : NavBarMode.always);

  /// Kotlin: AppSettings.DEFAULT_PRIORITY (SPOTIFY deliberately absent).
  static const List<SourceKind> defaultPriority = [
    SourceKind.local,
    SourceKind.subsonic,
    SourceKind.jellyfin,
    SourceKind.youtube,
    SourceKind.jiosaavn,
    SourceKind.audius,
    SourceKind.jamendo,
    SourceKind.archive,
    SourceKind.soundcloud,
  ];

  AppSettings copyWith({
    bool? onboarded,
    bool? guest,
    Quality? quality,
    Quality? mobileQuality,
    Quality? downloadQuality,
    List<SourceKind>? sourcePriority,
    Set<SourceKind>? enabledSources,
    Object? jamendoClientId = _unset,
    List<String>? lyricsOrder,
    Set<String>? lyricsEnabled,
    int? lyricsOffsetMs,
    bool? romanize,
    int? crossfadeSec,
    bool? gapless,
    int? sleepDefaultMin,
    bool? autoplay,
    bool? sleepFade,
    bool? sleepFinishSong,
    int? cacheLimitMb,
    bool? wifiOnlyDownloads,
    GlassStyle? glass,
    bool? reduceMotion,
    bool? hideNavOnScroll,
    Object? navBarMode = _unset,
    bool? dynamicColor,
    PlayerStyle? playerStyle,
    DockStyle? dockStyle,
    HomeStyle? homeStyle,
    ThemeMode? themeMode,
    bool? haptics,
    bool? pureHiRes,
    bool? bitPerfectUsb,
    EqSetting? eq,
    int? upscaleRate,
    EnhanceLevel? bwe,
    bool? transientRestore,
    Object? region = _unset,
    List<String>? recentSearches,
    bool? setupDone,
    bool? autoUpdateCheck,
    Object? skippedUpdate = _unset,
  }) =>
      AppSettings(
        onboarded: onboarded ?? this.onboarded,
        guest: guest ?? this.guest,
        quality: quality ?? this.quality,
        mobileQuality: mobileQuality ?? this.mobileQuality,
        downloadQuality: downloadQuality ?? this.downloadQuality,
        sourcePriority: sourcePriority ?? this.sourcePriority,
        enabledSources: enabledSources ?? this.enabledSources,
        jamendoClientId: identical(jamendoClientId, _unset)
            ? this.jamendoClientId
            : jamendoClientId as String?,
        lyricsOrder: lyricsOrder ?? this.lyricsOrder,
        lyricsEnabled: lyricsEnabled ?? this.lyricsEnabled,
        lyricsOffsetMs: lyricsOffsetMs ?? this.lyricsOffsetMs,
        romanize: romanize ?? this.romanize,
        crossfadeSec: crossfadeSec ?? this.crossfadeSec,
        gapless: gapless ?? this.gapless,
        sleepDefaultMin: sleepDefaultMin ?? this.sleepDefaultMin,
        autoplay: autoplay ?? this.autoplay,
        sleepFade: sleepFade ?? this.sleepFade,
        sleepFinishSong: sleepFinishSong ?? this.sleepFinishSong,
        cacheLimitMb: cacheLimitMb ?? this.cacheLimitMb,
        wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
        glass: glass ?? this.glass,
        reduceMotion: reduceMotion ?? this.reduceMotion,
        hideNavOnScroll: hideNavOnScroll ?? this.hideNavOnScroll,
        navBarMode:
            identical(navBarMode, _unset) ? this.navBarMode : navBarMode as NavBarMode?,
        dynamicColor: dynamicColor ?? this.dynamicColor,
        playerStyle: playerStyle ?? this.playerStyle,
        dockStyle: dockStyle ?? this.dockStyle,
        homeStyle: homeStyle ?? this.homeStyle,
        themeMode: themeMode ?? this.themeMode,
        haptics: haptics ?? this.haptics,
        pureHiRes: pureHiRes ?? this.pureHiRes,
        bitPerfectUsb: bitPerfectUsb ?? this.bitPerfectUsb,
        eq: eq ?? this.eq,
        upscaleRate: upscaleRate ?? this.upscaleRate,
        bwe: bwe ?? this.bwe,
        transientRestore: transientRestore ?? this.transientRestore,
        region: identical(region, _unset) ? this.region : region as String?,
        recentSearches: recentSearches ?? this.recentSearches,
        setupDone: setupDone ?? this.setupDone,
        autoUpdateCheck: autoUpdateCheck ?? this.autoUpdateCheck,
        skippedUpdate: identical(skippedUpdate, _unset)
            ? this.skippedUpdate
            : skippedUpdate as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'onboarded': onboarded,
        'guest': guest,
        'quality': quality.serializedName,
        'mobileQuality': mobileQuality.serializedName,
        'downloadQuality': downloadQuality.serializedName,
        'sourcePriority': sourcePriority.map((s) => s.serializedName).toList(),
        'enabledSources': enabledSources.map((s) => s.serializedName).toList(),
        if (jamendoClientId != null) 'jamendoClientId': jamendoClientId,
        'lyricsOrder': lyricsOrder,
        'lyricsEnabled': lyricsEnabled.toList(),
        'lyricsOffsetMs': lyricsOffsetMs,
        'romanize': romanize,
        'crossfadeSec': crossfadeSec,
        'gapless': gapless,
        'sleepDefaultMin': sleepDefaultMin,
        'autoplay': autoplay,
        'sleepFade': sleepFade,
        'sleepFinishSong': sleepFinishSong,
        'cacheLimitMb': cacheLimitMb,
        'wifiOnlyDownloads': wifiOnlyDownloads,
        'glass': glass.serializedName,
        'reduceMotion': reduceMotion,
        'hideNavOnScroll': hideNavOnScroll,
        if (navBarMode != null) 'navBarMode': navBarMode!.serializedName,
        'dynamicColor': dynamicColor,
        'playerStyle': playerStyle.serializedName,
        'dockStyle': dockStyle.serializedName,
        'homeStyle': homeStyle.serializedName,
        'themeMode': themeMode.serializedName,
        'haptics': haptics,
        'pureHiRes': pureHiRes,
        'bitPerfectUsb': bitPerfectUsb,
        'eq': eq.toJson(),
        'upscaleRate': upscaleRate,
        'bwe': bwe.serializedName,
        'transientRestore': transientRestore,
        if (region != null) 'region': region,
        'recentSearches': recentSearches,
        'setupDone': setupDone,
        'autoUpdateCheck': autoUpdateCheck,
        if (skippedUpdate != null) 'skippedUpdate': skippedUpdate,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    List<SourceKind> kinds(Object? v, List<SourceKind> fallback) {
      if (v is! List) return fallback;
      return v.map((e) => SourceKind.fromSerializedName(e as String?)).toList();
    }

    List<String> strings(Object? v, List<String> fallback) =>
        v is List ? v.map((e) => e as String).toList() : fallback;

    return AppSettings(
      onboarded: json['onboarded'] as bool? ?? false,
      guest: json['guest'] as bool? ?? true,
      quality: Quality.fromSerializedName(json['quality'] as String?),
      mobileQuality:
          Quality.fromSerializedName(json['mobileQuality'] as String?, Quality.high),
      downloadQuality:
          Quality.fromSerializedName(json['downloadQuality'] as String?, Quality.max),
      sourcePriority: kinds(json['sourcePriority'], defaultPriority),
      enabledSources:
          kinds(json['enabledSources'], const [SourceKind.youtube, SourceKind.jiosaavn])
              .toSet(),
      jamendoClientId: json['jamendoClientId'] as String?,
      lyricsOrder: strings(json['lyricsOrder'],
          const ['lrclib', 'lyricsplus', 'kugou', 'netease', 'ytmusic']),
      lyricsEnabled: strings(json['lyricsEnabled'],
              const ['lrclib', 'lyricsplus', 'kugou', 'netease', 'ytmusic'])
          .toSet(),
      lyricsOffsetMs: (json['lyricsOffsetMs'] as num?)?.toInt() ?? 0,
      romanize: json['romanize'] as bool? ?? false,
      crossfadeSec: (json['crossfadeSec'] as num?)?.toInt() ?? 0,
      gapless: json['gapless'] as bool? ?? true,
      sleepDefaultMin: (json['sleepDefaultMin'] as num?)?.toInt() ?? 30,
      autoplay: json['autoplay'] as bool? ?? true,
      sleepFade: json['sleepFade'] as bool? ?? true,
      sleepFinishSong: json['sleepFinishSong'] as bool? ?? false,
      cacheLimitMb: (json['cacheLimitMb'] as num?)?.toInt() ?? 1024,
      wifiOnlyDownloads: json['wifiOnlyDownloads'] as bool? ?? false,
      glass: GlassStyle.fromSerializedName(json['glass'] as String?),
      reduceMotion: json['reduceMotion'] as bool? ?? false,
      hideNavOnScroll: json['hideNavOnScroll'] as bool? ?? true,
      navBarMode: json['navBarMode'] == null
          ? null
          : NavBarMode.fromSerializedName(json['navBarMode'] as String?),
      dynamicColor: json['dynamicColor'] as bool? ?? true,
      playerStyle: PlayerStyle.fromSerializedName(json['playerStyle'] as String?),
      dockStyle: DockStyle.fromSerializedName(json['dockStyle'] as String?),
      homeStyle: HomeStyle.fromSerializedName(json['homeStyle'] as String?),
      themeMode: ThemeMode.fromSerializedName(json['themeMode'] as String?),
      haptics: json['haptics'] as bool? ?? true,
      pureHiRes: json['pureHiRes'] as bool? ?? false,
      bitPerfectUsb: json['bitPerfectUsb'] as bool? ?? false,
      eq: json['eq'] is Map<String, dynamic>
          ? EqSetting.fromJson(json['eq'] as Map<String, dynamic>)
          : const EqSetting(),
      upscaleRate: (json['upscaleRate'] as num?)?.toInt() ?? 0,
      bwe: EnhanceLevel.fromSerializedName(json['bwe'] as String?),
      transientRestore: json['transientRestore'] as bool? ?? false,
      region: json['region'] as String?,
      recentSearches: strings(json['recentSearches'], const []),
      setupDone: json['setupDone'] as bool? ?? false,
      autoUpdateCheck: json['autoUpdateCheck'] as bool? ?? true,
      skippedUpdate: json['skippedUpdate'] as String?,
    );
  }
}

/// (Kotlin: SettingsRepo) — key-value style access over [AppSettings]:
/// read/write individual settings by the same names as the Kotlin fields,
/// with whole-object [value]/[update] for the rest.
class SettingsStore {
  SettingsStore(String dirPath) : _file = File('$dirPath/settings.json');

  final File _file;
  AppSettings _value = const AppSettings();
  final List<void Function()> _listeners = [];
  Timer? _saveTimer;

  AppSettings get value => _value;

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          final s = AppSettings.fromJson(decoded);
          // Kotlin load(): sources added in later versions join the
          // priority list at the end; SPOTIFY is never in it.
          final seen = <SourceKind>{};
          final prio = <SourceKind>[
            for (final k in [...s.sourcePriority, ...AppSettings.defaultPriority])
              if (k != SourceKind.spotify && seen.add(k)) k,
          ];
          _value = s.copyWith(sourcePriority: prio);
        }
      }
    } catch (_) {}
  }

  void update(AppSettings Function(AppSettings) f) {
    _value = f(_value);
    for (final l in List.of(_listeners)) {
      l();
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _flush);
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_value.toJson()));
    } catch (_) {}
  }

  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _flush();
    }
  }

  // --- key-value access (names match the Kotlin fields) ---

  T get<T>(String key) {
    final v = _value.toJson()[key];
    if (v == null) throw ArgumentError('Unknown or null setting: $key');
    return v as T;
  }

  bool has(String key) => _value.toJson().containsKey(key);

  /// Set one setting by name. Enum values are their serialized names
  /// ("AUTO", "YOUTUBE", ...), matching the on-disk JSON.
  void set(String key, Object? newValue) {
    final json = _value.toJson();
    if (!json.containsKey(key) && newValue != null) {
      // Allow setting nullable fields that are currently null/absent.
      const nullableKeys = {
        'jamendoClientId',
        'navBarMode',
        'region',
        'skippedUpdate',
      };
      if (!nullableKeys.contains(key)) {
        throw ArgumentError('Unknown setting: $key');
      }
    }
    json[key] = newValue;
    update((_) => AppSettings.fromJson(json));
  }
}
