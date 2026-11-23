import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'gemini.dart';
import 'job.dart';
import 'languages.dart';
import 'library.dart';
import 'media_tools.dart';
import 'prompts.dart';
import 'srt.dart';

const _mimeTypes = {
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/ogg',
  '.wav': 'audio/wav',
  '.flac': 'audio/flac',
  '.aac': 'audio/aac',
};

/// Transcribes [recording] within [job]: upload, streamed generation, then
/// the transcript, plain text and language sidecars.
Future<void> transcribeRecording(
  Job job, {
  required Library library,
  required File recording,
  required Language language,
  required String apiKey,
  required String model,
  MediaTools? media,
  Duration pollInterval = const Duration(seconds: 2),
}) async {
  final extracted = library.sidecarFile(recording, Sidecar.audio);
  if (videoExts.contains(p.extension(recording.path).toLowerCase()) &&
      !extracted.existsSync()) {
    if (media == null) throw const JobFailure('video needs audio extraction');
    job.resetOutput();
    job.setStatus('Extracting the audio from the video');
    extracted.parent.createSync(recursive: true);
    final partial = File(p.join(extracted.parent.path, '.audio.tmp.mp3'));
    job.onCancel = media.cancel;
    try {
      await media.extractAudio(recording, partial);
      partial.renameSync(extracted.path);
    } finally {
      job.onCancel = null;
      if (partial.existsSync()) partial.deleteSync();
    }
  }
  final audio = library.playbackAudio(recording);
  final mimeType = _mimeTypes[p.extension(audio.path).toLowerCase()];
  if (mimeType == null) throw const JobFailure('unsupported audio format');
  final gemini = GeminiClient(apiKey: apiKey, client: job.openClient());
  GeminiFile? remote;
  try {
    final megabytes = (await audio.length() / 1e6).toStringAsFixed(1);
    job.resetOutput();
    job.setStatus('Uploading $megabytes MB');
    var lastPercent = -1;
    remote = await gemini.upload(
      audio,
      mimeType,
      onProgress: (fraction) {
        final percent = (fraction * 100).floor();
        if (percent == lastPercent) return;
        lastPercent = percent;
        job.setStatus('Uploading $megabytes MB ($percent%)');
      },
    );
    job.setStatus('Waiting for Gemini to process the file');
    remote = await gemini.waitUntilActive(remote, interval: pollInterval);

    job.setStatus('Transcribing ${language.name} with $model');
    final chunks = gemini.generateStream(
      model: model,
      prompt: buildTranscriptionPrompt(language),
      file: remote,
    );
    await for (final chunk in chunks) {
      job.appendOutput(chunk);
    }

    final srt = cleanModelSrt(job.output.toString());
    if (srt.isEmpty) throw const JobFailure('empty response from Gemini');
    library.sidecarDir(recording).createSync(recursive: true);
    library
        .sidecarFile(recording, Sidecar.transcriptSrt)
        .writeAsStringSync('$srt\n');
    library
        .sidecarFile(recording, Sidecar.transcriptTxt)
        .writeAsStringSync(srtToPlaintext(srt));
    library
        .sidecarFile(recording, Sidecar.lang)
        .writeAsStringSync('${language.code}\n');
  } finally {
    if (remote != null) unawaited(_deleteRemote(job, apiKey, remote.name));
  }
}

Future<void> _deleteRemote(Job job, String apiKey, String name) async {
  final client = job.clientFactory();
  try {
    await GeminiClient(apiKey: apiKey, client: client).deleteFile(name);
  } catch (_) {
    // The Files API expires uploads on its own.
  } finally {
    client.close();
  }
}

class TranscriptionJob extends Job {
  TranscriptionJob({
    required this.library,
    required this.recording,
    required this.language,
    required this.apiKey,
    required this.model,
    this.media,
    super.clientFactory,
    this.pollInterval = const Duration(seconds: 2),
  });

  final Library library;
  final Recording recording;
  final Language language;
  final String apiKey;
  final String model;
  final MediaTools? media;
  final Duration pollInterval;

  @override
  Future<void> perform() => transcribeRecording(
    this,
    library: library,
    recording: recording.file,
    language: language,
    apiKey: apiKey,
    model: model,
    media: media,
    pollInterval: pollInterval,
  );
}
