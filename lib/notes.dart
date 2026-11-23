import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'library.dart';
import 'srt.dart';

/// [name] when it is a plain, visible file name, else null.
String? _plainName(String? name) =>
    name != null && p.basename(name) == name && !name.startsWith('.')
    ? name
    : null;

/// A remark the user attached to a moment in a recording.
class Note {
  const Note({
    required this.id,
    required this.time,
    required this.text,
    this.image,
  });

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    time: (json['time'] as num).toDouble(),
    text: json['text'] as String? ?? '',
    image: _plainName(json['image'] as String?),
  );

  final String id;

  /// Where the note sits in the recording, in seconds.
  final double time;
  final String text;

  /// The file name of an attached picture inside the sidecar's notes folder.
  final String? image;

  Note copyWith({double? time, String? text}) => Note(
    id: id,
    time: time ?? this.time,
    text: text ?? this.text,
    image: image,
  );

  /// This note with [image] as its picture, or with none when null.
  Note withImage(String? image) =>
      Note(id: id, time: time, text: text, image: image);

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time,
    'text': text,
    if (image != null) 'image': image,
  };
}

String newNoteId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

/// The notes of [recording], ordered by time.
List<Note> readNotes(Library library, File recording) {
  final file = library.sidecarFile(recording, Sidecar.notes);
  if (!file.existsSync()) return [];
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List) return [];
    return [
      for (final entry in decoded.cast<Map<String, dynamic>>())
        Note.fromJson(entry),
    ]..sort((a, b) => a.time.compareTo(b.time));
  } on FormatException {
    return [];
  }
}

/// Stores [notes] for [recording], ordered by time. With no notes, the file
/// is removed.
void writeNotes(Library library, File recording, List<Note> notes) {
  final file = library.sidecarFile(recording, Sidecar.notes);
  if (notes.isEmpty) {
    if (file.existsSync()) file.deleteSync();
    return;
  }
  final sorted = [...notes]..sort((a, b) => a.time.compareTo(b.time));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ')
        .convert([for (final note in sorted) note.toJson()]),
  );
}

/// The order a transcript is read in with its notes: each entry is a cue's
/// index (an [int]) or a [Note]. A note comes after the cue it falls in, just
/// before the first cue that starts later than it.
List<Object> transcriptRows(List<Cue> cues, List<Note> notes) {
  final sorted = [...notes]..sort((a, b) => a.time.compareTo(b.time));
  final rows = <Object>[];
  var next = 0;
  for (final (i, cue) in cues.indexed) {
    while (next < sorted.length && sorted[next].time < cue.start) {
      rows.add(sorted[next++]);
    }
    rows.add(i);
  }
  rows.addAll(sorted.skip(next));
  return rows;
}

/// A note as one line of summary input, naming its picture as
/// "Picture [picture]" when it has one that is being sent along. Null when
/// the note has nothing to say.
String? noteLine(Note note, {int? picture}) {
  final text = note.text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
  final at = formatClock(note.time);
  if (text.isEmpty) return picture == null ? null : '[Picture $picture at $at]';
  return picture == null
      ? '[Note at $at: $text]'
      : '[Note at $at, with Picture $picture: $text]';
}

/// The folder inside a recording's sidecar that holds its notes' pictures.
Directory noteImagesDir(Library library, File recording) =>
    Directory(p.join(library.sidecarDir(recording).path, 'notes'));

/// The picture attached to [note], when it has one and the file exists.
File? noteImage(Library library, File recording, Note note) {
  final name = note.image;
  if (name == null) return null;
  final file = File(p.join(noteImagesDir(library, recording).path, name));
  return file.existsSync() ? file : null;
}

/// Copies [source] into the recording's notes folder as the picture of the
/// note with [noteId]. Returns the stored file's name.
String storeNoteImage(
  Library library,
  File recording,
  File source,
  String noteId,
) {
  final ext = p.extension(source.path).toLowerCase();
  final name = '$noteId${ext.isEmpty ? '.jpg' : ext}';
  final dir = noteImagesDir(library, recording)..createSync(recursive: true);
  source.copySync(p.join(dir.path, name));
  return name;
}

/// Removes the picture file of [note], if it has one.
void removeNoteImage(Library library, File recording, Note note) {
  noteImage(library, recording, note)?.deleteSync();
}

/// Copies the pictures of [notes], which belong to [recording], into
/// [staging], keeping their file names.
void stageNoteImages(
  Library library,
  File recording,
  List<Note> notes,
  Directory staging,
) {
  for (final note in notes) {
    final image = noteImage(library, recording, note);
    if (image == null) continue;
    staging.createSync(recursive: true);
    image.copySync(p.join(staging.path, note.image));
  }
}

/// Moves the staged pictures of [notes] from [staging] into the notes folder
/// of [recording].
void claimNoteImages(
  Library library,
  File recording,
  List<Note> notes,
  Directory staging,
) {
  for (final note in notes) {
    final name = note.image;
    if (name == null) continue;
    final staged = File(p.join(staging.path, name));
    if (!staged.existsSync()) continue;
    final dir = noteImagesDir(library, recording)..createSync(recursive: true);
    staged.renameSync(p.join(dir.path, name));
  }
}
