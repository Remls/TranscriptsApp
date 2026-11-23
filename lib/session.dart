import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'combine.dart';
import 'durations.dart';
import 'job.dart';
import 'language_lookup.dart';
import 'languages.dart';
import 'library.dart';
import 'media_tools.dart';
import 'notes.dart';
import 'rechunk.dart';
import 'settings.dart';
import 'srt.dart';
import 'text_generator.dart';
import 'text_jobs.dart';
import 'transcript_edits.dart';
import 'transcription_job.dart';

const playbackSpeeds = [0.5, 1.0, 1.25, 1.5, 2.0];

const _lastAudioKey = 'lastAudio';
const _lastPositionKey = 'lastPositionMs';
const _speedKey = 'playbackSpeed';

enum JobKind {
  transcribe,
  translate,
  summary,
  folderFlat,
  folderHierarchical,
  rechunk,
  combine,
}

JobKind folderJobKind(FolderSummaryMode mode) {
  return mode == FolderSummaryMode.flat
      ? JobKind.folderFlat
      : JobKind.folderHierarchical;
}

/// The open recording, its transcript and its player, plus the running jobs.
class Session extends ChangeNotifier {
  Session(this.library, this.prefs, this.settings, this.media) {
    _positionSub = player.positionStream.listen(_onPosition);
    _stateSub = player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        player.pause();
        player.seek(Duration.zero);
      }
      if (!s.playing) persistPosition();
    });
  }

  final Library library;
  final SharedPreferences prefs;
  final Settings settings;
  final MediaTools media;
  late final languages = LanguageList(library.root)
    ..addListener(notifyListeners);
  late final languageLookup = LanguageLookup(
    catalog: LanguageCatalog.load(),
    askGemini: (name) async {
      if (settings.geminiKey.isEmpty) {
        throw const LookupException('Add a Gemini API key in Settings first');
      }
      final client = http.Client();
      try {
        return await askGeminiForLanguage(
          client,
          apiKey: settings.geminiKey,
          model: settings.geminiModel,
          name: name,
        );
      } finally {
        client.close();
      }
    },
  );
  late final durations = DurationCache(prefs, media);
  final player = AudioPlayer();
  final activeIndex = ValueNotifier<int>(-1);
  final translationActiveIndex = ValueNotifier<int>(-1);

  Recording? recording;
  List<Cue> cues = const [];
  List<Cue> translatedCues = const [];
  String? summary;
  List<Note> notes = const [];
  Map<String, String> speakerNames = const {};
  Map<String, String> speakerOverrides = const {};
  String? loadError;

  /// The latest job per kind and target, kept after it ends so its outcome
  /// can be shown. The target is a recording's or folder's path.
  final _jobs = <(JobKind, String), Job>{};

  /// Called when a job starts and when it ends, with its kind and target.
  void Function(JobKind kind, String target, Job job)? onJobStarted;
  void Function(JobKind kind, String target, Job job)? onJobFinished;

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<PlayerState> _stateSub;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);

  double get speed => prefs.getDouble(_speedKey) ?? 1.0;

  Future<void> open(Recording r, {Duration position = Duration.zero}) async {
    recording = r;
    _loadSidecars();
    activeIndex.value = -1;
    translationActiveIndex.value = -1;
    loadError = null;
    notifyListeners();
    await prefs.setString(_lastAudioKey, r.relPath);
    await prefs.setInt(_lastPositionKey, position.inMilliseconds);
    try {
      await player.setAudioSource(
        AudioSource.file(
          library.playbackAudio(r.file).path,
          tag: MediaItem(
            id: r.relPath,
            title: r.name,
            album: r.file.parent.path == library.root.path
                ? null
                : p.basename(r.file.parent.path),
          ),
        ),
        initialPosition: position,
      );
      await player.setSpeed(speed);
    } on PlayerException catch (e) {
      loadError = e.message ?? 'This file could not be played';
      notifyListeners();
    }
  }

  void _loadSidecars() {
    final file = recording!.file;
    cues = _readCues(file, Sidecar.transcriptSrt);
    translatedCues = _readCues(file, Sidecar.translation);
    final summaryFile = library.sidecarFile(file, Sidecar.summary);
    summary = summaryFile.existsSync() ? summaryFile.readAsStringSync() : null;
    speakerNames = library.readStringMap(file, Sidecar.speakers);
    speakerOverrides = library.readStringMap(file, Sidecar.overrides);
    notes = readNotes(library, file);
    _updateActive(player.position);
  }

  List<Cue> _readCues(File recording, Sidecar key) {
    final srt = library.sidecarFile(recording, key);
    return srt.existsSync() ? parseSrt(srt.readAsStringSync()) : const [];
  }

  /// Closes the open recording and forgets it as the one to restore.
  Future<void> close() async {
    await player.stop();
    recording = null;
    cues = const [];
    translatedCues = const [];
    summary = null;
    notes = const [];
    loadError = null;
    notifyListeners();
    await prefs.remove(_lastAudioKey);
  }

  /// Reopens the open recording at [file], its location after a rename or
  /// move, keeping the playback position.
  Future<void> reopenAt(File file) {
    return open(library.describe(file), position: player.position);
  }

  /// Applies [change] to the open recording's stored files, then reloads
  /// them.
  void edit(void Function(TranscriptEditor editor) change) {
    change(TranscriptEditor(library, recording!.file));
    _loadSidecars();
    notifyListeners();
  }

  /// The picture attached to [note] in the open recording, if any.
  File? noteImageOf(Note note) => noteImage(library, recording!.file, note);

  /// Adds [note] to the open recording, or replaces the note with its id.
  /// [newImage] becomes its picture, and [removeImage] drops the one it has.
  void saveNote(Note note, {File? newImage, bool removeImage = false}) {
    final file = recording!.file;
    var saved = note;
    if (newImage != null || removeImage) {
      removeNoteImage(library, file, note);
      saved = note.withImage(
        newImage == null
            ? null
            : storeNoteImage(library, file, newImage, note.id),
      );
    }
    writeNotes(library, file, [
      for (final n in notes)
        if (n.id != note.id) n,
      saved,
    ]);
    _loadSidecars();
    notifyListeners();
  }

  void deleteNote(Note note) {
    removeNoteImage(library, recording!.file, note);
    writeNotes(library, recording!.file, [
      for (final n in notes)
        if (n.id != note.id) n,
    ]);
    _loadSidecars();
    notifyListeners();
  }

  bool get anyJobRunning =>
      _jobs.values.any((job) => job.state == JobState.running);

  /// Whether a job is running on the recording at [relPath].
  bool recordingBusy(String relPath) => _jobs.entries.any(
    (e) => e.key.$2 == relPath && e.value.state == JobState.running,
  );

  /// Whether a job is running on [folder] or on a recording inside it.
  bool folderBusy(Directory folder) {
    final prefix = '${p.basename(folder.path)}/';
    return _jobs.entries.any(
      (e) =>
          e.value.state == JobState.running &&
          (e.key.$2 == folder.path || e.key.$2.startsWith(prefix)),
    );
  }

  Job? jobFor(JobKind kind, String target) => _jobs[(kind, target)];

  bool isRunning(JobKind kind, String target) =>
      jobFor(kind, target)?.state == JobState.running;

  void _start(JobKind kind, String target, Job job) {
    _jobs[(kind, target)] = job;
    onJobStarted?.call(kind, target, job);
    notifyListeners();
    job.run().then((_) {
      onJobFinished?.call(kind, target, job);
      final open = recording;
      if (open != null) {
        recording = library.describe(open.file);
        _loadSidecars();
      }
      notifyListeners();
    });
  }

  /// Starts transcribing [r]. Returns a message instead when a setting is
  /// missing.
  /// The language preselected for new transcriptions, or [defaultLang] when
  /// the chosen one has left the list.
  String get transcribeLang {
    final code = settings.transcribeLang;
    return languages.contains(code) ? code : defaultLang;
  }

  String? startTranscription(Recording r, String lang) {
    if (settings.geminiKey.isEmpty) return 'Add a Gemini API key in Settings';
    if (settings.geminiModel.isEmpty) {
      return 'Choose a Gemini model in Settings';
    }
    _start(
      JobKind.transcribe,
      r.relPath,
      TranscriptionJob(
        library: library,
        recording: r,
        language: languages.resolve(lang),
        apiKey: settings.geminiKey,
        model: settings.geminiModel,
        media: media,
      ),
    );
    return null;
  }

  String? startTranslation(Recording r) {
    final (generator, problem) = TextGenerator.fromSettings(settings);
    if (generator == null) return problem;
    _start(
      JobKind.translate,
      r.relPath,
      TranslationJob(
        library: library,
        recording: r.file,
        generator: generator,
        languages: languages,
      ),
    );
    return null;
  }

  String? startSummary(Recording r) {
    final (generator, problem) = TextGenerator.fromSettings(settings);
    if (generator == null) return problem;
    _start(
      JobKind.summary,
      r.relPath,
      SummaryJob(library: library, recording: r.file, generator: generator),
    );
    return null;
  }

  String? startFolderSummary(Directory folder, FolderSummaryMode mode) {
    final (generator, problem) = TextGenerator.fromSettings(settings);
    if (generator == null) return problem;
    _start(
      folderJobKind(mode),
      folder.path,
      FolderSummaryJob(
        library: library,
        folder: folder,
        mode: mode,
        language: languages.resolve(transcribeLang),
        languages: languages,
        generator: generator,
        geminiKey: settings.geminiKey,
        geminiModel: settings.geminiModel,
        media: media,
      ),
    );
    return null;
  }

  /// Starts joining and re-cutting [recording]'s family into chunks of
  /// [targetSeconds], none longer than [maxSeconds].
  RechunkJob startRechunk(
    Recording recording,
    double targetSeconds,
    double maxSeconds,
  ) {
    final job = RechunkJob(
      library: library,
      recording: recording.file,
      targetSeconds: targetSeconds,
      maxSeconds: maxSeconds,
      media: media,
    );
    _start(JobKind.rechunk, recording.relPath, job);
    return job;
  }

  /// Starts joining [parts] into one recording named [outputStem].
  CombineJob startCombine(
    List<CombinePart> parts,
    SpeakerMapping mapping,
    String outputStem,
  ) {
    final job = CombineJob(
      library: library,
      parts: parts,
      mapping: mapping,
      outputStem: outputStem,
      media: media,
    );
    _start(JobKind.combine, parts.first.file.parent.path, job);
    return job;
  }

  /// Reopens the recording that was open last, paused at its last position.
  Future<void> restore() async {
    final rel = prefs.getString(_lastAudioKey);
    final file = rel == null ? null : library.recordingAt(rel);
    if (file == null) return;
    await open(
      library.describe(file),
      position: Duration(milliseconds: prefs.getInt(_lastPositionKey) ?? 0),
    );
  }

  Future<void> setSpeed(double value) async {
    await prefs.setDouble(_speedKey, value);
    await player.setSpeed(value);
    notifyListeners();
  }

  void seekAndPlay(double seconds) {
    player.seek(Duration(milliseconds: (seconds * 1000).round()));
    player.play();
  }

  void seekBy(Duration delta) {
    final max = player.duration ?? Duration.zero;
    var target = player.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > max) target = max;
    player.seek(target);
  }

  void persistPosition() {
    if (recording == null) return;
    prefs.setInt(_lastPositionKey, player.position.inMilliseconds);
  }

  void _updateActive(Duration position) {
    final seconds = position.inMilliseconds / 1000;
    activeIndex.value = activeCueIndex(cues, seconds);
    translationActiveIndex.value = activeCueIndex(translatedCues, seconds);
  }

  void _onPosition(Duration position) {
    _updateActive(position);
    final now = DateTime.now();
    if (player.playing &&
        now.difference(_lastPersist) > const Duration(seconds: 1)) {
      _lastPersist = now;
      persistPosition();
    }
  }

  @override
  void dispose() {
    _positionSub.cancel();
    _stateSub.cancel();
    player.dispose();
    activeIndex.dispose();
    translationActiveIndex.dispose();
    super.dispose();
  }
}
