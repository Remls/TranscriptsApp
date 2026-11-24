import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:video_player/video_player.dart';

import 'playback.dart';

/// The system media session: the notification, lock screen and media
/// buttons. It shows and controls whatever [MediaSessionPlayback] plays.
class PlaybackHandler extends BaseAudioHandler {
  Playback? _playback;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Shows [playback] in the media session, with [label] and its length.
  void show(Playback playback, PlaybackLabel label) {
    _detach();
    _playback = playback;
    mediaItem.add(
      MediaItem(
        id: label.id,
        title: label.title,
        album: label.album,
        duration: playback.duration,
      ),
    );
    _subscriptions
      ..add(playback.playingStream.listen((_) => _broadcast()))
      ..add(playback.speedStream.listen((_) => _broadcast()))
      ..add(playback.seeks.listen((_) => _broadcast()))
      ..add(
        playback.durationStream.listen((duration) {
          final item = mediaItem.value;
          if (item != null && item.duration != duration) {
            mediaItem.add(item.copyWith(duration: duration));
          }
        }),
      );
    _broadcast();
  }

  /// Takes the media session down.
  void hide() {
    _detach();
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  void _detach() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _playback = null;
  }

  void _broadcast() {
    final playback = _playback;
    if (playback == null) return;
    final playing = playback.playing;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.rewind,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.rewind,
          MediaAction.fastForward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: playback.position,
        speed: playback.speed,
      ),
    );
  }

  @override
  Future<void> play() async {
    final playback = _playback;
    if (playback != null) unawaited(playback.play());
  }

  @override
  Future<void> pause() async => _playback?.pause();

  @override
  Future<void> seek(Duration position) async => _playback?.seek(position);

  @override
  Future<void> rewind() => _skip(-skipInterval);

  @override
  Future<void> fastForward() => _skip(skipInterval);

  Future<void> _skip(Duration by) async {
    final playback = _playback;
    if (playback == null) return;
    final end = playback.duration ?? Duration.zero;
    var to = playback.position + by;
    if (to < Duration.zero) to = Duration.zero;
    if (to > end) to = end;
    await playback.seek(to);
  }

  @override
  Future<void> stop() async {
    await _playback?.pause();
    hide();
  }
}

/// Plays each file with [audioPlayback] or [videoPlayback] by its kind, and shows it in the
/// system media session through [handler].
class MediaSessionPlayback implements Playback {
  MediaSessionPlayback({
    required this.audioPlayback,
    required this.videoPlayback,
    required this.handler,
    required this.isVideo,
  }) {
    _follow(audioPlayback);
  }

  final Playback audioPlayback;
  final Playback videoPlayback;
  final PlaybackHandler handler;

  /// Whether a file is played with [videoPlayback].
  final bool Function(File file) isVideo;

  late Playback _current;
  final _subscriptions = <StreamSubscription<Object?>>[];

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _speeds = StreamController<double>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _seeks = StreamController<Duration>.broadcast();

  /// Passes [playback]'s events on as this one's.
  void _follow(Playback playback) {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions
      ..clear()
      ..add(playback.positionStream.listen(_position.add))
      ..add(playback.durationStream.listen(_duration.add))
      ..add(playback.playingStream.listen(_playing.add))
      ..add(playback.speedStream.listen(_speeds.add))
      ..add(playback.completed.listen(_completed.add))
      ..add(playback.seeks.listen(_seeks.add));
    _current = playback;
  }

  @override
  Duration get position => _current.position;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Duration? get duration => _current.duration;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  bool get playing => _current.playing;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  double get speed => _current.speed;
  @override
  Stream<double> get speedStream => _speeds.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Duration> get seeks => _seeks.stream;
  @override
  VideoPlayerController? get video => _current.video;

  @override
  Future<void> load(
    File file, {
    required PlaybackLabel label,
    Duration position = Duration.zero,
  }) async {
    final next = isVideo(file) ? videoPlayback : audioPlayback;
    if (!identical(next, _current)) {
      await _current.stop();
      await next.setSpeed(_current.speed);
      _follow(next);
    }
    await _current.load(file, label: label, position: position);
    handler.show(this, label);
  }

  /// Resolves when playback stops for `just_audio`, or once started for
  /// video.
  @override
  Future<void> play() {
    final item = handler.mediaItem.value;
    if (handler.playbackState.value.processingState ==
            AudioProcessingState.idle &&
        item != null) {
      handler.show(this, (id: item.id, title: item.title, album: item.album));
    }
    return _current.play();
  }

  @override
  Future<void> pause() => _current.pause();
  @override
  Future<void> seek(Duration position) => _current.seek(position);
  @override
  Future<void> setSpeed(double speed) => _current.setSpeed(speed);

  @override
  Future<void> stop() async {
    await _current.stop();
    handler.hide();
  }

  @override
  Future<void> dispose() async {
    for (final s in _subscriptions) {
      s.cancel();
    }
    await audioPlayback.dispose();
    await videoPlayback.dispose();
  }
}
