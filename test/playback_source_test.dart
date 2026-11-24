import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/library.dart';
import 'package:transcripts/playback_source.dart';

import 'fake_media_tools.dart';

void main() {
  late Directory root;
  late Library library;
  late FakeMediaTools media;

  setUp(() {
    root = Directory.systemTemp.createTempSync('playback_source_test');
    library = Library(root);
    media = FakeMediaTools();
  });

  tearDown(() => root.deleteSync(recursive: true));

  File touch(String name) =>
      File(p.join(root.path, name))..writeAsStringSync(name);

  test('the plan follows what Android can play', () {
    PlaybackPlan plan(String format, String? audio, String? video) =>
        planPlayback((
          format: format,
          audio: audio,
          video: video,
        ), isVideo: video != null);
    expect(plan('mov,mp4,m4a,3gp,3g2,mj2', 'aac', 'h264'), PlaybackPlan.asIs);
    expect(plan('matroska,webm', 'ac3', 'h264'), PlaybackPlan.convertSound);
    expect(plan('asf', 'wmav2', 'wmv3'), PlaybackPlan.soundOnly);
    expect(plan('mpegts', 'mp2', 'mpeg2video'), PlaybackPlan.soundOnly);
    expect(plan('mp3', 'mp3', null), PlaybackPlan.asIs);
    expect(plan('asf', 'wmav2', null), PlaybackPlan.soundOnly);
    expect(
      planPlayback((
        format: 'mp3',
        audio: 'mp3',
        video: 'mjpeg',
      ), isVideo: false),
      PlaybackPlan.asIs,
    );
  });

  test('a playable file plays as it is', () async {
    final file = touch('clip.mp4');
    final source = await playbackSource(library, media, file);
    expect(source.file.path, file.path);
    expect(source.pictureUnavailable, isFalse);
    expect(media.calls, ['streams clip.mp4']);
  });

  test('unplayable sound gets a converted copy, made once', () async {
    final file = touch('talk.wma');
    media.streamsByName['talk.wma'] = (
      format: 'asf',
      audio: 'wmav2',
      video: null,
    );
    var converting = 0;
    final first = await playbackSource(
      library,
      media,
      file,
      onConverting: () => converting++,
    );
    expect(
      first.file.path,
      library.sidecarFile(file, Sidecar.playbackSound).path,
    );
    expect(first.pictureUnavailable, isFalse);
    expect(converting, 1);

    media.calls.clear();
    final again = await playbackSource(library, media, file);
    expect(again.file.path, first.file.path);
    expect(media.calls, isEmpty);
    expect(library.sidecarDir(file).listSync().map((e) => p.basename(e.path)), [
      Sidecar.playbackSound.fileName,
    ]);
  });

  test('a video keeps its picture unless Android cannot show it', () async {
    final kept = touch('show.mkv');
    media.streamsByName['show.mkv'] = (
      format: 'matroska,webm',
      audio: 'ac3',
      video: 'h264',
    );
    final keptSource = await playbackSource(library, media, kept);
    expect(
      keptSource.file.path,
      library.sidecarFile(kept, Sidecar.playbackVideo).path,
    );
    expect(keptSource.pictureUnavailable, isFalse);

    final lost = touch('old.wmv');
    media.streamsByName['old.wmv'] = (
      format: 'asf',
      audio: 'wmav2',
      video: 'wmv3',
    );
    final lostSource = await playbackSource(library, media, lost);
    expect(
      lostSource.file.path,
      library.sidecarFile(lost, Sidecar.playbackSound).path,
    );
    expect(lostSource.pictureUnavailable, isTrue);
    expect(
      (await playbackSource(library, media, lost)).pictureUnavailable,
      isTrue,
    );
  });
}
