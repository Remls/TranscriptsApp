import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import 'fullscreen_video.dart';
import 'pip.dart';
import 'session.dart';

const _maxDrift = Duration(milliseconds: 400);

/// The picture of a video recording. It plays muted and follows the audio
/// player's position, state and speed.
class VideoFollower extends ChangeNotifier {
  VideoFollower(this._player, File video)
    : controller = VideoPlayerController.file(
        video,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      ) {
    _start();
  }

  final AudioPlayer _player;
  final VideoPlayerController controller;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _disposed = false;
  bool _fullscreen = false;

  bool get isInitialized => controller.value.isInitialized;

  /// Whether the fullscreen video screen is open.
  bool get fullscreen => _fullscreen;
  set fullscreen(bool value) {
    if (value == _fullscreen) return;
    _fullscreen = value;
    notifyListeners();
  }

  Future<void> _start() async {
    try {
      await controller.initialize();
    } on PlatformException {
      return;
    }
    if (_disposed) return;
    await controller.setVolume(0);
    _subscriptions
      ..add(_player.playingStream.listen((_) => _sync()))
      ..add(_player.speedStream.listen((_) => _sync()))
      ..add(_player.positionStream.listen((_) => _sync()));
    _sync();
    notifyListeners();
  }

  void _sync() {
    if (!controller.value.isInitialized) return;
    final drift = controller.value.position - _player.position;
    if (drift.abs() > _maxDrift) controller.seekTo(_player.position);
    if (controller.value.playbackSpeed != _player.speed) {
      controller.setPlaybackSpeed(_player.speed);
    }
    if (_player.playing != controller.value.isPlaying) {
      _player.playing ? controller.play() : controller.pause();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      s.cancel();
    }
    controller.dispose();
    super.dispose();
  }
}

/// The video of [follower] above the transcript, with a fullscreen button.
class VideoPanel extends StatelessWidget {
  const VideoPanel({
    super.key,
    required this.session,
    required this.follower,
    required this.pip,
  });

  final Session session;
  final VideoFollower follower;
  final PipController pip;

  void _openFullscreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            FullscreenVideo(follower: follower, session: session, pip: pip),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: follower,
      builder: (context, _) {
        if (!follower.isInitialized) return const SizedBox.shrink();
        final controller = follower.controller;
        return ColoredBox(
          color: Colors.black,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.35,
            ),
            child: Stack(
              alignment: .center,
              children: [
                AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: IconButton(
                    tooltip: 'Fullscreen',
                    color: Colors.white,
                    icon: const Icon(Icons.fullscreen),
                    onPressed: () => _openFullscreen(context),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The video of [follower] alone, centred on black.
class PipVideo extends StatelessWidget {
  const PipVideo({super.key, required this.follower});

  final VideoFollower follower;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AspectRatio(
          aspectRatio: follower.controller.value.aspectRatio,
          child: VideoPlayer(follower.controller),
        ),
      ),
    );
  }
}
