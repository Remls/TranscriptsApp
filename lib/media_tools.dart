import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

class MediaException implements Exception {
  const MediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The audio and video processing the app needs.
abstract class MediaTools {
  /// The length of [file] in seconds, or null when it cannot be read.
  Future<double?> duration(File file);

  /// Writes the audio of [video] to [output] as mp3.
  Future<void> extractAudio(File video, File output);

  /// Joins [inputs] end to end into [output] without re-encoding.
  Future<void> concat(List<File> inputs, File output);

  /// Copies [length] seconds of [input] from [start] into [output] without
  /// re-encoding. Copies to the end when [length] is null.
  Future<void> split(
    File input,
    File output, {
    required double start,
    double? length,
  });

  /// Stops the operation in progress, which then fails as cancelled.
  void cancel();
}

class FfmpegMediaTools implements MediaTools {
  int? _sessionId;

  @override
  Future<double?> duration(File file) async {
    final session = await FFprobeKit.getMediaInformation(file.path);
    final raw = session.getMediaInformation()?.getDuration();
    return raw == null ? null : double.tryParse(raw);
  }

  Future<void> _run(List<String> arguments, String what) async {
    final done = Completer<void>();
    final session = await FFmpegKit.executeWithArgumentsAsync([
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      ...arguments,
    ], (_) => done.complete());
    _sessionId = session.getSessionId();
    await done.future;
    _sessionId = null;
    final code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code)) return;
    if (ReturnCode.isCancel(code)) throw const MediaException('cancelled');
    final logs = (await session.getAllLogsAsString() ?? '').trim();
    final tail = logs.length > 300 ? logs.substring(logs.length - 300) : logs;
    throw MediaException('$what failed: $tail');
  }

  @override
  Future<void> extractAudio(File video, File output) {
    return _run([
      '-i',
      video.path,
      '-vn',
      '-c:a',
      'libmp3lame',
      '-q:a',
      '2',
      output.path,
    ], 'audio extraction');
  }

  @override
  Future<void> concat(List<File> inputs, File output) async {
    final list = File('${output.path}.list.txt');
    list.writeAsStringSync(
      inputs.map((f) => "file '${f.path.replaceAll("'", r"'\''")}'\n").join(),
    );
    try {
      await _run([
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        list.path,
        '-c',
        'copy',
        output.path,
      ], 'joining');
    } finally {
      if (list.existsSync()) list.deleteSync();
    }
  }

  @override
  Future<void> split(
    File input,
    File output, {
    required double start,
    double? length,
  }) {
    return _run([
      '-ss',
      '$start',
      '-i',
      input.path,
      if (length != null) ...['-t', '$length'],
      '-c',
      'copy',
      output.path,
    ], 'splitting');
  }

  @override
  void cancel() {
    final id = _sessionId;
    if (id != null) FFmpegKit.cancel(id);
  }
}
