import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'job.dart';
import 'library.dart';
import 'media_tools.dart';
import 'notes.dart';
import 'rechunk.dart';
import 'srt.dart';
import 'transcript_edits.dart';
import 'trash.dart';

/// One recording going into a combination, with what it carries.
class CombinePart {
  CombinePart({
    required this.file,
    required this.duration,
    required this.lang,
    required this.transcript,
    required this.translation,
    required this.names,
    required this.overrides,
    required this.hasSummary,
    required this.extractedAudio,
    this.notes = const [],
  });

  factory CombinePart.load(Library library, File file, double duration) {
    List<Cue>? cues(Sidecar key) {
      final srt = library.sidecarFile(file, key);
      return srt.existsSync() ? parseSrt(srt.readAsStringSync()) : null;
    }

    final audio = library.sidecarFile(file, Sidecar.audio);
    return CombinePart(
      file: file,
      duration: duration,
      lang: library.langOf(file),
      transcript: cues(Sidecar.transcriptSrt),
      translation: cues(Sidecar.translation),
      names: library.readStringMap(file, Sidecar.speakers),
      overrides: library.readStringMap(file, Sidecar.overrides),
      hasSummary: library.sidecarFile(file, Sidecar.summary).existsSync(),
      extractedAudio: audio.existsSync() ? audio : null,
      notes: readNotes(library, file),
    );
  }

  final File file;
  final double duration;
  final String lang;
  final List<Cue>? transcript;
  final List<Cue>? translation;
  final Map<String, String> names;
  final Map<String, String> overrides;
  final bool hasSummary;
  final List<Note> notes;

  /// The audio extracted from a video, if it has been transcribed.
  final File? extractedAudio;

  String get name => p.basenameWithoutExtension(file.path);

  /// The speakers in this part's transcript, in numeric order.
  List<String> get speakers =>
      speakerLineCounts(transcript ?? const [], overrides).keys.toList();

  /// The first line [speaker] says, to help recognize them.
  String? sampleLine(String speaker) {
    final cues = transcript ?? const <Cue>[];
    for (var c = 0; c < cues.length; c++) {
      for (var i = 0; i < cues[c].items.length; i++) {
        if (effectiveSpeaker(cues, overrides, c, i) == speaker) {
          return cues[c].items[i].text;
        }
      }
    }
    return null;
  }
}

int _suffix(String stem) {
  final m = RegExp(r'_(\d+)$').firstMatch(stem);
  return m == null ? 0 : int.parse(m[1]!);
}

/// Orders recordings so that the pieces of one family follow each other by
/// number, and families follow each other by name.
int compareForCombining(File a, File b) {
  final x = p.basenameWithoutExtension(a.path);
  final y = p.basenameWithoutExtension(b.path);
  final byFamily = familyBase(x).compareTo(familyBase(y));
  if (byFamily != 0) return byFamily;
  final bySuffix = _suffix(x).compareTo(_suffix(y));
  return bySuffix != 0 ? bySuffix : x.compareTo(y);
}

/// The reasons [parts] cannot be combined. Empty when they can.
List<String> combineProblems(List<CombinePart> parts) {
  final problems = <String>[];
  if (parts.length < 2) {
    return ['Choose at least two recordings.'];
  }
  final extensions = {
    for (final part in parts) p.extension(part.file.path).toLowerCase(),
  };
  if (extensions.length > 1) {
    problems.add(
      'The recordings are in different formats (${extensions.join(', ')}). '
      'Only recordings of the same format can be joined.',
    );
  }
  final missing = [
    for (final part in parts)
      if (part.transcript == null) part.name,
  ];
  if (missing.isNotEmpty && missing.length < parts.length) {
    problems.add(
      'Some recordings have no transcript: ${missing.join(', ')}. '
      'Recordings can be joined when all of them have a transcript or none '
      'do.',
    );
  }
  if (missing.isEmpty) {
    final langs = {for (final part in parts) part.lang};
    if (langs.length > 1) {
      problems.add(
        'The transcripts are in different languages (${langs.join(', ')}).',
      );
    }
  }
  return problems;
}

bool hasTranscripts(List<CombinePart> parts) =>
    parts.every((part) => part.transcript != null);

/// The parts whose missing translation keeps the translation from being
/// merged. Empty when every part has one, or none does.
List<String> partsMissingTranslation(List<CombinePart> parts) {
  final missing = [
    for (final part in parts)
      if (part.translation == null) part.name,
  ];
  return missing.length == parts.length ? const [] : missing;
}

bool mergesTranslation(List<CombinePart> parts) =>
    hasTranscripts(parts) && parts.every((part) => part.translation != null);

/// The family base when every part belongs to one family, else the first
/// part's name marked as combined.
String defaultCombinedName(List<CombinePart> parts) {
  final bases = {for (final part in parts) familyBase(part.name)};
  return bases.length == 1 ? bases.single : '${parts.first.name} (combined)';
}

/// For each part, which combined speaker each of its speakers becomes.
typedef SpeakerMapping = List<Map<String, String>>;

String _key(String name) => name.trim().toLowerCase();

/// Matches each part's speakers to the combined set: by custom name first,
/// then by number. Two speakers of one part never share a combined speaker:
/// when a part's number is already claimed, or belongs to a differently
/// named person, the speaker takes the lowest unnamed combined speaker that
/// is still free, or a new number.
SpeakerMapping defaultSpeakerMapping(List<CombinePart> parts) {
  final combinedNames = <String, String?>{};
  final mapping = <Map<String, String>>[];
  for (final part in parts) {
    final map = <String, String>{};
    final claimed = <String>{};
    void assign(String speaker, String target) {
      combinedNames[target] ??= part.names[speaker];
      claimed.add(target);
      map[speaker] = target;
    }

    final rest = <String>[];
    for (final speaker in part.speakers) {
      final name = part.names[speaker];
      final match = name == null
          ? null
          : combinedNames.entries
                .where((e) => e.value != null && _key(e.value!) == _key(name))
                .map((e) => e.key)
                .firstOrNull;
      match == null ? rest.add(speaker) : assign(speaker, match);
    }
    for (final speaker in rest) {
      final named = part.names[speaker] != null;
      final ownNumberFits =
          !claimed.contains(speaker) &&
          !(named && combinedNames[speaker] != null);
      if (ownNumberFits) {
        assign(speaker, speaker);
        continue;
      }
      final free = combinedNames.entries
          .where((e) => e.value == null && !claimed.contains(e.key))
          .map((e) => e.key)
          .firstOrNull;
      assign(speaker, free ?? nextSpeakerId(combinedNames.keys));
    }
    mapping.add({for (final speaker in part.speakers) speaker: map[speaker]!});
  }
  return mapping;
}

/// The names of the combined speakers under [mapping]: for each, the first
/// name any part gives a speaker mapped to it.
Map<String, String> combinedSpeakerNames(
  List<CombinePart> parts,
  SpeakerMapping mapping,
) {
  final names = <String, String>{};
  for (final (i, part) in parts.indexed) {
    for (final MapEntry(key: from, value: to) in mapping[i].entries) {
      final name = part.names[from];
      if (name != null) names.putIfAbsent(to, () => name);
    }
  }
  return names;
}

/// Where each part starts in the combined recording, in seconds.
List<double> partOffsets(List<CombinePart> parts) {
  final offsets = <double>[];
  var at = 0.0;
  for (final part in parts) {
    offsets.add(at);
    at += part.duration;
  }
  return offsets;
}

/// The parts' notes as one list, each moved to its time in the combined
/// recording.
List<Note> mergeNotes(List<CombinePart> parts) {
  final offsets = partOffsets(parts);
  return [
    for (final (n, part) in parts.indexed)
      for (final note in part.notes)
        note.copyWith(time: note.time + offsets[n]),
  ];
}

/// The parts' transcripts (or translations) as one, with timestamps shifted
/// to each part's start and speakers renumbered through [mapping]. Manual
/// speaker changes are written into the labels.
List<Cue> mergeCues(
  List<CombinePart> parts,
  SpeakerMapping mapping, {
  bool translation = false,
}) {
  final offsets = partOffsets(parts);
  final merged = <Cue>[];
  for (final (n, part) in parts.indexed) {
    final cues = (translation ? part.translation : part.transcript)!;
    for (final (c, cue) in cues.indexed) {
      merged.add(
        Cue(cue.start + offsets[n], cue.end + offsets[n], [
          for (final (i, item) in cue.items.indexed)
            CueItem(
              mapping[n][part.overrides['$c:$i'] ?? item.speaker] ??
                  part.overrides['$c:$i'] ??
                  item.speaker,
              item.text,
            ),
        ]),
      );
    }
  }
  return merged;
}

String _speakerLabel(Map<String, String> names, String id) =>
    names[id] ?? 'Speaker $id';

/// A plain account of what combining [parts] into [outputStem] will do, one
/// statement per entry.
List<String> describeCombination(
  List<CombinePart> parts,
  SpeakerMapping mapping,
  String outputStem,
) {
  final lines = <String>[];
  final ext = p.extension(parts.first.file.path);
  final offsets = partOffsets(parts);
  final total = offsets.last + parts.last.duration;
  lines.add(
    'Joins ${parts.length} recordings into "$outputStem$ext", '
    '${formatClock(total)} long, in this order: '
    '${[for (final (i, part) in parts.indexed) '${part.name} (starts at ${formatClock(offsets[i])})'].join(', ')}.',
  );
  if (hasTranscripts(parts)) {
    lines.add(
      'The transcripts are merged into one, with each part\'s timestamps '
      'shifted to where it starts.',
    );
    if (parts.first.lang != 'en') {
      final missing = partsMissingTranslation(parts);
      if (mergesTranslation(parts)) {
        lines.add('The translations are merged the same way.');
      } else if (missing.isNotEmpty) {
        lines.add(
          'The translation is left out, because ${missing.join(', ')} '
          '${missing.length == 1 ? 'has' : 'have'} none. Translate the '
          'combined recording afterwards.',
        );
      }
    }
    final names = combinedSpeakerNames(parts, mapping);
    final sources = <String, List<String>>{};
    for (final (i, part) in parts.indexed) {
      for (final MapEntry(key: from, value: to) in mapping[i].entries) {
        sources
            .putIfAbsent(to, () => [])
            .add('${_speakerLabel(part.names, from)} in ${part.name}');
      }
    }
    for (final MapEntry(key: id, value: from) in sources.entries) {
      lines.add('${_speakerLabel(names, id)} is ${from.join(', ')}.');
    }
    if (parts.any((part) => part.overrides.isNotEmpty)) {
      lines.add('Manual speaker changes are kept.');
    }
  } else {
    lines.add(
      'None of the recordings has a transcript, so only the audio is joined.',
    );
  }
  final noteCount = parts.fold(0, (sum, part) => sum + part.notes.length);
  if (noteCount > 0) {
    lines.add(
      'Your $noteCount ${noteCount == 1 ? 'note is' : 'notes are'} kept, '
      'moved to ${noteCount == 1 ? 'its' : 'their'} new '
      '${noteCount == 1 ? 'time' : 'times'}.',
    );
  }
  final summaries = parts.where((part) => part.hasSummary).length;
  if (summaries > 0) {
    lines.add(
      'Summaries are not carried over ($summaries of the recordings '
      '${summaries == 1 ? 'has' : 'have'} one). Generate a new one '
      'afterwards.',
    );
  }
  lines.add(
    'The ${parts.length} originals move to the trash with everything '
    'attached to them. You can restore them from there.',
  );
  return lines;
}

/// Joins [parts] into one recording named [outputStem], with their
/// transcripts and translations merged. The originals go to the trash.
class CombineJob extends Job {
  CombineJob({
    required this.library,
    required this.parts,
    required this.mapping,
    required this.outputStem,
    required this.media,
  }) {
    onCancel = media.cancel;
  }

  final Library library;
  final List<CombinePart> parts;
  final SpeakerMapping mapping;
  final String outputStem;
  final MediaTools media;

  /// The combined recording, once the job is done.
  File? result;

  @override
  Future<void> perform() async {
    final problems = combineProblems(parts);
    if (problems.isNotEmpty) throw JobFailure(problems.first);
    final String stem;
    try {
      stem = library.checkName(outputStem);
    } on LibraryException catch (e) {
      throw JobFailure(e.message);
    }
    final folder = parts.first.file.parent;
    final ext = p.extension(parts.first.file.path);
    final ownStems = {for (final part in parts) part.name};
    if (!ownStems.contains(stem) && library.stemTaken(folder, stem)) {
      throw const JobFailure('A recording with that name already exists here');
    }

    final joined = File(p.join(folder.path, '.$stem.combine.tmp$ext'));
    final joinedAudio = File(
      p.join(folder.path, '.$stem.combine.audio.tmp.mp3'),
    );
    final extracted = [for (final part in parts) part.extractedAudio];
    final pictures = Directory(p.join(folder.path, '.$stem.combine.notes.tmp'));
    try {
      setStatus('Joining ${parts.length} recordings');
      await media.concat([for (final part in parts) part.file], joined);
      final keepAudio = extracted.every((f) => f != null);
      if (keepAudio) {
        setStatus('Joining the extracted audio');
        await media.concat(extracted.cast<File>(), joinedAudio);
      }

      final transcripts = hasTranscripts(parts);
      final transcript = transcripts
          ? formatSrt(mergeCues(parts, mapping))
          : null;
      final translation = mergesTranslation(parts)
          ? formatSrt(mergeCues(parts, mapping, translation: true))
          : null;
      final names = combinedSpeakerNames(parts, mapping);
      final notes = mergeNotes(parts);
      for (final part in parts) {
        stageNoteImages(library, part.file, part.notes, pictures);
      }

      setStatus('Moving the originals to the trash');
      final trash = Trash(library);
      for (final part in parts) {
        trash.trashRecording(part.file);
      }

      final target = joined.renameSync(p.join(folder.path, '$stem$ext'));
      void write(Sidecar key, String content) {
        library.sidecarFile(target, key)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      if (keepAudio) {
        library.sidecarDir(target).createSync(recursive: true);
        joinedAudio.renameSync(library.sidecarFile(target, Sidecar.audio).path);
      }
      if (transcript != null) {
        write(Sidecar.transcriptSrt, transcript);
        write(Sidecar.transcriptTxt, srtToPlaintext(transcript));
        write(Sidecar.lang, '${parts.first.lang}\n');
      }
      if (translation != null) write(Sidecar.translation, translation);
      if (names.isNotEmpty) {
        write(
          Sidecar.speakers,
          const JsonEncoder.withIndent('  ').convert(names),
        );
      }
      writeNotes(library, target, notes);
      claimNoteImages(library, target, notes, pictures);
      result = target;
    } finally {
      for (final f in [joined, joinedAudio]) {
        if (f.existsSync()) f.deleteSync();
      }
      if (pictures.existsSync()) pictures.deleteSync(recursive: true);
    }
  }
}
