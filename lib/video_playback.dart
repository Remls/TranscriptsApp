import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'playback.dart';

/// [Playback] of a video file, picture and sound together, through
/// `video_player`.
class VideoPlayback implements Playback {
  VideoPlayerController? _controller;
  VideoPlayerValue _last = const VideoPlayerValue.uninitialized();
  double _speed = 1;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _speeds = StreamController<double>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _seeks = StreamController<Duration>.broadcast();

  /// The loaded video, for drawing its picture.
  @override
  VideoPlayerController? get video => _controller;

  VideoPlayerValue get _value => _controller?.value ?? _last;

  @override
  Duration get position => _value.position;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Duration? get duration => _value.isInitialized ? _value.duration : null;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  bool get playing => _value.isPlaying;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  double get speed => _speed;
  @override
  Stream<double> get speedStream => _speeds.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Duration> get seeks => _seeks.stream;

  void _onChange() {
    final value = _controller!.value;
    if (value.position != _last.position) _position.add(value.position);
    if (value.duration != _last.duration) _duration.add(value.duration);
    if (value.isPlaying != _last.isPlaying) _playing.add(value.isPlaying);
    if (value.isCompleted && !_last.isCompleted) _completed.add(null);
    _last = value;
  }

  @override
  Future<void> load(
    File file, {
    required PlaybackLabel label,
    Duration position = Duration.zero,
  }) async {
    await _unload();
    final controller = VideoPlayerController.file(
      file,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    try {
      await controller.initialize();
    } on PlatformException catch (e) {
      await controller.dispose();
      throw PlaybackException(e.message ?? 'This file could not be played');
    }
    _controller = controller;
    _last = controller.value;
    controller.addListener(_onChange);
    await controller.setPlaybackSpeed(_speed);
    if (position > Duration.zero) await controller.seekTo(position);
    _duration.add(controller.value.duration);
    _position.add(controller.value.position);
  }

  Future<void> _unload() async {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    controller.removeListener(_onChange);
    await controller.dispose();
    _last = const VideoPlayerValue.uninitialized();
    _playing.add(false);
  }

  @override
  Future<void> play() async => _controller?.play();
  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
    _seeks.add(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _controller?.setPlaybackSpeed(speed);
    _speeds.add(speed);
  }

  @override
  Future<void> stop() => _unload();

  @override
  Future<void> dispose() async {
    await _unload();
    for (final c in [
      _position,
      _duration,
      _playing,
      _speeds,
      _completed,
      _seeks,
    ]) {
      await c.close();
    }
  }
}
