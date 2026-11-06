// Page-level Innertube parsing for the Flutter port — the half of
// InnertubeParser.kt that lib/yt/innertube.dart did not port:
//   * parseHome / parseHomeContinuation        -> InnertubePages.homeShelves
//   * parseArtistPage                          -> InnertubePages.artistPage
//   * parsePlaylistShelf / parsePlaylistContinuation / collectSongsDeep /
//     parseBrowseHeader / pageCredit           -> InnertubePages.playlistPage
//   * parseWatchQueue                          -> InnertubePages.radioQueue
// plus the YtMusic.kt wrappers around them (home / artist / collection /
// radio) and its ShelfItem -> Track/Collection mapping.
//
// The JSON navigation helpers and the row parser below are DUPLICATED from
// innertube.dart (they are library-private there, so they cannot be
// imported); only the naming is prefixed the same way. parseClockMs and
// upscaleArtwork are public in innertube.dart and are reused, not copied.
//
// Null-safe throughout, like the Kotlin: a response whose shape drifted
// yields empty lists / null fields, never a throw.

import '../models/track.dart';
import 'innertube.dart';

/// An artist page (Kotlin: YtMusic.ArtistInfo over InnertubeParser.ArtistPage).
class ArtistPage {
  /// The page's own name, off its header (null when the header says none).
  final String? name;

  /// The artist as a browsable collection: id `yt:<browseId>`, kind artist,
  /// subtitle = monthly listeners, else the subscriber text.
  final Collection collection;

  /// The "Top songs" shelf's rows (~5, credited by the page — see below).
  final List<Track> topTracks;

  /// Carousels below the top songs (Albums, Singles & EPs, …), already
  /// split into tracks/collections the way Shelf wants them.
  final List<Shelf> shelves;

  /// "About the artist" blurb, where YouTube ships one.
  final String? description;

  /// e.g. "1.2M subscribers" (the bare-count form gains its noun, as in
  /// the Kotlin's subscriberLabel).
  final String? subscriberCount;

  /// e.g. "3.4M monthly listeners".
  final String? monthlyListeners;

  /// Browse id of the playlist holding the artist's full song list (the
  /// "Top songs" shelf's Show-all target), where the page offers one.
  final String? moreSongsId;

  const ArtistPage({
    required this.name,
    required this.collection,
    required this.topTracks,
    required this.shelves,
    this.description,
    this.subscriberCount,
    this.monthlyListeners,
    this.moreSongsId,
  });
}

/// A playlist or album page (Kotlin: YtMusic.CollectionPage over
/// InnertubeParser.parsePlaylistShelf).
class PlaylistPage {
  /// The page as a browsable collection: kind album for an `MPREb…` id,
  /// playlist otherwise; title/subtitle/art off the page header.
  final Collection collection;

  /// The page's own tracks, in page order, continuations followed.
  final List<Track> tracks;

  /// Rows from the page's "Suggestions" shelf (an owned playlist only) —
  /// NOT part of the playlist. Kept separate for the same reason the
  /// Kotlin scopes by `playlistSetVideoId`: a plain walk would read
  /// these as songs the user added.
  final List<Track> suggested;

  /// "About the album" blurb, where YouTube ships one.
  final String? description;

  const PlaylistPage({
    required this.collection,
    required this.tracks,
    required this.suggested,
    this.description,
  });
}

/// Browse-shaped reads over an [Innertube] (Kotlin: the page half of
/// YtMusic + InnertubeParser).
class InnertubePages {
  final Innertube tube;

  InnertubePages(this.tube);

  // ---- Home ---------------------------------------------------------------

  /// The YouTube Music home feed (Kotlin: YtMusic.home — browse id
  /// `FEmusic_home`, parseHome with a parseHomeContinuation fallback,
  /// shelves with nothing playable or browsable dropped).
  Future<List<Shelf>> homeShelves() async {
    final res = await tube.browse('FEmusic_home');
    var shelves = _parseHome(res);
    if (shelves.isEmpty) shelves = _parseHomeDeep(res);
    return _usable(shelves);
  }

  /// The token for the home feed's next page of shelves, read off a
  /// home (or home-continuation) response (Kotlin:
  /// InnertubeParser.sectionListContinuation): on the first page it
  /// hangs off the section list, on later pages off the continuation
  /// envelope. Null once YouTube has nothing more to send. Feed the
  /// result to [homeShelvesMore].
  static String? sectionListContinuation(Map<String, dynamic> response) {
    Map<String, dynamic>? list;
    final tabs = _a(
        _o(_o(response, 'contents'), 'singleColumnBrowseResultsRenderer'),
        'tabs');
    if (tabs != null && tabs.isNotEmpty) {
      list = _o(_o(_o(tabs.first, 'tabRenderer'), 'content'),
          'sectionListRenderer');
    }
    list ??=
        _o(_o(response, 'continuationContents'), 'sectionListContinuation');
    if (list == null) return null;
    final continuations = _a(list, 'continuations');
    if (continuations != null && continuations.isNotEmpty) {
      final token =
          _s(_o(continuations.first, 'nextContinuationData'), 'continuation');
      if (token != null) return token;
    }
    final contents = _a(list, 'contents');
    if (contents == null || contents.isEmpty) return null;
    return _s(
        _o(
            _o(_o(contents.last, 'continuationItemRenderer'),
                'continuationEndpoint'),
            'continuationCommand'),
        'token');
  }

  /// The next page of home shelves off a continuation token
  /// (Kotlin: YtMusic.homeMore over parseHomeContinuation).
  Future<List<Shelf>> homeShelvesMore(String token) async {
    final res = await tube.browseContinuation(token);
    var shelves = _parseHomeDeep(res);
    if (shelves.isEmpty) shelves = _parseHome(res);
    return _usable(shelves);
  }

  static List<Shelf> _usable(List<Shelf> shelves) => shelves
      .where((s) => s.tracks.isNotEmpty || s.collections.isNotEmpty)
      .toList();

  // ---- Artist -------------------------------------------------------------

  /// An artist page (Kotlin: YtMusic.artist over parseArtistPage).
  Future<ArtistPage> artistPage(String browseId) async {
    final res = await tube.browse(browseId);
    final header = res['header'];
    final name = _artistName(header);
    // "Top songs" rows are billed by the page they sit on: the subtitle
    // beside them counts plays where a search row names the artist.
    final credit = _Credits(artistName: name);

    final songs = <Track>[];
    String? moreSongs;
    final shelves = <Shelf>[];
    for (final section in _browseSections(res)) {
      final shelf = _o(section, 'musicShelfRenderer');
      if (shelf != null) {
        for (final row in _a(shelf, 'contents') ?? const []) {
          final song = _parseRow(_o(row, 'musicResponsiveListItemRenderer'),
              fallback: credit);
          if (song != null) songs.add(song.track);
        }
        moreSongs ??= _s(
                _o(
                    _o(_a(_o(shelf, 'title'), 'runs')?.firstOrNull,
                        'navigationEndpoint'),
                    'browseEndpoint'),
                'browseId') ??
            _s(_o(_o(shelf, 'bottomEndpoint'), 'browseEndpoint'), 'browseId');
      }
      final carousel = _o(section, 'musicCarouselShelfRenderer') ??
          _o(section, 'musicImmersiveCarouselShelfRenderer');
      if (carousel != null) {
        final parsed = _artistCarousel(carousel);
        if (parsed != null) shelves.add(parsed);
      }
    }

    final subscribers = _subscriberCount(header);
    final monthly = _monthlyListeners(header);
    return ArtistPage(
      name: name,
      collection: Collection(
        id: 'yt:$browseId',
        kind: CollectionKind.artist,
        title: name ?? '',
        subtitle: monthly ?? subscribers,
        artUrl: upscaleArtwork(_artistThumbnail(header)),
      ),
      topTracks: songs,
      shelves: _usable(shelves),
      description: _parseDescription(res),
      subscriberCount: subscribers,
      monthlyListeners: monthly,
      moreSongsId: moreSongs,
    );
  }

  // ---- Playlist / album -----------------------------------------------------

  /// A playlist or album page (Kotlin: YtMusic.collection — scoped shelf
  /// parse with the deep walk as fallback, continuations followed for up
  /// to [maxPages] extra pages).
  Future<PlaylistPage> playlistPage(String browseId, {int maxPages = 10}) async {
    final res = await tube.browse(browseId);
    final header = _parseBrowseHeader(res);
    final credit = _pageCredit(res);
    final first = _parsePlaylistShelf(res, credit);
    final songs = <Track>[];
    final seen = <String>{};
    void addAll(List<Track> tracks) {
      for (final t in tracks) {
        if (seen.add(t.id)) songs.add(t);
      }
    }

    // Kotlin: page?.songs.takeIf { it.isNotEmpty() } ?: collectSongsDeep.
    final scopedSongs = first?.songs;
    addAll(scopedSongs != null && scopedSongs.isNotEmpty
        ? scopedSongs
        : _collectSongsDeep(res, credit));
    final suggested = first?.suggested ?? const <Track>[];
    var token = first?.continuation;
    var pages = 0;
    while (token != null && pages++ < maxPages) {
      _PlaylistShelfPage next;
      try {
        next = _parsePlaylistContinuation(
            await tube
                .browseContinuation(token)
                .timeout(const Duration(seconds: 12)),
            credit);
      } catch (_) {
        break; // Kotlin: withTimeoutOrNull(...) ?: break
      }
      addAll(next.songs);
      token = next.continuation;
    }

    final kind = browseId.startsWith('MPREb')
        ? CollectionKind.album
        : CollectionKind.playlist;
    final art = upscaleArtwork(header?.thumbnailUrl);
    final tracks = [
      for (final t in songs)
        t
            .copyWith(artUrl: t.artUrl ?? art)
            .copyWith(
              album: kind == CollectionKind.album
                  ? (t.album ?? header?.title)
                  : t.album,
              albumId: kind == CollectionKind.album
                  ? (t.albumId ?? 'yt:$browseId')
                  : t.albumId,
            ),
    ];
    return PlaylistPage(
      collection: Collection(
        id: 'yt:$browseId',
        kind: kind,
        title: header?.title ?? '',
        subtitle: header?.subtitle,
        artUrl: art,
      ),
      tracks: tracks,
      suggested: suggested,
      description: _parseDescription(res),
    );
  }

  // ---- Watch queue / radio --------------------------------------------------

  /// The watch-next queue for [videoId], parsed properly off
  /// `playlistPanelVideoRenderer` (Kotlin: InnertubeParser.parseWatchQueue).
  ///
  /// Unlike YtMusic.radio (and the simplified YtMusic.radio in
  /// innertube.dart), the seed track itself is NOT filtered out: the
  /// queue comes back in panel order, seed first, exactly as served.
  Future<List<Track>> radioQueue(String videoId) async {
    final res = await tube.next(videoId);
    return _parseWatchQueue(res);
  }
}

// ===========================================================================
// Shelf plumbing (Kotlin: HomeShelf + YtMusic's toShelf/toCollection/
// toTrackOrNull/artistFromSubtitle mapping)
// ===========================================================================

/// One shelf card before it is split into a track or a collection
/// (Kotlin: ShelfItem).
class _CardItem {
  final String title;
  final String subtitle;
  final String? artUrl;
  final String? videoId;
  final String? browseId;
  final bool explicit;
  const _CardItem({
    required this.title,
    required this.subtitle,
    this.artUrl,
    this.videoId,
    this.browseId,
    this.explicit = false,
  });
}

/// Kotlin: ShelfItem.toTrackOrNull — the artist is the credit out of the
/// card's subtitle ("Song • Chelsea Wolfe" reads just "Chelsea Wolfe").
Track? _cardToTrack(_CardItem item) {
  final videoId = item.videoId;
  if (videoId == null) return null;
  return Track(
    id: 'yt:$videoId',
    title: item.title,
    artist: _artistFromSubtitle(item.subtitle),
    artUrl: upscaleArtwork(item.artUrl),
    explicit: item.explicit,
  );
}

/// Kotlin: ShelfItem.toCollection — kind read off the browse-id prefix.
Collection? _cardToCollection(_CardItem item) {
  final id = item.browseId;
  if (id == null) return null;
  final kind = (id.startsWith('UC') || id.startsWith('MPLAUC'))
      ? CollectionKind.artist
      : id.startsWith('MPREb')
          ? CollectionKind.album
          : CollectionKind.playlist;
  return Collection(
    id: 'yt:$id',
    kind: kind,
    title: item.title,
    subtitle: item.subtitle,
    artUrl: upscaleArtwork(item.artUrl),
  );
}

/// Kotlin: HomeShelf.toShelf.
Shelf _shelfFrom(
  String title,
  List<_CardItem> items, {
  String? subtitle,
  String? moreBrowseId,
}) {
  return Shelf(
    title: title,
    tracks: items.map(_cardToTrack).whereType<Track>().toList(),
    collections: items
        .where((i) => i.videoId == null)
        .map(_cardToCollection)
        .whereType<Collection>()
        .toList(),
    subtitle: (subtitle == null || subtitle.isEmpty) ? null : subtitle,
    moreId: moreBrowseId == null ? null : 'yt:$moreBrowseId',
  );
}

/// Kotlin: InnertubeParser.artistFromSubtitle.
String _artistFromSubtitle(String subtitle) {
  final parts = subtitle
      .split(' • ')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty);
  for (final part in parts) {
    if (!_typeWords.contains(part.toLowerCase()) &&
        !_tallyRe.hasMatch(part) &&
        !_durationRe.hasMatch(part)) {
      return part;
    }
  }
  return '';
}

// ===========================================================================
// Home (Kotlin: parseHome / parseHomeContinuation / carouselShelf /
// plainShelf)
// ===========================================================================

/// The sections of a single-column browse response, off the fixed path
/// the Kotlin reads (empty when the layout isn't that shape).
List<dynamic> _browseSections(Map<String, dynamic> response) {
  final tabs = _a(
      _o(_o(response, 'contents'), 'singleColumnBrowseResultsRenderer'),
      'tabs');
  if (tabs == null || tabs.isEmpty) return const [];
  return _a(
          _o(_o(_o(tabs.first, 'tabRenderer'), 'content'),
              'sectionListRenderer'),
          'contents') ??
      const [];
}

List<Shelf> _parseHome(Map<String, dynamic> response) {
  final out = <Shelf>[];
  for (final section in _browseSections(response)) {
    final carousel = _o(section, 'musicCarouselShelfRenderer') ??
        _o(section, 'musicImmersiveCarouselShelfRenderer');
    if (carousel != null) {
      final shelf = _carouselShelf(carousel);
      if (shelf != null) out.add(shelf);
      continue;
    }
    final plain = _o(section, 'musicShelfRenderer');
    if (plain != null) {
      final shelf = _plainShelf(plain);
      if (shelf != null) out.add(shelf);
    }
  }
  return out;
}

/// Continuation envelopes don't repeat the tabs/section-list wrapper, so
/// the shelves are walked out wherever they land (Kotlin:
/// parseHomeContinuation). Carousel renderers are matched before plain
/// shelves at each node, and a node is never descended into twice for the
/// same shelf.
List<Shelf> _parseHomeDeep(dynamic root) {
  final out = <Shelf>[];
  void walk(dynamic node) {
    if (node is Map) {
      final carousel = _o(node, 'musicCarouselShelfRenderer') ??
          _o(node, 'musicImmersiveCarouselShelfRenderer');
      if (carousel != null) {
        final shelf = _carouselShelf(carousel);
        if (shelf != null) out.add(shelf);
      }
      final plain = _o(node, 'musicShelfRenderer');
      if (plain != null) {
        final shelf = _plainShelf(plain);
        if (shelf != null) out.add(shelf);
      }
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(root);
  return out;
}

Shelf? _carouselShelf(Map<String, dynamic> carousel) {
  final header = _o(_o(carousel, 'header'),
      'musicCarouselShelfBasicHeaderRenderer');
  final title = _runs(_o(header, 'title'));
  final strapline = _runs(_o(header, 'strapline'));
  // Whole shelves like "Video charts" carry nothing but video
  // compilations — dropped outright, as in the Kotlin.
  if (_videoWordRe.hasMatch(title)) return null;
  final items = <_CardItem>[];
  for (final item in _a(carousel, 'contents') ?? const []) {
    final twoRow = _parseTwoRowItem(_o(item, 'musicTwoRowItemRenderer'));
    if (twoRow != null) {
      items.add(twoRow);
      continue;
    }
    final row = _o(item, 'musicResponsiveListItemRenderer');
    final song = _parseRow(row);
    if (song != null && !song.isVideo) {
      items.add(_CardItem(
        title: song.track.title,
        subtitle: song.track.artist,
        artUrl: song.track.artUrl,
        videoId: song.track.nativeId,
        explicit: song.track.explicit,
      ));
      continue;
    }
    // A chart row with nothing to play — "Top artists" names the artist
    // alone — falls through the row parser and is read as an artist card.
    final artistRow = _parseArtistRow(row);
    if (artistRow != null) items.add(artistRow);
  }
  if (items.isEmpty) return null;
  return _shelfFrom(title.isEmpty ? 'For you' : title, items,
      subtitle: strapline);
}

Shelf? _plainShelf(Map<String, dynamic> shelf) {
  final title = _runs(_o(shelf, 'title'));
  if (_videoWordRe.hasMatch(title)) return null;
  final items = <_CardItem>[];
  for (final item in _a(shelf, 'contents') ?? const []) {
    final song = _parseRow(_o(item, 'musicResponsiveListItemRenderer'));
    if (song != null && !song.isVideo) {
      items.add(_CardItem(
        title: song.track.title,
        subtitle: song.track.artist,
        artUrl: song.track.artUrl,
        videoId: song.track.nativeId,
        explicit: song.track.explicit,
      ));
    }
  }
  if (items.isEmpty) return null;
  return _shelfFrom(title.isEmpty ? 'For you' : title, items);
}

/// An artist page's carousel (Kotlin: the carousel half of
/// parseArtistPage): two-row cards only, cards without a browse target
/// dropped at parse time, and the header's Show-all endpoint kept.
Shelf? _artistCarousel(Map<String, dynamic> carousel) {
  final header = _o(_o(carousel, 'header'),
      'musicCarouselShelfBasicHeaderRenderer');
  final title = _runs(_o(header, 'title'));
  if (_videoWordRe.hasMatch(title)) return null;
  final items = <_CardItem>[];
  for (final item in _a(carousel, 'contents') ?? const []) {
    final parsed = _parseTwoRowItem(_o(item, 'musicTwoRowItemRenderer'));
    if (parsed != null && parsed.browseId != null) items.add(parsed);
  }
  if (title.isEmpty || items.isEmpty) return null;
  return _shelfFrom(title, items, moreBrowseId: _moreBrowseId(header));
}

/// The carousel header's "Show all" browse id, wherever this layout put
/// it (Kotlin: parseArtistPage's moreEndpoint chain; the params half of
/// that endpoint has no home in Dart's Shelf and is dropped — see the
/// report note).
String? _moreBrowseId(Map<String, dynamic>? header) {
  if (header == null) return null;
  for (final run in _a(_o(header, 'title'), 'runs') ?? const []) {
    final id = _s(_o(_o(run, 'navigationEndpoint'), 'browseEndpoint'),
        'browseId');
    if (id != null) return id;
  }
  final candidates = <Map<String, dynamic>?>[
    _o(_o(header, 'moreContentButton'), 'buttonRenderer'),
    _o(_o(header, 'moreContentButton'), 'musicMoreContentButtonRenderer'),
    header,
  ];
  for (final c in candidates) {
    final id =
        _s(_o(_o(c, 'navigationEndpoint'), 'browseEndpoint'), 'browseId');
    if (id != null) return id;
  }
  for (final icon in _a(header, 'endIcons') ?? const []) {
    final button = _o(icon, 'musicNavigationButtonRenderer');
    final id = _s(
            _o(_o(button, 'clickCommand'), 'browseEndpoint'), 'browseId') ??
        _s(_o(_o(button, 'navigationEndpoint'), 'browseEndpoint'),
            'browseId');
    if (id != null) return id;
  }
  return null;
}

// ===========================================================================
// Artist header (Kotlin: artistName / artistThumbnail / subscriberCount /
// monthlyListeners / parseDescription)
// ===========================================================================

Map<String, dynamic>? _immersiveHeader(dynamic header) =>
    _o(header, 'musicImmersiveHeaderRenderer');

String? _artistName(dynamic header) {
  final renderer = _immersiveHeader(header) ??
      _o(header, 'musicVisualHeaderRenderer');
  final name = _runs(_o(renderer, 'title'));
  return name.isEmpty ? null : name;
}

String? _artistThumbnail(dynamic header) {
  if (header == null) return null;
  final immersive = _immersiveHeader(header);
  final visual = _o(header, 'musicVisualHeaderRenderer');
  var renderer = _o(
      _o(immersive, 'thumbnail') ??
          _o(visual, 'foregroundThumbnail') ??
          _o(visual, 'thumbnail'),
      'musicThumbnailRenderer');
  // Header shapes drift; fall back to the first image anywhere under the
  // header rather than to the caller's album art.
  renderer ??= _collectRenderers(header, 'musicThumbnailRenderer')
      .firstOrNull;
  return _bestThumb(_a(_o(renderer, 'thumbnail'), 'thumbnails'));
}

String? _firstRunText(dynamic v) {
  final runs = _a(v, 'runs');
  if (runs == null || runs.isEmpty) return null;
  return _s(runs.first, 'text');
}

final RegExp _bareCountRe =
    RegExp(r'^[\d.,]+\s*[KMB]?$', caseSensitive: false);

String? _subscriberCount(dynamic header) {
  final immersive = _immersiveHeader(header);
  if (immersive == null) return null;
  final button2 =
      _o(_o(immersive, 'subscriptionButton2'), 'subscribeButtonRenderer');
  final button1 =
      _o(_o(immersive, 'subscriptionButton'), 'subscribeButtonRenderer');
  final raw = _firstRunText(_o(button2, 'subscriberCountWithSubscribeText')) ??
      _firstRunText(_o(button1, 'longSubscriberCountText')) ??
      _firstRunText(_o(button1, 'subscriberCountWithSubscribeText')) ??
      _firstRunText(_o(button1, 'subscriberCountText')) ??
      _firstRunText(_o(button1, 'shortSubscriberCountText'));
  final count = raw?.trim();
  if (count == null || count.isEmpty) return null;
  // The current button prints the number alone ("109K") because the word
  // "Subscribe" sits beside it; give it its noun back.
  return _bareCountRe.hasMatch(count) ? '$count subscribers' : count;
}

String? _monthlyListeners(dynamic header) =>
    _firstRunText(_o(_immersiveHeader(header), 'monthlyListenerCount'));

/// The editorial blurb for a release or an artist (Kotlin:
/// parseDescription): its own shelf on current layouts, a header field
/// on others.
String? _parseDescription(dynamic root) {
  final shelves = _collectRenderers(root, 'musicDescriptionShelfRenderer');
  if (shelves.isNotEmpty) {
    final text = _runs(_o(shelves.first, 'description'));
    if (text.isNotEmpty) return text;
  }
  for (final name in const [
    'musicResponsiveHeaderRenderer',
    'musicDetailHeaderRenderer',
    'musicImmersiveHeaderRenderer',
  ]) {
    for (final header in _collectRenderers(root, name)) {
      final text = _runs(_o(header, 'description'));
      if (text.isNotEmpty) return text;
    }
  }
  return null;
}

// ===========================================================================
// Playlist / album (Kotlin: parsePlaylistShelf / parsePlaylistContinuation
// / collectSongsDeep / parseBrowseHeader / pageCredit)
// ===========================================================================

class _BrowseHeader {
  final String title;
  final String subtitle;
  final String? thumbnailUrl;
  const _BrowseHeader(this.title, this.subtitle, this.thumbnailUrl);
}

class _PlaylistShelfPage {
  final List<Track> songs;
  final List<Track> suggested;
  final String? continuation;
  const _PlaylistShelfPage(this.songs, this.suggested, this.continuation);
}

const List<String> _headerRenderers = [
  'musicResponsiveHeaderRenderer',
  'musicDetailHeaderRenderer',
];
const List<String> _headerCreditLines = ['straplineTextOne', 'subtitle'];
const Set<String> _releaseWords = {'album', 'single', 'ep'};

Map<String, dynamic>? _pageHeader(dynamic root) {
  for (final name in _headerRenderers) {
    final found = _collectRenderers(root, name);
    if (found.isNotEmpty) return found.first;
  }
  return null;
}

/// What a release or playlist page calls itself (Kotlin:
/// parseBrowseHeader).
_BrowseHeader? _parseBrowseHeader(dynamic root) {
  final header = _pageHeader(root);
  if (header == null) return null;
  final title = _runs(_o(header, 'title'));
  if (title.isEmpty) return null;
  final lines = <String>[];
  for (final key in _headerCreditLines) {
    final line = _runs(_o(header, key));
    if (line.isNotEmpty && !lines.contains(line)) lines.add(line);
  }
  final thumbs = _collectRenderers(header, 'musicThumbnailRenderer');
  return _BrowseHeader(
    title,
    lines.join(' • '),
    thumbs.isEmpty
        ? null
        : _bestThumb(_a(_o(thumbs.first, 'thumbnail'), 'thumbnails')),
  );
}

/// Who a release page is billed to, off its own header (Kotlin:
/// pageCredit). Only releases, never playlists: a playlist's header
/// names whoever put it together, which is not what its tracks are by.
_Credits _pageCredit(dynamic root) {
  final header = _pageHeader(root);
  if (header == null) return const _Credits();
  final linesRuns = <List<dynamic>>[
    for (final key in _headerCreditLines)
      _a(_o(header, key), 'runs') ?? const [],
  ];
  // Split per line, not across them: the strapline and the subtitle are
  // separate sentences.
  final parts = <String>[
    for (final line in linesRuns)
      ...line
          .map((r) => _s(r, 'text') ?? '')
          .join()
          .split(' • ')
          .map((p) => p.trim()),
  ];
  if (!parts.any((p) => _releaseWords.contains(p.toLowerCase()))) {
    return const _Credits();
  }
  final credits = _creditsOf([for (final line in linesRuns) ...line]);
  if (credits.artistName != null && credits.artistName!.isNotEmpty) {
    return credits;
  }
  // An artist YouTube has no page for is named in the same line without a
  // link to follow, leaving the name as the only thing to go on.
  final yearRe = RegExp(r'^\d{4}$');
  for (final part in parts) {
    if (part.isNotEmpty &&
        !_typeWords.contains(part.toLowerCase()) &&
        !_tallyRe.hasMatch(part) &&
        !yearRe.hasMatch(part) &&
        !_durationRe.hasMatch(part)) {
      return _Credits(
        artistId: credits.artistId,
        artistName: part,
        albumId: credits.albumId,
        albumName: credits.albumName,
      );
    }
  }
  return credits;
}

/// A playlist page's own tracks, the ones YouTube suggests adding, and
/// the token for the rest (Kotlin: parsePlaylistShelf). Null off a page
/// with nothing playlist-shaped in scope, so callers fall back to the
/// generic walk.
_PlaylistShelfPage? _parsePlaylistShelf(
    Map<String, dynamic> root, _Credits credit) {
  final scope = _o(root, 'continuationContents') ??
      _o(
          _o(_o(root, 'contents'), 'twoColumnBrowseResultsRenderer'),
          'secondaryContents');
  if (scope == null) return null;
  final playlistScope = _o(scope, 'musicPlaylistShelfContinuation') ??
      _collectRenderers(scope, 'musicPlaylistShelfRenderer').firstOrNull;
  final suggestionShelves = _collectRenderers(scope, 'musicShelfRenderer')
      .where((s) => _runs(_o(s, 'title')) == 'Suggestions')
      .toList();
  if (playlistScope == null && suggestionShelves.isEmpty) return null;

  final songs = <Track>[];
  final seenSongs = <String>{};
  if (playlistScope != null) {
    for (final row
        in _collectRenderers(playlistScope, 'musicResponsiveListItemRenderer')) {
      final song = _parseRow(row, fallback: credit);
      // Each song once: one added twice shows once.
      if (song != null && seenSongs.add(song.track.id)) {
        songs.add(song.track);
      }
    }
  }
  final suggested = <Track>[];
  final seenSuggested = <String>{};
  for (final shelf in suggestionShelves) {
    for (final row
        in _collectRenderers(shelf, 'musicResponsiveListItemRenderer')) {
      final song = _parseRow(row, fallback: credit);
      if (song != null &&
          !seenSongs.contains(song.track.id) &&
          seenSuggested.add(song.track.id)) {
        suggested.add(song.track);
      }
    }
  }
  // Only the playlist shelf's own continuation means more real tracks;
  // the Suggestions shelf's reloads it with a fresh batch instead.
  final token =
      playlistScope == null ? null : _continuationToken(playlistScope);
  return _PlaylistShelfPage(songs, suggested, token);
}

/// A later page of a playlist's songs (Kotlin: parsePlaylistContinuation):
/// the scoped shelf parse when the envelope is the older shape, else the
/// `appendContinuationItemsAction` items YouTube sends now.
_PlaylistShelfPage _parsePlaylistContinuation(
    Map<String, dynamic> root, _Credits credit) {
  final scoped = _parsePlaylistShelf(root, credit);
  if (scoped != null) return scoped;
  final songs = <Track>[];
  final seen = <String>{};
  String? token;
  for (final action in _a(root, 'onResponseReceivedActions') ?? const []) {
    final append = _o(action, 'appendContinuationItemsAction');
    if (append == null) continue;
    for (final item in _a(append, 'continuationItems') ?? const []) {
      final song =
          _parseRow(_o(item, 'musicResponsiveListItemRenderer'));
      if (song != null && seen.add(song.track.id)) songs.add(song.track);
      token ??= _s(
          _o(
              _o(_o(item, 'continuationItemRenderer'),
                  'continuationEndpoint'),
              'continuationCommand'),
          'token');
    }
  }
  return _PlaylistShelfPage(songs, const [], token);
}

/// Walks the whole response collecting any row that carries a videoId —
/// layout-agnostic, so it survives playlist/album/library differences
/// (Kotlin: collectSongsDeep).
List<Track> _collectSongsDeep(dynamic root, _Credits credit) {
  final out = <String, Track>{};
  void walk(dynamic node) {
    if (node is Map) {
      final renderer = node['musicResponsiveListItemRenderer'];
      if (renderer is Map<String, dynamic>) {
        final song = _parseRow(renderer, fallback: credit);
        if (song != null) out[song.track.id] = song.track;
      }
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(root);
  return out.values.toList();
}

// ===========================================================================
// Watch queue (Kotlin: parseWatchQueue)
// ===========================================================================

List<Track> _parseWatchQueue(Map<String, dynamic> root) {
  final out = <String, Track>{};
  for (final renderer
      in _collectRenderers(root, 'playlistPanelVideoRenderer')) {
    final videoId = _s(renderer, 'videoId');
    if (videoId == null) continue;
    final title = _runs(_o(renderer, 'title'));
    if (title.isEmpty) continue;
    // The byline packs artist, views and likes into one run list; only
    // the leading runs before the first bullet are the credit.
    final bylineRuns = _a(_o(renderer, 'longBylineText'), 'runs') ?? const [];
    final byline = [for (final r in bylineRuns) _s(r, 'text') ?? ''];
    final artist = byline.join().split('•').first.trim();
    final shortArtist =
        _runs(_o(renderer, 'shortBylineText')).split('•').first.trim();
    // Those same runs link out to the artist and album pages.
    final credits = _creditsOf([
      ...bylineRuns,
      ..._a(_o(renderer, 'shortBylineText'), 'runs') ?? const [],
    ]);
    final duration = _runs(_o(renderer, 'lengthText'));
    out[videoId] = Track(
      id: 'yt:$videoId',
      title: title,
      artist: _preferredArtist([artist, shortArtist, credits.artistName]),
      artUrl: upscaleArtwork(
          _bestThumb(_a(_o(renderer, 'thumbnail'), 'thumbnails'))),
      durationMs: parseClockMs(duration.isEmpty ? null : duration),
      artistId: (credits.artistId != null &&
              !_isPlaceholderArtist(credits.artistName))
          ? 'yt:${credits.artistId}'
          : null,
      albumId: credits.albumId == null ? null : 'yt:${credits.albumId}',
      album: credits.albumName,
      explicit: _hasExplicitBadge(renderer),
    );
    // The Kotlin also derives isVideo here (a byline run containing
    // "views"), but Dart's Track has no isVideo field, and YtMusic.radio
    // keeps video rows in the queue anyway — so every row is kept, as
    // served, exactly as the Kotlin's queue does.
  }
  return out.values.toList();
}

// ===========================================================================
// Card / row renderers (Kotlin: parseTwoRowItem / parseArtistRow /
// parseResponsiveListItem)
// ===========================================================================

_CardItem? _parseTwoRowItem(Map<String, dynamic>? renderer) {
  if (renderer == null) return null;
  final title = _runs(_o(renderer, 'title'));
  if (title.isEmpty) return null;
  final endpoint = _o(renderer, 'navigationEndpoint');
  final browseId = _s(_o(endpoint, 'browseEndpoint'), 'browseId');
  // History/"Listen again" cards for tracks YouTube never catalogued
  // carry no watchEndpoint — just a browseId to a "non-music audio track
  // page" prefixed MPED<videoId>. That's the actual video id.
  final videoId = _s(_o(endpoint, 'watchEndpoint'), 'videoId') ??
      (browseId != null && browseId.startsWith('MPED')
          ? browseId.substring(4)
          : null);
  final resolvedBrowseId =
      (browseId != null && browseId.startsWith('MPED')) ? null : browseId;
  final thumbnails = _a(
      _o(
          _o(_o(renderer, 'thumbnailRenderer'), 'musicThumbnailRenderer'),
          'thumbnail'),
      'thumbnails');
  final subtitle = _runs(_o(renderer, 'subtitle'));
  // A card with no browse target is a playable track; widescreen art on
  // one of those means a music-video upload — drop it.
  if (resolvedBrowseId == null && videoId != null && _thumbsNotSquare(thumbnails)) {
    return null;
  }
  // An album/playlist billed as a video chart/compilation is the same
  // dead-end as in the browse-row parser. A plain track card is exempt.
  if (resolvedBrowseId != null &&
      !resolvedBrowseId.startsWith('VL') &&
      !resolvedBrowseId.startsWith('PL') &&
      !resolvedBrowseId.startsWith('MPRE') &&
      !resolvedBrowseId.startsWith('UC') &&
      (_videoWordRe.hasMatch(title) || _videoWordRe.hasMatch(subtitle))) {
    return null;
  }
  return _CardItem(
    title: title,
    subtitle: subtitle,
    artUrl: _bestThumb(thumbnails),
    videoId: videoId,
    browseId: resolvedBrowseId,
    explicit: _hasExplicitBadge(renderer['subtitleBadges']),
  );
}

/// A chart row that names an artist rather than a track — no videoId for
/// the row parser to key off, so it is read off the row's own
/// navigationEndpoint (Kotlin: parseArtistRow).
_CardItem? _parseArtistRow(Map<String, dynamic>? renderer) {
  if (renderer == null) return null;
  final endpoint = _o(_o(renderer, 'navigationEndpoint'), 'browseEndpoint');
  final pageType = _s(
          _o(_o(endpoint, 'browseEndpointContextSupportedConfigs'),
              'browseEndpointContextMusicConfig'),
          'pageType') ??
      '';
  if (!pageType.contains('ARTIST')) return null;
  final browseId = _s(endpoint, 'browseId');
  if (browseId == null) return null;
  final columns = _a(renderer, 'flexColumns') ?? const [];
  String columnText(int i) {
    if (i >= columns.length) return '';
    return _runs(_o(
        _o(columns[i], 'musicResponsiveListItemFlexColumnRenderer'),
        'text'));
  }

  final title = columnText(0);
  if (title.isEmpty) return null;
  final thumbnails = _a(
      _o(_o(_o(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails');
  return _CardItem(
    title: title,
    subtitle: columnText(1),
    artUrl: _bestThumb(thumbnails),
    browseId: browseId,
  );
}

// ===========================================================================
// Duplicated helpers from innertube.dart (library-private there — see the
// file header). Kept behaviour-identical to the search layer's copies.
// ===========================================================================

Map<String, dynamic>? _o(dynamic v, String key) {
  if (v is Map) {
    final inner = v[key];
    if (inner is Map<String, dynamic>) return inner;
    if (inner is Map) return inner.cast<String, dynamic>();
  }
  return null;
}

List<dynamic>? _a(dynamic v, String key) {
  if (v is Map) {
    final inner = v[key];
    if (inner is List) return inner;
  }
  return null;
}

String? _s(dynamic v, String key) {
  if (v is Map) {
    final inner = v[key];
    if (inner is String) return inner;
    if (inner is num || inner is bool) return inner.toString();
  }
  return null;
}

String _runs(dynamic v) {
  final runs = _a(v, 'runs');
  if (runs == null) return '';
  return runs.map((r) => _s(r, 'text') ?? '').join();
}

List<Map<String, dynamic>> _collectRenderers(dynamic root, String name) {
  final out = <Map<String, dynamic>>[];
  void walk(dynamic node) {
    if (node is Map) {
      final hit = node[name];
      if (hit is Map<String, dynamic>) out.add(hit);
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(root);
  return out;
}

bool _hasExplicitBadge(dynamic v) {
  if (v is String) return v == 'MUSIC_EXPLICIT_BADGE';
  if (v is List) return v.any(_hasExplicitBadge);
  if (v is Map) return v.values.any(_hasExplicitBadge);
  return false;
}

bool _isPlaceholderArtist(String? name) {
  final key = (name ?? '')
      .trim()
      .replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  return const {
    '',
    'variousartist',
    'variousartists',
    'va',
    'unknownartist',
    'unknown',
    'artist'
  }.contains(key);
}

String _preferredArtist(List<String?> names) {
  for (final n in names) {
    if (!_isPlaceholderArtist(n)) return n!.trim();
  }
  for (final n in names) {
    if (n != null && n.trim().isNotEmpty) return n.trim();
  }
  return 'Unknown artist';
}

final RegExp _durationRe = RegExp(r'^\d+:\d{2}$');
final RegExp _tallyRe = RegExp(
  r'^[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|hours?|minutes?|seconds?)\b.*',
  caseSensitive: false,
);
final RegExp _videoWordRe = RegExp(r'\bvideos?\b', caseSensitive: false);
const Set<String> _typeWords = {
  'song',
  'video',
  'album',
  'single',
  'ep',
  'artist',
  'playlist',
  'podcast',
  'episode',
};

class _Credits {
  final String? artistId;
  final String? artistName;
  final String? albumId;
  final String? albumName;
  const _Credits({this.artistId, this.artistName, this.albumId, this.albumName});
}

_Credits _creditsOf(List<dynamic> runs) {
  String? artistId, artistName, albumId, albumName;
  for (final run in runs) {
    final browse = _o(_o(run, 'navigationEndpoint'), 'browseEndpoint');
    final id = _s(browse, 'browseId');
    if (browse == null || id == null) continue;
    final pageType = _s(
            _o(_o(browse, 'browseEndpointContextSupportedConfigs'),
                'browseEndpointContextMusicConfig'),
            'pageType') ??
        '';
    if (pageType.contains('ARTIST') &&
        (artistId == null ||
            (_isPlaceholderArtist(artistName) &&
                !_isPlaceholderArtist(_s(run, 'text'))))) {
      artistId = id;
      artistName = _s(run, 'text');
    } else if (pageType.contains('ALBUM') && albumId == null) {
      albumId = id;
      albumName = _s(run, 'text');
    }
  }
  return _Credits(
      artistId: artistId, artistName: artistName, albumId: albumId, albumName: albumName);
}

bool _thumbsNotSquare(List<dynamic>? thumbnails) {
  if (thumbnails == null || thumbnails.isEmpty) return false;
  final last = thumbnails.last;
  final w = _s(last, 'width');
  final h = _s(last, 'height');
  final width = w == null ? null : double.tryParse(w);
  final height = h == null ? null : double.tryParse(h);
  if (width == null || height == null || width <= 0 || height <= 0) {
    return false;
  }
  final ratio = width / height;
  return ratio < 0.85 || ratio > 1.15;
}

String? _bestThumb(List<dynamic>? thumbnails) {
  if (thumbnails == null || thumbnails.isEmpty) return null;
  return _s(thumbnails.last, 'url');
}

String? _continuationToken(dynamic root) {
  final items = _collectRenderers(root, 'continuationItemRenderer');
  if (items.isNotEmpty) {
    final token = _s(
        _o(_o(items.first, 'continuationEndpoint'), 'continuationCommand'),
        'token');
    if (token != null) return token;
  }
  String? found;
  void walk(dynamic node) {
    if (found != null) return;
    if (node is Map) {
      final v = node['nextContinuationData'];
      if (v is Map) found = _s(v, 'continuation');
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(root);
  return found;
}

class _RowSong {
  final Track track;
  final bool isVideo;
  const _RowSong(this.track, this.isVideo);
}

/// One track row (Kotlin: InnertubeParser.parseResponsiveListItem) —
/// behaviour-identical duplicate of innertube.dart's
/// _parseResponsiveListItem.
_RowSong? _parseRow(Map<String, dynamic>? renderer,
    {_Credits fallback = const _Credits()}) {
  if (renderer == null) return null;
  var node = _o(renderer, 'overlay');
  node = _o(node, 'musicItemThumbnailOverlayRenderer');
  node = _o(node, 'content');
  node = _o(node, 'musicPlayButtonRenderer');
  node = _o(node, 'playNavigationEndpoint');
  final resolvedVideoId = _s(_o(renderer, 'playlistItemData'), 'videoId') ??
      _s(_o(node, 'watchEndpoint'), 'videoId');
  if (resolvedVideoId == null) return null;

  final columns = _a(renderer, 'flexColumns') ?? const [];
  String columnText(int i) {
    if (i >= columns.length) return '';
    return _runs(_o(
        _o(columns[i], 'musicResponsiveListItemFlexColumnRenderer'), 'text'));
  }

  final title = columnText(0);
  if (title.isEmpty) return null;
  final subtitle = columnText(1);
  final parts = subtitle.split(' • ').where((p) => p.isNotEmpty).toList();

  String? duration;
  if (parts.isNotEmpty && _durationRe.hasMatch(parts.last)) {
    duration = parts.last;
  } else {
    for (final column in _a(renderer, 'fixedColumns') ?? const []) {
      final text = _runs(
          _o(_o(column, 'musicResponsiveListItemFixedColumnRenderer'), 'text'));
      if (_durationRe.hasMatch(text)) {
        duration = text;
        break;
      }
    }
  }

  String? rowType;
  for (final p in parts) {
    if (_typeWords.contains(p.toLowerCase())) {
      rowType = p.toLowerCase();
      break;
    }
  }
  String? artist;
  for (final p in parts) {
    if (!_durationRe.hasMatch(p) &&
        !_typeWords.contains(p.toLowerCase()) &&
        !_tallyRe.hasMatch(p)) {
      artist = p;
      break;
    }
  }

  final allRuns = <dynamic>[];
  for (final col in columns) {
    final runs = _a(
        _o(_o(col, 'musicResponsiveListItemFlexColumnRenderer'), 'text'),
        'runs');
    if (runs != null) allRuns.addAll(runs);
  }
  final credits = _creditsOf(allRuns);

  final thumbnails = _a(
      _o(_o(_o(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails');

  final artistId = (credits.artistId != null &&
          !_isPlaceholderArtist(credits.artistName))
      ? credits.artistId
      : (fallback.artistId != null &&
              !_isPlaceholderArtist(fallback.artistName)
          ? fallback.artistId
          : null);

  final isVideo = rowType == 'video' || _thumbsNotSquare(thumbnails);
  final track = Track(
    id: 'yt:$resolvedVideoId',
    title: title,
    artist: _preferredArtist([credits.artistName, artist, fallback.artistName]),
    album: credits.albumName ?? fallback.albumName,
    durationMs: parseClockMs(duration),
    artUrl: upscaleArtwork(_bestThumb(thumbnails)),
    artistId: artistId == null ? null : 'yt:$artistId',
    albumId: (credits.albumId ?? fallback.albumId) == null
        ? null
        : 'yt:${credits.albumId ?? fallback.albumId}',
    explicit: _hasExplicitBadge(renderer['badges']),
  );
  return _RowSong(track, isVideo);
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
