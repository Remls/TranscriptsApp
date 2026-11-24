import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/session.dart';
import 'package:transcripts/settings.dart';

import 'fake_media_tools.dart';
import 'fake_playback.dart';
import 'settings_test.dart' show MemorySecretStore;

void main() {
  late Directory root;
  late Library library;
  late FakePlayback playback;
  late Session session;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('session_playback_test');
    library = Library(root);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    playback = FakePlayback();
    session = Session(
      library,
      prefs,
      await Settings.load(prefs, MemorySecretStore()),
      FakeMediaTools(),
      player: playback,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  Recording recording(String rel) => library.describe(
    File(p.join(root.path, rel))
      ..createSync(recursive: true)
      ..writeAsStringSync('audio'),
  );

  test('opening a recording loads it with its name and folder', () async {
    await session.setSpeed(1.5);
    await session.open(
      recording('talks/intro.mp3'),
      position: const Duration(seconds: 7),
    );
    expect(playback.loaded!.path, endsWith('talks/intro.mp3'));
    expect(playback.label, (
      id: 'talks/intro.mp3',
      title: 'intro',
      album: 'talks',
    ));
    expect(playback.position, const Duration(seconds: 7));
    expect(playback.speed, 1.5);

    await session.open(recording('loose.mp3'));
    expect(playback.label!.album, isNull);
  });

  test('a file that cannot be played sets the load error', () async {
    playback.failWith = 'Unsupported file';
    await session.open(recording('bad.mp3'));
    expect(session.loadError, 'Unsupported file');
  });

  test('reaching the end pauses at the start', () async {
    await session.open(recording('a.mp3'));
    await playback.play();
    playback.position = const Duration(seconds: 30);
    playback.finish();
    await pumpEventQueue();
    expect(playback.playing, isFalse);
    expect(playback.position, Duration.zero);
  });

  test('skipping stays within the recording', () async {
    await session.open(recording('a.mp3'));
    playback.duration = const Duration(seconds: 20);
    playback.position = const Duration(seconds: 15);
    session.seekBy(const Duration(seconds: 10));
    expect(playback.position, const Duration(seconds: 20));
    session.seekBy(const Duration(seconds: -30));
    expect(playback.position, Duration.zero);
  });
}
