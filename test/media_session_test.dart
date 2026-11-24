import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcripts/media_session.dart';

import 'fake_playback.dart';

void main() {
  late FakePlayback inner;
  late FakePlayback videoInner;
  late PlaybackHandler handler;
  late MediaSessionPlayback playback;

  setUp(() async {
    inner = FakePlayback();
    videoInner = FakePlayback();
    handler = PlaybackHandler();
    playback = MediaSessionPlayback(
      audioPlayback: inner,
      videoPlayback: videoInner,
      handler: handler,
      isVideo: (file) => file.path.endsWith('.mp4'),
    );
    await playback.load(
      File('talk.mp3'),
      label: (id: 'set/talk.mp3', title: 'talk', album: 'set'),
    );
  });

  test('loading shows the recording in the media session', () async {
    expect(handler.mediaItem.value?.title, 'talk');
    expect(handler.mediaItem.value?.album, 'set');
    final state = handler.playbackState.value;
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.playing, isFalse);
    expect(state.controls, contains(MediaControl.play));

    await playback.play();
    await pumpEventQueue();
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.controls, contains(MediaControl.pause));
  });

  test(
    'the session buttons control playback and skip within the file',
    () async {
      inner.duration = const Duration(seconds: 30);
      await handler.play();
      expect(inner.playing, isTrue);
      await handler.pause();
      expect(inner.playing, isFalse);

      inner.position = const Duration(seconds: 25);
      await handler.fastForward();
      expect(inner.position, const Duration(seconds: 30));
      await handler.rewind();
      expect(inner.position, const Duration(seconds: 20));
      await handler.seek(const Duration(seconds: 3));
      expect(inner.position, const Duration(seconds: 3));
    },
  );

  test('stop pauses and takes the session down until played again', () async {
    await playback.play();
    await handler.stop();
    expect(inner.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );

    await playback.play();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
  });

  test('each file plays on the player for its kind', () async {
    await playback.setSpeed(1.5);
    await playback.play();
    await playback.load(
      File('clip.mp4'),
      label: (id: 'clip.mp4', title: 'clip', album: null),
    );
    expect(videoInner.loaded?.path, 'clip.mp4');
    expect(inner.loaded, isNull);
    expect(inner.playing, isFalse);
    expect(videoInner.speed, 1.5);
    expect(handler.mediaItem.value?.title, 'clip');

    final positions = <Duration>[];
    playback.seeks.listen(positions.add);
    await playback.seek(const Duration(seconds: 4));
    await pumpEventQueue();
    expect(videoInner.position, const Duration(seconds: 4));
    expect(positions, [const Duration(seconds: 4)]);

    await playback.load(
      File('talk.mp3'),
      label: (id: 'talk.mp3', title: 'talk', album: null),
    );
    expect(inner.loaded?.path, 'talk.mp3');
    expect(videoInner.loaded, isNull);
  });
}
