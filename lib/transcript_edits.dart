import 'dart:convert';
import 'dart:io';

import 'library.dart';
import 'srt.dart';

String _timestamp(double seconds) {
  final ms = (seconds * 1000).round();
  String pad(int v, int w) => v.toString().padLeft(w, '0');
  return '${pad(ms ~/ 3600000, 2)}:${pad(ms % 3600000 ~/ 60000, 2)}:'
      '${pad(ms % 60000 ~/ 1000, 2)},${pad(ms % 1000, 3)}';
}

/// [cues] as SRT text, numbered from 1.
String formatSrt(List<Cue> cues) {
  final out = StringBuffer();
  for (final (i, cue) in cues.indexed) {
    if (i > 0) out.writeln();
    out.writeln(i + 1);
    out.writeln('${_timestamp(cue.start)} --> ${_timestamp(cue.end)}');
    for (final item in cue.items) {
      out.writeln(
        item.speaker == null
            ? item.text
            : 'Speaker ${item.speaker}: ${item.text}',
      );
    }
  }
  return out.toString();
}

/// The speaker shown for line [item] of cue [cue]: a manual change when there
/// is one, else the SRT's own label.
String? effectiveSpeaker(
  List<Cue> cues,
  Map<String, String> overrides,
  int cue,
  int item,
) {
  return overrides['$cue:$item'] ?? cues[cue].items[item].speaker;
}

/// How many lines each speaker has, keyed by speaker id in numeric order.
Map<String, int> speakerLineCounts(
  List<Cue> cues,
  Map<String, String> overrides,
) {
  final counts = <String, int>{};
  for (var c = 0; c < cues.length; c++) {
    for (var i = 0; i < cues[c].items.length; i++) {
      final speaker = effectiveSpeaker(cues, overrides, c, i);
      if (speaker != null) counts[speaker] = (counts[speaker] ?? 0) + 1;
    }
  }
  final ids = counts.keys.toList()
    ..sort((a, b) {
      final x = int.tryParse(a);
      final y = int.tryParse(b);
      return x != null && y != null ? x.compareTo(y) : a.compareTo(b);
    });
  return {for (final id in ids) id: counts[id]!};
}

/// The id for a speaker that is not in [existing]: one above the highest.
String nextSpeakerId(Iterable<String> existing) {
  var highest = 0;
  for (final id in existing) {
    final n = int.tryParse(id) ?? 0;
    if (n > highest) highest = n;
  }
  return '${highest + 1}';
}

/// Edits to a recording's stored transcript, translation and speaker files.
class TranscriptEditor {
  TranscriptEditor(this.library, this.recording);

  final Library library;
  final File recording;

  List<Cue> _cues(Sidecar key) =>
      parseSrt(library.sidecarFile(recording, key).readAsStringSync());

  void _writeMap(Sidecar key, Map<String, String> map) {
    final file = library.sidecarFile(recording, key);
    if (map.isEmpty) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(map));
  }

  /// Replaces the text of line [item] of cue [cue] in the SRT stored as
  /// [key]. Editing the transcript also refreshes its plain-text copy.
  void setText(Sidecar key, int cue, int item, String rawText) {
    final text = rawText.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    if (text.isEmpty) throw const LibraryException('Enter some text');
    final cues = _cues(key);
    final items = cues[cue].items;
    items[item] = CueItem(items[item].speaker, text);
    final srt = formatSrt(cues);
    library.sidecarFile(recording, key).writeAsStringSync(srt);
    if (key == Sidecar.transcriptSrt) {
      library
          .sidecarFile(recording, Sidecar.transcriptTxt)
          .writeAsStringSync(srtToPlaintext(srt));
    }
  }

  /// Names [speaker] for this recording. An empty name removes it.
  void setSpeakerName(String speaker, String rawName) {
    final names = library.readStringMap(recording, Sidecar.speakers);
    final name = rawName.trim();
    if (name.isEmpty) {
      names.remove(speaker);
    } else {
      names[speaker] = name;
    }
    _writeMap(Sidecar.speakers, names);
  }

  void _setOverride(
    List<Cue> cues,
    Map<String, String> overrides,
    int cue,
    int item,
    String speaker,
  ) {
    if (cues[cue].items[item].speaker == speaker) {
      overrides.remove('$cue:$item');
    } else {
      overrides['$cue:$item'] = speaker;
    }
  }

  /// Assigns line [item] of cue [cue] to [speaker].
  void setLineSpeaker(int cue, int item, String speaker) {
    final cues = _cues(Sidecar.transcriptSrt);
    final overrides = library.readStringMap(recording, Sidecar.overrides);
    _setOverride(cues, overrides, cue, item, speaker);
    _writeMap(Sidecar.overrides, overrides);
  }

  /// Reassigns lines according to [mapping], from current speaker to new
  /// speaker, starting at line [fromItem] of cue [fromCue] and running to the
  /// end. Lines of speakers not in [mapping] are left alone.
  void remapSpeakers(
    Map<String, String> mapping, {
    int fromCue = 0,
    int fromItem = 0,
  }) {
    final cues = _cues(Sidecar.transcriptSrt);
    final overrides = library.readStringMap(recording, Sidecar.overrides);
    for (var c = fromCue; c < cues.length; c++) {
      for (var i = c == fromCue ? fromItem : 0; i < cues[c].items.length; i++) {
        final target = mapping[effectiveSpeaker(cues, overrides, c, i)];
        if (target != null) _setOverride(cues, overrides, c, i, target);
      }
    }
    _writeMap(Sidecar.overrides, overrides);
  }

  /// Gives every line of [a] to [b] and every line of [b] to [a].
  void swapSpeakers(String a, String b) => remapSpeakers({a: b, b: a});

  /// Gives every line of [from] to [into].
  void mergeSpeakers(String from, String into) => remapSpeakers({from: into});

  /// Drops every manual speaker change, back to the transcript's own labels.
  void resetSpeakerChanges() => _writeMap(Sidecar.overrides, {});
}
