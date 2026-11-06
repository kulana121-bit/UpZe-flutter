// Romanizer — Dart client for the lyric romanization in
// lyrics/Romanizer.kt (UpZe v1.0.1, ported there from OpenTune).
//
// The Kotlin does the work with Android's own ICU transliterator
// (android.icu.text.Transliterator, API 29+): "Any-Latin; Latin-ASCII"
// for most scripts, "Han-Latin; Latin-ASCII" for Chinese runs outside
// Japanese lyrics, and a hand-rolled Revised-Romanization table for
// Hangul. None of that exists in Dart, so — exactly as the Kotlin's
// Android-only pieces always needed the platform — the transliteration
// itself stays on the Android side, behind a MethodChannel:
//
//   channel:  'upze/romanizer'
//   'isAvailable'  ()           -> bool
//   'romanize'     List<String> -> List<String?>  (same length/order;
//                                  null where a line is already Latin
//                                  or cannot be romanized)
//
// The native handler (to be registered in MainActivity, mirroring
// Romanizer.kt line for line) is NOT part of this file. Until it lands —
// and on every non-Android target (desktop, tests) — this client
// degrades exactly the way the Kotlin does below API 29: [available]
// is false and [lines] answers a null for every line, so callers can
// offer romanization opportunistically and simply show nothing extra
// when it isn't there.

import 'package:flutter/services.dart';

/// Lyrics in Latin letters, for following along in a script you don't
/// read (Kotlin: Romanizer).
class Romanizer {
  Romanizer._();

  static const MethodChannel _channel = MethodChannel('upze/romanizer');

  /// The Kotlin computes availability once (a lazy val); the answer
  /// can't change while the app runs, so it is cached after first ask.
  static Future<bool>? _availableCache;

  /// Whether romanization can actually be offered: the native handler
  /// is registered AND its ICU transliterators loaded (Android 10+).
  static Future<bool> available() {
    return _availableCache ??= _checkAvailable();
  }

  static Future<bool> _checkAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false; // No native handler (yet, or not Android).
    } on PlatformException {
      return false;
    }
  }

  /// Each line in Latin letters, or null where it's already in them (or
  /// can't be) — the Kotlin's `Romanizer.lines` contract, including its
  /// all-nulls answer when romanization is unavailable.
  static Future<List<String?>> lines(List<String> texts) async {
    final nulls = List<String?>.filled(texts.length, null);
    if (texts.isEmpty) return nulls;
    if (!await available()) return nulls;
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('romanize', texts);
      // A short/long answer can't be lined up with the input safely;
      // treat a shape drift like unavailability rather than guess.
      if (result == null || result.length != texts.length) return nulls;
      return result.map((e) => e is String ? e : null).toList();
    } on MissingPluginException {
      return nulls;
    } on PlatformException {
      return nulls;
    }
  }
}
