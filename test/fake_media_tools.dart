import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:transcripts/media_tools.dart';

/// Media tools over text files: a file's length is its character count,
/// joining concatenates text and splitting takes a substring.
class FakeMediaTools implements MediaTools {
  final calls = <String>[];
  bool cancelled = false;
  String? failOn;

  void _record(String call) {
    calls.add(call);
    if (failOn != null && call.startsWith(failOn!)) {
      throw const MediaException('boom');
    }
  }

  @override
  Future<double?> duration(File file) async {
    _record('duration ${p.basename(file.path)}');
    return file.existsSync() ? file.readAsStringSync().length.toDouble() : null;
  }

  @override
  Future<void> extractAudio(File video, File output) async {
    _record('extract ${p.basename(video.path)}');
    output.writeAsStringSync('audio of ${video.readAsStringSync()}');
  }

  @override
  Future<void> concat(List<File> inputs, File output) async {
    _record('concat ${inputs.map((f) => p.basename(f.path)).join('+')}');
    output.writeAsStringSync(inputs.map((f) => f.readAsStringSync()).join());
  }

  @override
  Future<void> split(
    File input,
    File output, {
    required double start,
    double? length,
  }) async {
    final text = input.readAsStringSync();
    final from = start.toInt();
    final to = length == null ? text.length : from + length.toInt();
    output.writeAsStringSync(text.substring(from, to));
    _record('split $start ${length ?? 'end'}');
  }

  @override
  void cancel() => cancelled = true;
}
