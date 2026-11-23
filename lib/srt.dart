class CueItem {
  const CueItem(this.speaker, this.text);

  final String? speaker;
  final String text;
}

class Cue {
  Cue(this.start, this.end, this.items);

  final double start;
  double end;
  final List<CueItem> items;
}

final _parseTs = RegExp(r'^(\d+):(\d+):(\d+)[,.](\d+)$');
final _speakerLine = RegExp(r'^Speaker\s+(\d+)\s*:\s*(.*)$');
final _digitsOnly = RegExp(r'^\d+$');

double _tsToSeconds(String s) {
  final m = _parseTs.firstMatch(s);
  if (m == null) return 0;
  return int.parse(m[1]!) * 3600 +
      int.parse(m[2]!) * 60 +
      int.parse(m[3]!) +
      int.parse(m[4]!) / 1000;
}

/// Parses SRT text into cues. A cue whose end is not after its start gets its
/// end clamped to min(start + 5s, next cue's start).
List<Cue> parseSrt(String text) {
  final out = <Cue>[];
  for (final block in text.replaceAll('\r', '').split(RegExp(r'\n\s*\n+'))) {
    final lines = block
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final tsIdx = lines.indexWhere((l) => l.contains('-->'));
    if (tsIdx < 0) continue;
    final parts = lines[tsIdx].split('-->');
    if (parts.length != 2) continue;
    final items = <CueItem>[];
    for (final ln in lines.skip(tsIdx + 1)) {
      final m = _speakerLine.firstMatch(ln);
      items.add(m != null ? CueItem(m[1], m[2]!) : CueItem(null, ln));
    }
    out.add(
      Cue(_tsToSeconds(parts[0].trim()), _tsToSeconds(parts[1].trim()), items),
    );
  }
  for (var i = 0; i < out.length; i++) {
    if (out[i].end <= out[i].start) {
      var cand = out[i].start + 5;
      if (i + 1 < out.length && out[i + 1].start > out[i].start) {
        cand = cand < out[i + 1].start ? cand : out[i + 1].start;
      }
      out[i].end = cand;
    }
  }
  return out;
}

/// Index of the shortest cue containing [t], or -1.
int activeCueIndex(List<Cue> cues, double t) {
  var idx = -1;
  var bestDur = double.infinity;
  for (var i = 0; i < cues.length; i++) {
    final c = cues[i];
    if (c.start <= t && t < c.end) {
      final dur = c.end - c.start;
      if (dur < bestDur) {
        bestDur = dur;
        idx = i;
      }
    }
  }
  return idx;
}

/// Formats seconds as m:ss, or h:mm:ss from one hour up.
String formatClock(double seconds) {
  if (!seconds.isFinite) return '';
  final total = seconds.floor();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
  return '$m:$s';
}

String stripCodeFence(String text) {
  final t = text.trim();
  if (!t.startsWith('```')) return t;
  final lines = t.split('\n').sublist(1);
  if (lines.isNotEmpty && lines.last.trim().startsWith('```')) {
    lines.removeLast();
  }
  return lines.join('\n').trim();
}

final _tsFull = RegExp(r'^(\d{2}):(\d{2}):(\d{2}),(\d{3})$');
final _tsMsColon = RegExp(r'^(\d{2}):(\d{2}):(\d{3})$');
final _tsMsComma = RegExp(r'^(\d{2}):(\d{2}),(\d{3})$');
final _tsPair = RegExp(r'^(.+?)\s*-->\s*(.+?)\s*$', multiLine: true);

String _normalizeTs(String raw) {
  final ts = raw.trim();
  if (_tsFull.hasMatch(ts)) return ts;
  for (final pat in [_tsMsColon, _tsMsComma]) {
    final m = pat.firstMatch(ts);
    if (m != null) return '00:${m[1]}:${m[2]},${m[3]}';
  }
  return ts;
}

/// Rewrites MM:SS,mmm and MM:SS:mmm timestamps as HH:MM:SS,mmm.
String normalizeSrtTimestamps(String srt) {
  return srt.replaceAllMapped(
    _tsPair,
    (m) => '${_normalizeTs(m[1]!)} --> ${_normalizeTs(m[2]!)}',
  );
}

final _cueTs = RegExp(
  r'^(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*$',
  multiLine: true,
);

int _tsToMs(RegExpMatch m, int from) {
  return ((int.parse(m[from]!) * 60 + int.parse(m[from + 1]!)) * 60 +
              int.parse(m[from + 2]!)) *
          1000 +
      int.parse(m[from + 3]!);
}

String _msToTs(int ms) {
  String pad(int v, int w) => v.toString().padLeft(w, '0');
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  return '${pad(h, 2)}:${pad(m, 2)}:${pad(s, 2)},${pad(ms % 1000, 3)}';
}

/// Rewrites cues whose end is not after their start, clamping the end to
/// min(start + 5s, next cue's start). Expects normalized timestamps.
String fixBackwardTimestamps(String srt) {
  final matches = _cueTs.allMatches(srt).toList();
  if (matches.isEmpty) return srt;
  final starts = [for (final m in matches) _tsToMs(m, 1)];
  final ends = [for (final m in matches) _tsToMs(m, 5)];
  for (var i = matches.length - 1; i >= 0; i--) {
    if (ends[i] > starts[i]) continue;
    var cand = starts[i] + 5000;
    if (i + 1 < starts.length && starts[i + 1] > starts[i]) {
      cand = cand < starts[i + 1] ? cand : starts[i + 1];
    }
    srt = srt.replaceRange(
      matches[i].start,
      matches[i].end,
      '${_msToTs(starts[i])} --> ${_msToTs(cand)}',
    );
  }
  return srt;
}

final _speakerInline = RegExp(r'Speaker\s+(\d+)\s*:\s*');

/// Splits a text line carrying several "Speaker N:" labels into one line per
/// speaker turn.
String splitInlineSpeakers(String srt) {
  final out = <String>[];
  for (final line in srt.split('\n')) {
    final s = line.trim();
    if (s.isEmpty || _digitsOnly.hasMatch(s) || s.contains('-->')) {
      out.add(line);
      continue;
    }
    final matches = _speakerInline.allMatches(line).toList();
    if (matches.length <= 1) {
      out.add(line);
      continue;
    }
    final prefix = line.substring(0, matches.first.start).trimRight();
    if (prefix.isNotEmpty) out.add(prefix);
    for (var i = 0; i < matches.length; i++) {
      final end = i + 1 < matches.length ? matches[i + 1].start : line.length;
      final seg = line.substring(matches[i].start, end).trimRight();
      if (seg.isNotEmpty) out.add(seg);
    }
  }
  return out.join('\n');
}

/// The cue text lines of an SRT, without numbers or timestamps.
String srtToPlaintext(String srt) {
  final out = <String>[];
  for (final line in srt.split('\n')) {
    final s = line.trim();
    if (s.isEmpty || _digitsOnly.hasMatch(s) || s.contains('-->')) continue;
    out.add(s);
  }
  return '${out.join('\n')}\n';
}

/// The cleanup applied to a model's raw SRT output before it is stored.
String cleanModelSrt(String raw) {
  return splitInlineSpeakers(
    fixBackwardTimestamps(normalizeSrtTimestamps(stripCodeFence(raw))),
  );
}
