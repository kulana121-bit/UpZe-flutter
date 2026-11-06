// Ported from UpZe (Kotlin) lyrics/Lyrics.kt — originally OpenTune 1.0.4,
// Copyright (C) OpenTune contributors, GPL-3.0-or-later.
// Modified for UpZe (C) 2026 Ravi, GPL-3.0-or-later.
//
// Pure Dart: no Flutter, no I/O, no packages. Safe to unit-test directly.

/// Who sings a line: 0 the lead, 1 a second voice in a duet, 2 everyone together.
const int voiceLead = 0;
const int voiceSecond = 1;
const int voiceTogether = 2;

/// One timed word (or syllable) inside a synced line.
class LyricWord {
  final String text;
  final int startMs;
  final int endMs;

  const LyricWord(this.text, this.startMs, this.endMs);

  Map<String, dynamic> toJson() => {
        'text': text,
        'startMs': startMs,
        'endMs': endMs,
      };

  factory LyricWord.fromJson(Map<String, dynamic> j) => LyricWord(
        j['text'] as String? ?? '',
        (j['startMs'] as num?)?.toInt() ?? 0,
        (j['endMs'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is LyricWord &&
      other.text == text &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(text, startMs, endMs);

  @override
  String toString() => 'LyricWord($startMs-$endMs "$text")';
}

/// One timed lyrics line.
class LyricLine {
  final int startMs;
  final int endMs;
  final String text;

  /// Per-word timing. Exact when the source has word sync (enhanced LRC);
  /// otherwise spread across the line by character count, which is close
  /// enough to make the highlight sweep instead of jump.
  final List<LyricWord> words;
  final bool wordSynced;

  /// Who sings it, where the source says: see [voiceLead] etc.
  final int voice;

  /// Backing vocals sung under this line, shown smaller beneath it.
  final String? background;

  /// Right to left (Arabic, Hebrew, Persian, Urdu), as the source marks it;
  /// null when it doesn't say, and the text's own script decides.
  final bool? rtl;

  const LyricLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.words,
    required this.wordSynced,
    this.voice = voiceLead,
    this.background,
    this.rtl,
  });

  LyricLine copyWith({int? startMs, int? endMs, String? text}) => LyricLine(
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        text: text ?? this.text,
        words: words,
        wordSynced: wordSynced,
        voice: voice,
        background: background,
        rtl: rtl,
      );

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
        'words': words.map((w) => w.toJson()).toList(),
        'wordSynced': wordSynced,
        'voice': voice,
        'background': background,
        'rtl': rtl,
      };

  factory LyricLine.fromJson(Map<String, dynamic> j) => LyricLine(
        startMs: (j['startMs'] as num?)?.toInt() ?? 0,
        endMs: (j['endMs'] as num?)?.toInt() ?? 0,
        text: j['text'] as String? ?? '',
        words: ((j['words'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LyricWord.fromJson)
            .toList(),
        wordSynced: j['wordSynced'] as bool? ?? false,
        voice: (j['voice'] as num?)?.toInt() ?? voiceLead,
        background: j['background'] as String?,
        rtl: j['rtl'] as bool?,
      );

  @override
  String toString() => 'LyricLine($startMs-$endMs "$text")';
}

/// A named stretch of a song (verse, chorus, bridge) as the lyrics source marks it.
class SongPart {
  final String name;
  final int startMs;
  final int endMs;

  const SongPart(this.name, this.startMs, this.endMs);

  Map<String, dynamic> toJson() =>
      {'name': name, 'startMs': startMs, 'endMs': endMs};

  factory SongPart.fromJson(Map<String, dynamic> j) => SongPart(
        j['name'] as String? ?? '',
        (j['startMs'] as num?)?.toInt() ?? 0,
        (j['endMs'] as num?)?.toInt() ?? 0,
      );
}

/// Whether [line] reads right to left: as its source says, else by its first
/// letter with a direction.
///
/// Dart has no `Character.getDirectionality`, so the fallback checks the
/// first strong character against the main RTL script blocks (Hebrew,
/// Arabic, Syriac, Thaana, Nko, Samaritan, Mandaic, Arabic Extended).
bool readsRightToLeft(LyricLine line) {
  if (line.rtl != null) return line.rtl!;
  for (final rune in line.text.runes) {
    if (_isRtlRune(rune)) return true;
    if (_isLetterOrDigit(rune)) return false;
  }
  return false;
}

bool _isRtlRune(int r) =>
    (r >= 0x0590 && r <= 0x05FF) || // Hebrew
    (r >= 0x0600 && r <= 0x06FF) || // Arabic
    (r >= 0x0700 && r <= 0x074F) || // Syriac
    (r >= 0x0750 && r <= 0x077F) || // Arabic Supplement
    (r >= 0x0780 && r <= 0x07BF) || // Thaana
    (r >= 0x07C0 && r <= 0x07FF) || // Nko
    (r >= 0x0800 && r <= 0x083F) || // Samaritan
    (r >= 0x0840 && r <= 0x085F) || // Mandaic
    (r >= 0x08A0 && r <= 0x08FF) || // Arabic Extended-A
    (r >= 0xFB1D && r <= 0xFDFF) || // Hebrew/Arabic presentation forms
    (r >= 0xFE70 && r <= 0xFEFF); // Arabic presentation forms-B

final RegExp _letterOrDigitRe = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isLetterOrDigit(int rune) =>
    _letterOrDigitRe.hasMatch(String.fromCharCode(rune));

/// CJK scripts get a syllable's worth of time per character in [LrcParser].
bool _isCjkRune(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) || // Han
    (r >= 0x3400 && r <= 0x4DBF) || // Han ext A
    (r >= 0xAC00 && r <= 0xD7AF) || // Hangul syllables
    (r >= 0x1100 && r <= 0x11FF) || // Hangul jamo
    (r >= 0x3040 && r <= 0x309F) || // Hiragana
    (r >= 0x30A0 && r <= 0x30FF); // Katakana

/// Parses LRC, including the enhanced `<mm:ss.xx>` word tags some sources carry.
class LrcParser {
  LrcParser._();

  static final RegExp _lineTag =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final RegExp _wordTag =
      RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');
  static final RegExp _offsetTag =
      RegExp(r'\[offset:\s*([+-]?\d+)\]', caseSensitive: false);
  static final RegExp _whitespace = RegExp(r'\s+');

  /// A line with no following line is given this long before it ends.
  static const int lastLineMs = 5000;

  static List<LyricLine> parse(String lrc, {int durationMs = 0}) {
    final offsetMatch = _offsetTag.firstMatch(lrc);
    final offset = offsetMatch == null
        ? 0
        : int.tryParse(offsetMatch.group(1)!) ?? 0;

    // A line can carry several timestamps when a chorus repeats.
    final raw = <(int, String)>[];
    for (final line in lrc.split('\n')) {
      final tags = _lineTag.allMatches(line).toList();
      if (tags.isEmpty || tags.first.start != 0) continue;
      final text = line.substring(tags.last.end);
      for (final tag in tags) {
        final start = _toMs(tag) - offset;
        raw.add((start < 0 ? 0 : start, text));
      }
    }
    raw.sort((a, b) => a.$1.compareTo(b.$1));

    final lines = <LyricLine>[];
    for (var i = 0; i < raw.length; i++) {
      final start = raw[i].$1;
      final body = raw[i].$2;
      final nextStart = i + 1 < raw.length ? raw[i + 1].$1 : null;
      final int end = nextStart ??
          (durationMs > start
              ? (durationMs < start + lastLineMs * 2
                  ? durationMs
                  : start + lastLineMs * 2)
              : start + lastLineMs);
      final timedWords = _parseWords(body, end, offset);
      final text = body.replaceAll(_wordTag, '').replaceAll(_whitespace, ' ').trim();
      if (text.isEmpty) continue; // instrumental gap marker
      lines.add(LyricLine(
        startMs: start,
        endMs: end,
        text: text,
        words: timedWords ?? spreadWords(text, start, end),
        wordSynced: timedWords != null,
      ));
    }
    return lines;
  }

  static List<LyricWord>? _parseWords(String body, int lineEnd, int offset) {
    final tags = _wordTag.allMatches(body).toList();
    if (tags.length < 2) return null;
    final words = <LyricWord>[];
    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i];
      final textEnd = i + 1 < tags.length ? tags[i + 1].start : body.length;
      final text = body.substring(tag.end, textEnd);
      if (text.trim().isEmpty) continue;
      var start = _toMs(tag) - offset;
      if (start < 0) start = 0;
      var end = i + 1 < tags.length ? _toMs(tags[i + 1]) - offset : lineEnd;
      if (end < start) end = start;
      words.add(LyricWord(text, start, end));
    }
    return words.isEmpty ? null : words;
  }

  /// Estimate word timing for a line-synced lyric. Singers rarely use the
  /// full gap to the next line, so the sweep finishes a little early, and
  /// never takes much longer than the words take to sing: a short line
  /// before an instrumental break used to crawl on through the break, and
  /// the break only showed as one once the crawl was done.
  static List<LyricWord> spreadWords(String text, int start, int end) {
    final tokens =
        RegExp(r'\S+\s*').allMatches(text).map((m) => m.group(0)!).toList();
    if (tokens.isEmpty) return const [];
    var span = ((end - start) * 0.85).toInt();
    final singSpan = singingMs(text) * 3 ~/ 2;
    if (singSpan < span) span = singSpan;
    if (span < 300) span = 300;
    if (span > 8000) span = 8000;
    var totalChars = 0;
    for (final t in tokens) {
      final len = t.trim().length;
      totalChars += len < 1 ? 1 : len;
    }
    var cursor = start;
    return tokens.map((token) {
      final len = token.trim().length;
      final share = span * (len < 1 ? 1 : len) ~/ totalChars;
      final word = LyricWord(token, cursor, cursor + share);
      cursor += share;
      return word;
    }).toList();
  }

  /// About how long [text] takes to sing at an ordinary pace: a syllable's
  /// worth of time for each Chinese, Japanese or Korean character, less for
  /// each letter of an alphabet, where several letters make a syllable.
  static int singingMs(String text) {
    var ms = 400;
    for (final rune in text.runes) {
      if (!_isLetterOrDigit(rune)) continue;
      ms += _isCjkRune(rune) ? 330 : 160;
    }
    return ms;
  }

  static int _toMs(RegExpMatch match) {
    final min = int.parse(match.group(1)!);
    final sec = int.parse(match.group(2)!);
    final frac = match.group(3) ?? '';
    final int fracMs;
    if (frac.isEmpty) {
      fracMs = 0;
    } else if (frac.length == 1) {
      fracMs = int.parse(frac) * 100;
    } else if (frac.length == 2) {
      fracMs = int.parse(frac) * 10;
    } else {
      fracMs = int.parse(frac.substring(0, 3));
    }
    return min * 60000 + sec * 1000 + fracMs;
  }
}

/// A stretch with no singing between two lines, long enough to show as an
/// instrumental break.
class LyricGap {
  final int afterIndex;
  final int startMs;
  final int endMs;

  const LyricGap(this.afterIndex, this.startMs, this.endMs);
}

extension LyricLineTiming on LyricLine {
  /// When the singing in this line actually stops: the end of its last word,
  /// or the line's end when it carries no word timing.
  int get sungUntilMs {
    var best = endMs;
    if (words.isNotEmpty) {
      best = words.first.endMs;
      for (final w in words) {
        if (w.endMs > best) best = w.endMs;
      }
    }
    return best;
  }
}

extension LyricLineListLookup on List<LyricLine> {
  /// Index of the line playing at [positionMs], or -1 before the first one.
  /// (The Kotlin `List<LyricLine>.activeIndex` — binary search.)
  int activeIndex(int positionMs) {
    var lo = 0;
    var hi = length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (this[mid].startMs <= positionMs) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  /// The line playing at [positionMs], or null before the first one.
  LyricLine? activeLine(int positionMs) {
    final i = activeIndex(positionMs);
    return i < 0 ? null : this[i];
  }

  /// Instrumental breaks between lines: a line stops being sung and the
  /// next doesn't start for at least [minMs]. Used to show breathing dots
  /// in the gap instead of leaving the last line lit through a passage
  /// with no vocals.
  List<LyricGap> instrumentalGaps({int minMs = 5000}) {
    final out = <LyricGap>[];
    for (var i = 0; i + 1 < length; i++) {
      final from = this[i].sungUntilMs;
      final to = this[i + 1].startMs;
      if (to - from >= minMs) out.add(LyricGap(i, from, to));
    }
    return out;
  }
}
