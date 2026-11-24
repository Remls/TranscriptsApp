import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import 'fullscreen_video.dart';
import 'pip.dart';
import 'session.dart';

/// The picture of the open video recording, and whether the fullscreen
/// video screen is open.
class VideoPicture extends ChangeNotifier {
  VideoPicture(this.controller) {
    controller.addListener(_onChange);
  }

  final VideoPlayerController controller;
  bool _initialized = false;
  bool _fullscreen = false;

  bool get isInitialized => controller.value.isInitialized;

  void _onChange() {
    if (isInitialized == _initialized) return;
    _initialized = isInitialized;
    notifyListeners();
  }

  /// Whether the fullscreen video screen is open.
  bool get fullscreen => _fullscreen;
  set fullscreen(bool value) {
    if (value == _fullscreen) return;
    _fullscreen = value;
    notifyListeners();
  }

  @override
  void dispose() {
    controller.removeListener(_onChange);
    super.dispose();
  }
}

/// The video of [picture] above the transcript, with a fullscreen button.
class VideoPanel extends StatelessWidget {
  const VideoPanel({
    super.key,
    required this.session,
    required this.picture,
    required this.pip,
  });

  final Session session;
  final VideoPicture picture;
  final PipController pip;

  void _openFullscreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            FullscreenVideo(picture: picture, session: session, pip: pip),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: picture,
      builder: (context, _) {
        if (!picture.isInitialized) return const SizedBox.shrink();
        final controller = picture.controller;
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

/// The video of [picture] alone, centred on black.
class PipVideo extends StatelessWidget {
  const PipVideo({super.key, required this.picture});

  final VideoPicture picture;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AspectRatio(
          aspectRatio: picture.controller.value.aspectRatio,
          child: VideoPlayer(picture.controller),
        ),
      ),
    );
  }
}
