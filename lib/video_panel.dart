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
/// Dragging it up opens fullscreen, following the finger.
class VideoPanel extends StatefulWidget {
  const VideoPanel({
    super.key,
    required this.session,
    required this.picture,
    required this.pip,
    required this.subtitles,
  });

  final Session session;
  final VideoPicture picture;
  final PipController pip;

  /// The subtitles fullscreen opens with.
  final SubtitleMode Function() subtitles;

  @override
  State<VideoPanel> createState() => _VideoPanelState();
}

class _VideoPanelState extends State<VideoPanel>
    with SingleTickerProviderStateMixin {
  final _videoKey = GlobalKey();
  late final _opening = AnimationController(
    vsync: this,
    duration: fullscreenTransition,
  );
  OverlayEntry? _preview;

  @override
  void dispose() {
    _preview?.remove();
    _opening.dispose();
    super.dispose();
  }

  Rect _videoRect() {
    final box = _videoKey.currentContext!.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  double get _aspectRatio => widget.picture.controller.value.aspectRatio;

  void _openFullscreen({double from = 0}) {
    Navigator.push(
      context,
      FullscreenRoute(
        from: _videoRect(),
        startProgress: from,
        builder: (_) => FullscreenVideo(
          picture: widget.picture,
          session: widget.session,
          pip: widget.pip,
          subtitles: widget.subtitles(),
        ),
      ),
    );
  }

  void _removePreview() {
    _preview?.remove();
    _preview = null;
    if (mounted) setState(() {});
  }

  void _dragStart(DragStartDetails details) {
    final from = _videoRect();
    _opening.value = 0;
    _preview = OverlayEntry(
      builder: (context) => AnimatedBuilder(
        animation: _opening,
        builder: (context, _) => IgnorePointer(
          child: FullscreenFrame(
            t: _opening.value,
            from: from,
            aspectRatio: _aspectRatio,
            video: VideoPlayer(widget.picture.controller),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_preview!);
    setState(() {});
  }

  void _dragUpdate(DragUpdateDetails details) {
    final distance = MediaQuery.sizeOf(context).height * 0.6;
    _opening.value -= (details.primaryDelta ?? 0) / distance;
  }

  void _dragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final open = velocity < -700 || (_opening.value > 0.3 && velocity <= 700);
    if (open) {
      _openFullscreen(from: _opening.value);
      _removePreview();
    } else {
      _opening.reverse().whenComplete(_removePreview);
    }
  }

  @override
  Widget build(BuildContext context) {
    final picture = widget.picture;
    return ListenableBuilder(
      listenable: picture,
      builder: (context, _) {
        if (!picture.isInitialized) return const SizedBox.shrink();
        final controller = picture.controller;
        return GestureDetector(
          onVerticalDragStart: _dragStart,
          onVerticalDragUpdate: _dragUpdate,
          onVerticalDragEnd: _dragEnd,
          child: ColoredBox(
            color: Colors.black,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.35,
              ),
              child: Stack(
                alignment: .center,
                children: [
                  AspectRatio(
                    key: _videoKey,
                    aspectRatio: controller.value.aspectRatio,
                    child: picture.fullscreen || _preview != null
                        ? const SizedBox.shrink()
                        : VideoPlayer(controller),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: IconButton(
                      tooltip: 'Fullscreen',
                      color: Colors.white,
                      icon: const Icon(Icons.fullscreen),
                      onPressed: _openFullscreen,
                    ),
                  ),
                ],
              ),
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
