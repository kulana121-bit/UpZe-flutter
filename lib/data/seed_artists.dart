// Port of data/SeedArtists.kt — the DATA half (UpZe v1.0.1,
// com.ravi.musicspot.data).
//
// What the Kotlin actually contains, ported faithfully:
//  * the SeedArtist record (an artist picked in the optional first-run
//    artist picker; id is the catalogue id "yt:UC…"),
//  * the picker's fallback list of popular artist names (popularQueries),
//  * the pure mixing half of SeedArtists.songsFor(): per-artist lists are
//    shuffled, capped per artist, round-robin mixed, then deduped by id
//    and by Taste.key (title+artist) and capped at the limit.
//
// What is NOT here, deliberately: the network half of the Kotlin object —
// suggested() (YT Music charts + artist searches), search() and the
// per-artist top-song fetching in songsFor() all run through the app-wide
// Graph (YouTube browse/search, JioSaavn). In this port those tracks are
// produced by callers and handed in (HomeFeedRepo takes a `seedTracks`
// callback; the picker UI drives Innertube search). Selection persistence
// also moved: the Kotlin writes seed-artists.json itself, here the picked
// ids live in AccountsStore.seedArtistIds.
//
// NOTE on the brief's "ids/names/genres": the Kotlin has NO static artist
// catalogue with ids or genres anywhere — artists are discovered live from
// YT Music charts/search, and the only baked-in list is the 12 names in
// popularQueries below, ported verbatim. Nothing was invented to fill in
// ids/genres the original does not have.

import 'dart:math' as math;

import '../models/track.dart';

/// An artist the user picked in the optional artist picker.
/// (Kotlin: SeedArtist — id is the catalogue id, "yt:UC…".)
class SeedArtist {
  const SeedArtist({required this.id, required this.name, this.thumbnailUrl});

  final String id;
  final String name;
  final String? thumbnailUrl;

  SeedArtist copyWith({String? id, String? name, String? thumbnailUrl}) =>
      SeedArtist(
        id: id ?? this.id,
        name: name ?? this.name,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'thumbnailUrl': thumbnailUrl,
      };

  factory SeedArtist.fromJson(Map<String, dynamic> json) => SeedArtist(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        thumbnailUrl: json['thumbnailUrl'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is SeedArtist &&
      other.id == id &&
      other.name == name &&
      other.thumbnailUrl == thumbnailUrl;

  @override
  int get hashCode => Object.hash(id, name, thumbnailUrl);
}

/// The picker's fallback popular artists, in the Kotlin's exact order
/// (SeedArtists.popularQueries). Used to seed artist searches when charts
/// are unavailable; each name is searched, the artist itself ranks first.
const List<String> seedPopularQueries = [
  'Arijit Singh',
  'Taylor Swift',
  'Shreya Ghoshal',
  'The Weeknd',
  'Diljit Dosanjh',
  'AP Dhillon',
  'Pritam',
  'Ed Sheeran',
  'Badshah',
  'Sidhu Moose Wala',
  'Billie Eilish',
  'Atif Aslam',
];

/// Same-recording key for dedupe (Kotlin: logic/Taste.key): the title with
/// "(…)"/"[…]" segments and a trailing "- Official …" removed, cut at
/// " | ", normalised, plus the first artist.
///
/// Dart's stdlib has no Unicode Normalizer (the lyrics port records the
/// same limit), so normalisation here is lowercase + accent-fold for the
/// common precomposed Latin letters + non-alphanumeric collapse, instead of
/// the Kotlin's NFKC + mark-strip. Keys still agree for the Latin-script
/// titles this is used on.
String tasteKey(Track t) {
  var stripped =
      t.title.replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), ' ').split(' | ').first;
  stripped = stripped.replaceAll(RegExp(r'\s-\s*official.*$', caseSensitive: false), '');
  final artist = t.artist.split(RegExp(r'[,&]| feat\.? | ft\.? ')).first;
  return '${_norm(stripped)}|${_norm(artist)}';
}

const Map<String, String> _accentFold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae',
  'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ñ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'œ': 'oe',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ý': 'y', 'ÿ': 'y', 'ß': 'ss',
};

String _norm(String s) {
  final lower = s.toLowerCase();
  final buf = StringBuffer();
  for (final ch in lower.split('')) {
    buf.write(_accentFold[ch] ?? ch);
  }
  return buf
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// The mixing half of SeedArtists.songsFor(): each artist's list is
/// shuffled and capped at [perArtist] (the Kotlin fetches perArtist*2,
/// shuffles, takes perArtist), the lists are round-robin mixed in a
/// shuffled list order, then deduped by id and [tasteKey] and capped at
/// [limit]. Pass one track list per seed artist, in any order.
List<Track> mixSeedSongs(
  List<List<Track>> perArtistLists, {
  int perArtist = 8,
  int limit = 40,
  math.Random? random,
}) {
  final rnd = random ?? math.Random();
  final lists = [
    for (final l in perArtistLists)
      (List.of(l)..shuffle(rnd)).take(perArtist).toList(),
  ]..shuffle(rnd);
  final mixed = <Track>[];
  var maxLen = 0;
  for (final l in lists) {
    if (l.length > maxLen) maxLen = l.length;
  }
  for (var i = 0; i < maxLen; i++) {
    for (final l in lists) {
      if (i < l.length) mixed.add(l[i]);
    }
  }
  final ids = <String>{};
  final keys = <String>{};
  return mixed
      .where((t) =>
          t.title.isNotEmpty && ids.add(t.id) && keys.add(tasteKey(t)))
      .take(limit)
      .toList();
}
