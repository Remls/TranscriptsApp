import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('transcripts/files');

/// Lets the user choose where to save a copy of [file], suggesting [name].
/// Returns false when the user cancels.
Future<bool> saveFileAs(File file, String name, String mimeType) async {
  final saved = await _channel.invokeMethod<bool>('saveAs', {
    'path': file.path,
    'name': name,
    'mimeType': mimeType,
  });
  return saved ?? false;
}
