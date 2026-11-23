import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('transcripts/share');

/// Calls [onFiles] with the files other apps share into this one, copied into
/// the app's cache, and the number of shared files that could not be read.
/// Covers a share that launched the app and later ones.
void listenForSharedFiles(
  void Function(List<File> files, int unreadable) onFiles,
) {
  Future<void> deliver() async {
    final paths =
        await _channel.invokeListMethod<String>('takePending') ?? const [];
    if (paths.isEmpty) return;
    final readable = paths.where((path) => path.isNotEmpty);
    onFiles([
      for (final path in readable) File(path),
    ], paths.length - readable.length);
  }

  _channel.setMethodCallHandler((call) async {
    if (call.method == 'shared') await deliver();
  });
  deliver();
}
