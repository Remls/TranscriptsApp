import 'dart:async';
import 'dart:io';

import 'package:transcripts/playback.dart';
import 'package:video_player/video_player.dart';

/// Playback that records what it is asked to do and plays nothing.
class FakePlayback implements Playback {
  File? loaded;
  PlaybackLabel? label;
  String? failWith;

  final _position = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _seeks = StreamController<Duration>.broadcast();

  @override
  Duration position = Duration.zero;
  @override
  Duration? duration;
  @override
  bool playing = false;
  @override
  double speed = 1;

  /// Reports that playback reached the end.
  void finish() => _completed.add(null);

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => Stream.value(duration);
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<double> get speedStream => Stream.value(speed);
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Duration> get seeks => _seeks.stream;
  @override
  VideoPlayerController? get video => null;

  @override
  Future<void> load(
    File file, {
    required PlaybackLabel label,
    Duration position = Duration.zero,
  }) async {
    if (failWith != null) throw PlaybackException(failWith!);
    loaded = file;
    this.label = label;
    this.position = position;
  }

  @override
  Future<void> play() async {
    playing = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    this.position = position;
    _seeks.add(position);
    _position.add(position);
  }

  @override
  Future<void> setSpeed(double speed) async => this.speed = speed;

  @override
  Future<void> stop() async {
    loaded = null;
    await pause();
  }

  @override
  Future<void> dispose() async {}
}
