import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'combine.dart';
import 'job.dart';
import 'library.dart';
import 'media_tools.dart';
import 'notes.dart';
import 'srt.dart';
import 'transcript_edits.dart';
import 'trash.dart';

final _familyStem = RegExp(r'^(.+?)(_\d+)?$');

/// The stem of [stem]'s family: the stem without a trailing `_<digits>`.
String familyBase(String stem) => _familyStem.firstMatch(stem)?[1] ?? stem;

/// The files next to [recording] with the same extension whose stem is the
/// family base or the base plus `_<n>`, in order. The unsuffixed file comes
/// first.
List<File> familyMembers(File recording) {
  final ext = p.extension(recording.path).toLowerCase();
  final base = familyBase(p.basenameWithoutExtension(recording.path));
  final suffixed = RegExp('^${RegExp.escape(base)}_(\\d+)\$');
  final found = <(int, File)>[];
  for (final f in recording.parent.listSync().whereType<File>()) {
    if (p.extension(f.path).toLowerCase() != ext) continue;
    final stem = p.basenameWithoutExtension(f.path);
    if (stem == base) {
      found.add((0, f));
    } else {
      final m = suffixed.firstMatch(stem);
      if (m != null) found.add((int.parse(m[1]!), f));
    }
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, f) in found) f];
}

/// How many chunks of [target] seconds a recording of [total] seconds is cut
/// into. A final piece shorter than [max] minus [target] is merged into the
/// chunk before it, so the last chunk is at most [max] long.
int planChunkCount(double total, double target, double max) {
  var count = (total.floor() / target.floor()).ceil();
  if (count < 1) count = 1;
  final last = total - (count - 1) * target;
  if (last < max - target && count > 1) count--;
  return count;
}

/// Why a family of [total] seconds cannot be split with these settings, or
/// null when it can.
String? splitProblem(double total, double target, double max) {
  if (!(target > 0 && target < max)) {
    return 'The target must be above zero and below the max.';
  }
  if (total <= max) {
    return 'Nothing to split: the total (${formatClock(total)}) is not above '
        'the max (${formatClock(max)}).';
  }
  return null;
}

/// The most chunks [describeSplit] names one by one.
const _listedChunks = 6;

/// What a split carries from the originals into the chunks: the family's
/// transcripts, translations and notes as if the recordings were already
/// joined end to end.
class SplitCarry {
  SplitCarry._({
    required this.problems,
    required this.transcript,
    required this.translation,
    required this.missingTranslation,
    required this.notes,
    required this.names,
    required this.lang,
    required this.summaries,
    required this.extractedAudio,
  });

  factory SplitCarry.of(List<CombinePart> parts) {
    final problems = parts.length > 1 ? combineProblems(parts) : <String>[];
    final ok = problems.isEmpty;
    final mapping = defaultSpeakerMapping(parts);
    final transcribed = ok && hasTranscripts(parts);
    final audio = [for (final part in parts) part.extractedAudio];
    return SplitCarry._(
      problems: problems,
      transcript: transcribed ? mergeCues(parts, mapping) : null,
      translation: ok && mergesTranslation(parts)
          ? mergeCues(parts, mapping, translation: true)
          : null,
      missingTranslation: transcribed && parts.first.lang != 'en'
          ? partsMissingTranslation(parts)
          : const [],
      notes: mergeNotes(parts),
      names: transcribed ? combinedSpeakerNames(parts, mapping) : const {},
      lang: parts.first.lang,
      summaries: parts.where((part) => part.hasSummary).length,
      extractedAudio: audio.every((f) => f != null) ? audio.cast<File>() : null,
    );
  }

  /// The reasons the family cannot be joined. Empty when it can.
  final List<String> problems;
  final List<Cue>? transcript;
  final List<Cue>? translation;

  /// The recordings whose missing translation keeps it from being carried.
  final List<String> missingTranslation;
  final List<Note> notes;
  final Map<String, String> names;
  final String lang;

  /// How many of the recordings have a summary.
  final int summaries;

  /// The audio extracted from each video, when every recording has it.
  final List<File>? extractedAudio;
}

/// The cues that start in the stretch from [start] to [end] seconds, with
/// times counted from [start]. A null [end] runs to the last cue.
List<Cue> cuesBetween(List<Cue> cues, double start, double? end) => [
  for (final cue in cues)
    if (cue.start >= start && (end == null || cue.start < end))
      Cue(cue.start - start, cue.end - start, cue.items),
];

/// The notes in the stretch from [start] to [end] seconds, with times counted
/// from [start].
List<Note> notesBetween(List<Note> notes, double start, double? end) => [
  for (final note in notes)
    if (note.time >= start && (end == null || note.time < end))
      note.copyWith(time: note.time - start),
];

String _listed(List<String> items) => items.length < 2
    ? items.join()
    : '${items.take(items.length - 1).join(', ')} and ${items.last}';

/// A plain account of what splitting will do, one statement per entry.
/// [members] are the family's recordings with their lengths in seconds.
List<String> describeSplit(
  List<(String, double)> members,
  String base,
  String ext,
  double target,
  double max, {
  required SplitCarry carry,
}) {
  final total = members.fold(0.0, (sum, m) => sum + m.$2);
  final count = planChunkCount(total, target, max);
  final lines = <String>[];
  if (members.length > 1) {
    lines.add(
      'Joins ${members.length} recordings first, ${formatClock(total)} in '
      'total: ${[for (final (name, s) in members) '$name (${formatClock(s)})'].join(', ')}.',
    );
  }
  final last = total - (count - 1) * target;
  final source = members.length > 1 ? 'that' : '"${members.single.$1}$ext"';
  if (count <= _listedChunks) {
    final chunks = [
      for (var i = 0; i < count; i++)
        '${base}_${i + 1}$ext (${formatClock(i < count - 1 ? target : last)})',
    ];
    lines.add('Cuts $source into $count chunks: ${chunks.join(', ')}.');
  } else {
    lines.add(
      'Cuts $source into $count chunks, ${base}_1$ext to ${base}_$count$ext. '
      'Each is ${formatClock(target)} long and the last is '
      '${formatClock(last)}.',
    );
  }
  final notes = carry.notes.length;
  final carried = [
    if (carry.transcript != null) 'the transcript',
    if (carry.translation != null) 'the translation',
    if (notes > 0) 'your $notes ${notes == 1 ? 'note' : 'notes'}',
  ];
  if (carried.isNotEmpty) {
    final text = _listed(carried);
    final plural = carried.length > 1 || text.endsWith('notes');
    lines.add(
      '${text[0].toUpperCase()}${text.substring(1)} '
      '${plural ? 'are' : 'is'} cut at the same points and kept with the '
      'chunks. A line that runs across a cut stays in the chunk where it '
      'starts.',
    );
  }
  if (carry.missingTranslation.isNotEmpty) {
    lines.add(
      'The translation is left out, because '
      '${carry.missingTranslation.join(', ')} '
      '${carry.missingTranslation.length == 1 ? 'has' : 'have'} none.',
    );
  }
  if (carry.summaries > 0) {
    lines.add(
      'Summaries are not carried over (${carry.summaries} of the recordings '
      '${carry.summaries == 1 ? 'has' : 'have'} one). Generate new ones '
      'afterwards.',
    );
  }
  lines.add(
    '${members.length == 1 ? 'The original moves' : 'The ${members.length} originals move'} '
    'to the trash. You can restore ${members.length == 1 ? 'it' : 'them'} from there.',
  );
  return lines;
}

/// Joins a recording's family and cuts it into even chunks named
/// `<base>_1`, `<base>_2` and so on. Transcripts, translations and notes are
/// cut at the same points. The originals go to the trash.
class RechunkJob extends Job {
  RechunkJob({
    required this.library,
    required this.recording,
    required this.targetSeconds,
    required this.maxSeconds,
    required this.media,
  }) {
    onCancel = media.cancel;
  }

  final Library library;
  final File recording;
  final double targetSeconds;
  final double maxSeconds;
  final MediaTools media;

  /// The chunks written, once the job is done.
  List<File> chunks = const [];

  @override
  Future<void> perform() async {
    if (!(targetSeconds > 0 && targetSeconds < maxSeconds)) {
      throw const JobFailure('the target must be above zero and below the max');
    }
    final members = familyMembers(recording);
    final parts = [
      for (final m in members)
        CombinePart.load(library, m, await media.duration(m) ?? 0),
    ];
    final total = parts.fold(0.0, (sum, part) => sum + part.duration);
    if (total <= maxSeconds) {
      throw JobFailure(
        'the recordings total ${(total / 60).toStringAsFixed(1)} min, '
        'which is not above the max',
      );
    }
    final carry = SplitCarry.of(parts);
    if (carry.problems.isNotEmpty) throw JobFailure(carry.problems.first);

    final folder = recording.parent;
    final ext = p.extension(recording.path);
    final base = familyBase(p.basenameWithoutExtension(recording.path));
    File temp(String label, [String? extension]) =>
        File(p.join(folder.path, '.$base.$label.tmp${extension ?? ext}'));

    final merged = temp('merge');
    final mergedAudio = temp('merge.audio', '.mp3');
    final pieces = <File>[];
    final audioPieces = <File>[];
    final pictures = Directory(p.join(folder.path, '.$base.split.notes.tmp'));
    try {
      for (final part in parts) {
        stageNoteImages(library, part.file, part.notes, pictures);
      }
      File joined = members.first;
      if (members.length > 1) {
        setStatus('Joining ${members.length} recordings');
        await media.concat(members, merged);
        joined = merged;
      }
      File? joinedAudio = carry.extractedAudio?.first;
      if (carry.extractedAudio != null && members.length > 1) {
        await media.concat(carry.extractedAudio!, mergedAudio);
        joinedAudio = mergedAudio;
      }
      final combined = await media.duration(joined) ?? total;
      final count = planChunkCount(combined, targetSeconds, maxSeconds);
      double start(int i) => i * targetSeconds;
      double? length(int i) => i < count - 1 ? targetSeconds : null;
      for (var i = 0; i < count; i++) {
        setStatus('Cutting chunk ${i + 1} of $count');
        final piece = temp('split${i + 1}');
        pieces.add(piece);
        await media.split(joined, piece, start: start(i), length: length(i));
        if (joinedAudio != null) {
          final audio = temp('split${i + 1}.audio', '.mp3');
          audioPieces.add(audio);
          await media.split(
            joinedAudio,
            audio,
            start: start(i),
            length: length(i),
          );
        }
      }

      setStatus('Moving the originals to the trash');
      final trash = Trash(library);
      for (final m in members) {
        trash.trashRecording(m);
      }
      chunks = [
        for (final (i, piece) in pieces.indexed)
          piece.renameSync(p.join(folder.path, '${base}_${i + 1}$ext')),
      ];
      pieces.clear();
      for (final (i, chunk) in chunks.indexed) {
        final end = i < count - 1 ? start(i + 1) : null;
        _writeSidecars(chunk, carry, start(i), end, pictures);
        if (audioPieces.isNotEmpty) {
          library.sidecarDir(chunk).createSync(recursive: true);
          audioPieces[i].renameSync(
            library.sidecarFile(chunk, Sidecar.audio).path,
          );
        }
      }
      audioPieces.clear();
    } finally {
      for (final f in [merged, mergedAudio, ...pieces, ...audioPieces]) {
        if (f.existsSync()) f.deleteSync();
      }
      if (pictures.existsSync()) pictures.deleteSync(recursive: true);
    }
  }

  /// Writes the part of [carry] between [start] and [end] seconds next to
  /// [chunk].
  void _writeSidecars(
    File chunk,
    SplitCarry carry,
    double start,
    double? end,
    Directory pictures,
  ) {
    void write(Sidecar key, String content) {
      library.sidecarFile(chunk, key)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    final transcript = cuesBetween(carry.transcript ?? const [], start, end);
    if (transcript.isNotEmpty) {
      final srt = formatSrt(transcript);
      write(Sidecar.transcriptSrt, srt);
      write(Sidecar.transcriptTxt, srtToPlaintext(srt));
      write(Sidecar.lang, '${carry.lang}\n');
      if (carry.names.isNotEmpty) {
        write(
          Sidecar.speakers,
          const JsonEncoder.withIndent('  ').convert(carry.names),
        );
      }
    }
    final translation = cuesBetween(carry.translation ?? const [], start, end);
    if (translation.isNotEmpty) {
      write(Sidecar.translation, formatSrt(translation));
    }
    final notes = notesBetween(carry.notes, start, end);
    writeNotes(library, chunk, notes);
    claimNoteImages(library, chunk, notes, pictures);
  }
}
