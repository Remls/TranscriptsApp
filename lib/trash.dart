import 'dart:io';

import 'package:path/path.dart' as p;

import 'library.dart';

const _originFile = 'origin';

/// [origin] when it names one visible folder at the library root, else the
/// root itself.
String _folderName(String origin) =>
    p.basename(origin) == origin && !origin.startsWith('.') ? origin : '';

/// A trashed recording or folder. Its files sit in [dir] next to a note of
/// the folder they came from.
class TrashItem {
  const TrashItem({
    required this.dir,
    required this.name,
    required this.isFolder,
    required this.origin,
    required this.deletedAt,
    required this.bytes,
  });

  final Directory dir;
  final String name;
  final bool isFolder;

  /// The folder the item was in, relative to the library root. Empty for the
  /// root itself.
  final String origin;
  final DateTime deletedAt;
  final int bytes;
}

/// The library's trash, a hidden `.trash/` folder at its root.
class Trash {
  Trash(this.library);

  final Library library;

  Directory get _dir => Directory(p.join(library.root.path, '.trash'));

  Directory _newSlot(String origin) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var n = 0; ; n++) {
      final slot = Directory(p.join(_dir.path, '$now-$n'));
      if (slot.existsSync()) continue;
      slot.createSync(recursive: true);
      File(p.join(slot.path, _originFile)).writeAsStringSync(origin);
      return slot;
    }
  }

  void trashRecording(File recording) {
    final origin = p.relative(recording.parent.path, from: library.root.path);
    final slot = _newSlot(origin == '.' ? '' : origin);
    final sidecar = library.sidecarDir(recording);
    if (sidecar.existsSync()) {
      sidecar.renameSync(p.join(slot.path, p.basename(sidecar.path)));
    }
    recording.renameSync(p.join(slot.path, p.basename(recording.path)));
  }

  void trashFolder(Directory folder) {
    final slot = _newSlot('');
    folder.renameSync(p.join(slot.path, p.basename(folder.path)));
  }

  /// Trashed items, most recently deleted first.
  List<TrashItem> items() {
    if (!_dir.existsSync()) return [];
    final items = <TrashItem>[];
    for (final slot in _dir.listSync().whereType<Directory>()) {
      final payload = _payload(slot);
      if (payload == null) continue;
      final millis = int.tryParse(p.basename(slot.path).split('-').first) ?? 0;
      final origin = File(p.join(slot.path, _originFile));
      items.add(
        TrashItem(
          dir: slot,
          name: payload is Directory
              ? p.basename(payload.path)
              : p.basenameWithoutExtension(payload.path),
          isFolder: payload is Directory,
          origin: origin.existsSync()
              ? _folderName(origin.readAsStringSync())
              : '',
          deletedAt: DateTime.fromMillisecondsSinceEpoch(millis),
          bytes: _size(slot),
        ),
      );
    }
    return items..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  }

  /// The trashed folder, or the trashed recording file, inside [slot].
  FileSystemEntity? _payload(Directory slot) {
    final entries = slot.listSync();
    for (final dir in entries.whereType<Directory>()) {
      if (!p.basename(dir.path).startsWith('.')) return dir;
    }
    for (final file in entries.whereType<File>()) {
      if (p.basename(file.path) != _originFile) return file;
    }
    return null;
  }

  int _size(Directory dir) {
    var total = 0;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      total += f.lengthSync();
    }
    return total;
  }

  int totalBytes() => items().fold(0, (sum, item) => sum + item.bytes);

  /// Puts [item] back where it came from, under a free name when its own is
  /// taken. Returns the restored recording or folder.
  FileSystemEntity restore(TrashItem item) {
    final payload = _payload(item.dir)!;
    final FileSystemEntity restored;
    if (payload is Directory) {
      final name = p.basename(payload.path);
      var target = p.join(library.root.path, name);
      for (var n = 2; Directory(target).existsSync(); n++) {
        target = p.join(library.root.path, '$name ($n)');
      }
      restored = payload.renameSync(target);
    } else {
      final dir = item.origin.isEmpty
          ? library.root
          : Directory(p.joinAll([library.root.path, ...p.split(item.origin)]));
      restored = library.relocateFreely(payload as File, dir);
    }
    item.dir.deleteSync(recursive: true);
    return restored;
  }

  void deletePermanently(TrashItem item) =>
      item.dir.deleteSync(recursive: true);

  void empty() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}
