import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library.dart';
import 'media_tools.dart';

const _prefsKey = 'durations';

/// Recording lengths, probed once per file and remembered across launches.
/// An entry is reused while the file's size and modification time match.
class DurationCache extends ChangeNotifier {
  DurationCache(this._prefs, this._media) {
    final stored = _prefs.getString(_prefsKey);
    if (stored == null) return;
    try {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in decoded.entries) {
        _entries[key] = (value as List).cast<num>();
      }
    } on FormatException {
      // Starts empty.
    }
  }

  final SharedPreferences _prefs;
  final MediaTools _media;

  /// Size in bytes, modification time in milliseconds and length in seconds,
  /// keyed by the recording's path relative to the library root.
  final _entries = <String, List<num>>{};
  bool _probing = false;

  /// The cached length of [recording] in seconds, if it is still valid.
  double? of(Recording recording) {
    final entry = _entries[recording.relPath];
    if (entry == null) return null;
    final stat = recording.file.statSync();
    if (entry[0] != stat.size ||
        entry[1] != stat.modified.millisecondsSinceEpoch) {
      return null;
    }
    return entry[2].toDouble();
  }

  /// Measures the recordings that have no valid entry, one at a time.
  Future<void> probe(Iterable<Recording> recordings) async {
    if (_probing) return;
    _probing = true;
    try {
      var changed = false;
      for (final recording in recordings) {
        if (!recording.file.existsSync() || of(recording) != null) continue;
        final seconds = await _media.duration(recording.file);
        if (seconds == null || !recording.file.existsSync()) continue;
        final stat = recording.file.statSync();
        _entries[recording.relPath] = [
          stat.size,
          stat.modified.millisecondsSinceEpoch,
          seconds,
        ];
        changed = true;
        notifyListeners();
      }
      if (changed) await _prefs.setString(_prefsKey, jsonEncode(_entries));
    } finally {
      _probing = false;
    }
  }
}
