import 'dart:io';

import 'package:path/path.dart' as p;

import 'job.dart';
import 'languages.dart';
import 'library.dart';
import 'media_tools.dart';
import 'notes.dart';
import 'prompts.dart';
import 'ruby.dart';
import 'srt.dart';
import 'text_generator.dart';
import 'transcription_job.dart';

/// The cue text of [srt], one of [recording]'s SRT files, as "Name: text"
/// lines, with speaker overrides and custom names applied. [notes] are
/// placed between the lines at their times. Null when the file does not
/// exist.
String? speakerLines(
  Library library,
  File recording,
  File srt, {
  List<Note> notes = const [],
  Map<String, int> pictureNumbers = const {},
}) {
  if (!srt.existsSync()) return null;
  final cues = parseSrt(srt.readAsStringSync());
  final overrides = library.readStringMap(recording, Sidecar.overrides);
  final names = library.readStringMap(recording, Sidecar.speakers);
  final lines = <String>[];
  for (final row in transcriptRows(cues, notes)) {
    if (row is Note) {
      final line = noteLine(row, picture: pictureNumbers[row.id]);
      if (line != null) lines.add(line);
      continue;
    }
    final ci = row as int;
    for (final (ii, item) in cues[ci].items.indexed) {
      final speaker = overrides['$ci:$ii'] ?? item.speaker;
      lines.add(
        speaker == null
            ? item.text
            : '${names[speaker] ?? 'Speaker $speaker'}: ${item.text}',
      );
    }
  }
  return lines.join('\n');
}

/// [recording]'s text in [lang]: the transcript when the recording is in
/// [lang], else its translation into [lang].
File textIn(Library library, File recording, String lang) =>
    library.langOf(recording) == lang
    ? library.sidecarFile(recording, Sidecar.transcriptSrt)
    : library.translationFile(recording, lang);

/// The English transcript as speaker lines with the user's notes in place,
/// as given to the summarizer. Reads the translation, or the transcript
/// itself for an English recording. Null when that file does not exist.
String? translatedTranscriptText(Library library, File recording) {
  return speakerLines(
    library,
    recording,
    textIn(library, recording, englishLang),
    notes: readNotes(library, recording),
  );
}

/// What the summarizer is given for one recording.
class SummaryInput {
  const SummaryInput(this.text, this.images, {required this.hasNotes});

  /// The English transcript with notes in place.
  final String text;

  /// The notes' pictures, numbered as the note lines name them.
  final List<PromptImage> images;
  final bool hasNotes;
}

/// The summary input for [recording] in [lang] with its notes' pictures
/// attached. Null when there is no text in [lang] to summarize.
SummaryInput? summaryInput(
  Library library,
  File recording, {
  String lang = englishLang,
}) {
  final notes = readNotes(library, recording);
  final numbers = <String, int>{};
  final images = <PromptImage>[];
  for (final note in notes) {
    final file = noteImage(library, recording, note);
    if (file == null) continue;
    numbers[note.id] = images.length + 1;
    final ext = p.extension(file.path).toLowerCase();
    images.add(
      PromptImage(
        label: 'Picture ${images.length + 1}:',
        bytes: file.readAsBytesSync(),
        mimeType: ext == '.png' ? 'image/png' : 'image/jpeg',
      ),
    );
  }
  final text = speakerLines(
    library,
    recording,
    textIn(library, recording, lang),
    notes: notes,
    pictureNumbers: numbers,
  );
  if (text == null || text.isEmpty) return null;
  return SummaryInput(
    text,
    images,
    hasNotes: images.isNotEmpty || notes.any((n) => n.text.trim().isNotEmpty),
  );
}

/// Whether [recording] has a note with text.
bool hasTextNotes(Library library, File recording) =>
    readNotes(library, recording).any((n) => n.text.trim().isNotEmpty);

/// [prompt] with [recording]'s file name and the user's note about it.
String _aboutRecording(String prompt, Library library, File recording) =>
    withBackground(
      prompt,
      title: p.basenameWithoutExtension(recording.path),
      note: library.contextOf(recording),
    );

Future<String> _generate(
  Job job,
  TextGenerator generator, {
  required String prompt,
  required String input,
  List<PromptImage> images = const [],
}) async {
  job.resetOutput();
  final chunks = generator.generate(
    job.openClient(),
    prompt: prompt,
    input: input,
    images: images,
  );
  await for (final chunk in chunks) {
    job.appendOutput(chunk);
  }
  final text = job.output.toString().trim();
  if (text.isEmpty) throw const JobFailure('empty response from the model');
  return text;
}

/// Translates [recording]'s transcript into [to], storing the plain
/// translation and, when the model adds readings, the translation with them.
Future<void> translateRecording(
  Job job,
  Library library,
  File recording,
  TextGenerator generator,
  LanguageList languages, {
  String to = englishLang,
}) async {
  final srt = library.sidecarFile(recording, Sidecar.transcriptSrt);
  if (!srt.existsSync()) throw const JobFailure('no source transcript');
  final out = await _generate(
    job,
    generator,
    prompt: _aboutRecording(
      buildTranslationPrompt(
        languages.resolve(library.langOf(recording)),
        languages.resolve(to),
      ),
      library,
      recording,
    ),
    input: srt.readAsStringSync(),
  );
  final withReadings = stripCodeFence(out);
  library
      .translationFile(recording, to)
      .writeAsStringSync('${stripRuby(withReadings)}\n');
  final readings = library.translationFuriganaFile(recording, to);
  if (hasRuby(withReadings)) {
    readings.writeAsStringSync('$withReadings\n');
  } else if (readings.existsSync()) {
    readings.deleteSync();
  }
}

/// Summarizes [recording] in [lang] from its text in that language.
Future<void> summarizeRecording(
  Job job,
  Library library,
  File recording,
  TextGenerator generator,
  LanguageList languages, {
  String lang = englishLang,
}) async {
  final input = summaryInput(library, recording, lang: lang);
  if (input == null) {
    throw JobFailure(
      'no ${languages.resolve(lang).name} translation yet, translate this '
      'recording first',
    );
  }
  final out = await _generate(
    job,
    generator,
    prompt: _aboutRecording(
      summaryPromptFor(
        notes: input.hasNotes,
        pictures: input.images.isNotEmpty,
        language: lang == englishLang ? null : languages.resolve(lang),
      ),
      library,
      recording,
    ),
    input: input.text,
    images: input.images,
  );
  library.summaryFile(recording, lang).writeAsStringSync('$out\n');
}

class TranslationJob extends Job {
  TranslationJob({
    required this.library,
    required this.recording,
    required this.generator,
    required this.languages,
    this.to = englishLang,
    super.clientFactory,
  });

  final Library library;
  final File recording;
  final TextGenerator generator;
  final LanguageList languages;

  /// The language to translate into.
  final String to;

  @override
  Future<void> perform() {
    setStatus(
      'Translating into ${languages.resolve(to).name} with ${generator.model}',
    );
    return translateRecording(
      this,
      library,
      recording,
      generator,
      languages,
      to: to,
    );
  }
}

/// Summarizes a recording in [lang], translating it into [lang] first when
/// it has no text in that language.
class SummaryJob extends Job {
  SummaryJob({
    required this.library,
    required this.recording,
    required this.generator,
    required this.languages,
    this.lang = englishLang,
    super.clientFactory,
  });

  final Library library;
  final File recording;
  final TextGenerator generator;
  final LanguageList languages;
  final String lang;

  @override
  Future<void> perform() async {
    final name = languages.resolve(lang).name;
    if (!textIn(library, recording, lang).existsSync()) {
      setStatus('Translating into $name with ${generator.model}');
      await translateRecording(
        this,
        library,
        recording,
        generator,
        languages,
        to: lang,
      );
    }
    setStatus('Summarizing in $name with ${generator.model}');
    await summarizeRecording(
      this,
      library,
      recording,
      generator,
      languages,
      lang: lang,
    );
  }
}

enum FolderSummaryMode {
  flat('flat'),
  hierarchical('hier');

  const FolderSummaryMode(this.fileKey);

  /// The mode's name in the summary file name.
  final String fileKey;
}

/// Summarizes every recording in a folder as one document. Transcribes,
/// translates and (in hierarchical mode) summarizes the recordings that lack
/// those files first.
class FolderSummaryJob extends Job {
  FolderSummaryJob({
    required this.library,
    required this.folder,
    required this.mode,
    required this.language,
    required this.languages,
    required this.generator,
    required this.geminiKey,
    required this.geminiModel,
    this.media,
    super.clientFactory,
    this.pollInterval = const Duration(seconds: 2),
  });

  final Library library;
  final Directory folder;
  final FolderSummaryMode mode;

  /// The language used to transcribe recordings that have no transcript.
  final Language language;

  /// The languages of recordings being translated.
  final LanguageList languages;
  final TextGenerator generator;
  final String geminiKey;
  final String geminiModel;
  final MediaTools? media;
  final Duration pollInterval;

  @override
  Future<void> perform() async {
    final sources = [for (final r in library.recordingsIn(folder)) r.file];
    if (sources.isEmpty) throw const JobFailure('no audio in folder');
    final n = sources.length;
    String label(int i, File f) => '${i + 1}/$n: ${p.basename(f.path)}';

    for (final (i, file) in sources.indexed) {
      if (library.sidecarFile(file, Sidecar.transcriptSrt).existsSync()) {
        continue;
      }
      if (geminiKey.isEmpty || geminiModel.isEmpty) {
        throw const JobFailure(
          'transcription needs a Gemini API key and model in Settings',
        );
      }
      try {
        await transcribeRecording(
          this,
          library: library,
          recording: file,
          language: language,
          apiKey: geminiKey,
          model: geminiModel,
          media: media,
          pollInterval: pollInterval,
        );
      } on JobFailure catch (e) {
        throw JobFailure(
          'transcribe failed on ${p.basename(file.path)}: ${e.message}',
        );
      }
      setStatus('Transcribed ${label(i, file)}');
    }

    for (final (i, file) in sources.indexed) {
      if (textIn(library, file, englishLang).existsSync()) {
        continue;
      }
      setStatus('Translating ${label(i, file)}');
      await translateRecording(this, library, file, generator, languages);
    }

    if (mode == FolderSummaryMode.hierarchical) {
      for (final (i, file) in sources.indexed) {
        if (library.summaryFile(file, englishLang).existsSync()) continue;
        setStatus('Summarizing ${label(i, file)}');
        await summarizeRecording(this, library, file, generator, languages);
      }
    }

    setStatus('Synthesizing the summary of $n recordings');
    final parts = [
      for (final file in sources)
        '## ${p.basenameWithoutExtension(file.path)}\n\n${_content(file)}',
    ];
    final out = await _generate(
      this,
      generator,
      prompt: mode == FolderSummaryMode.flat
          ? folderFlatPromptFor(
              notes: sources.any((f) => hasTextNotes(library, f)),
            )
          : folderHierPrompt,
      input: parts.join('\n\n'),
    );
    library.folderSummaryFile(folder, mode.fileKey).writeAsStringSync('$out\n');
  }

  String _content(File file) {
    if (mode == FolderSummaryMode.hierarchical) {
      return library.summaryFile(file, englishLang).readAsStringSync().trim();
    }
    return translatedTranscriptText(library, file) ?? '';
  }
}
