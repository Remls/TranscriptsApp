import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

/// How far the back and forward buttons skip.
const skipInterval = Duration(seconds: 10);

/// A file that could not be loaded, with a message for the user.
class PlaybackException implements Exception {
  const PlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the notification and lock screen show for a loaded file.
typedef PlaybackLabel = ({String id, String title, String? album});

/// Plays one recording at a time.
abstract class Playback {
  Duration get position;
  Stream<Duration> get positionStream;

  /// The loaded file's length, once known.
  Duration? get duration;
  Stream<Duration?> get durationStream;

  bool get playing;
  Stream<bool> get playingStream;

  double get speed;
  Stream<double> get speedStream;

  /// Fires when playback reaches the end of the file.
  Stream<void> get completed;

  /// Fires with the new position after each seek.
  Stream<Duration> get seeks;

  /// Loads [file] at [position]. Throws [PlaybackException] when it cannot
  /// be played.
  Future<void> load(
    File file, {
    required PlaybackLabel label,
    Duration position = Duration.zero,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);

  /// The loaded video, for drawing its picture, or null for audio.
  VideoPlayerController? get video;

  /// Stops playback and unloads the file.
  Future<void> stop();
  Future<void> dispose();
}

/// [Playback] through `just_audio`.
class JustAudioPlayback implements Playback {
  final _player = AudioPlayer();

  @override
  Duration get position => _player.position;
  @override
  Stream<Duration> get positionStream => _player.positionStream;
  @override
  Duration? get duration => _player.duration;
  @override
  Stream<Duration?> get durationStream => _player.durationStream;
  @override
  bool get playing => _player.playing;
  @override
  Stream<bool> get playingStream => _player.playingStream;
  @override
  double get speed => _player.speed;
  @override
  Stream<double> get speedStream => _player.speedStream;

  @override
  VideoPlayerController? get video => null;

  @override
  Stream<void> get completed => _player.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});

  @override
  Stream<Duration> get seeks => _player.positionDiscontinuityStream
      .where((d) => d.reason == PositionDiscontinuityReason.seek)
      .map((_) => _player.position);

  @override
  Future<void> load(
    File file, {
    required PlaybackLabel label,
    Duration position = Duration.zero,
  }) async {
    try {
      await _player.setAudioSource(
        AudioSource.file(file.path),
        initialPosition: position,
      );
    } on PlayerException catch (e) {
      throw PlaybackException(e.message ?? 'This file could not be played');
    }
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}
