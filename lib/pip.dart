import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The system's floating video window.
abstract class PipWindow {
  /// Sets whether leaving the app shrinks the video into the window, whether
  /// it is playing, and the video's size in pixels. A size of zero keeps the
  /// last one.
  Future<void> setVideo({
    required bool active,
    required bool playing,
    required int width,
    required int height,
  });

  /// Calls [onModeChanged] when the app enters or leaves the window, and
  /// [onAction] when one of the window's buttons is tapped.
  void listen({
    required void Function(bool inPip) onModeChanged,
    required void Function(PipAction action) onAction,
  });
}

/// A button on the floating window.
enum PipAction { back, play, pause, forward }

class AndroidPipWindow implements PipWindow {
  const AndroidPipWindow();

  static const _channel = MethodChannel('transcripts/pip');

  @override
  Future<void> setVideo({
    required bool active,
    required bool playing,
    required int width,
    required int height,
  }) => _channel.invokeMethod('setVideo', {
    'active': active,
    'playing': playing,
    'width': width,
    'height': height,
  });

  @override
  void listen({
    required void Function(bool inPip) onModeChanged,
    required void Function(PipAction action) onAction,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'modeChanged':
          onModeChanged(call.arguments as bool);
        case 'action':
          final name = call.arguments as String?;
          for (final action in PipAction.values) {
            if (action.name == name) onAction(action);
          }
      }
    });
  }
}

/// Whether leaving the app should shrink the video into the floating window.
bool pipAllowed({
  required bool isVideo,
  required bool showVideo,
  required bool playing,
  required bool videoReady,
  required bool inFront,
}) => isVideo && showVideo && playing && videoReady && inFront;

/// Tracks the floating video window and tells the system when it may open.
class PipController extends ChangeNotifier {
  PipController(this._window) {
    _window.listen(
      onModeChanged: (inPip) {
        if (inPip == _inPip) return;
        _inPip = inPip;
        notifyListeners();
      },
      onAction: (action) => onAction?.call(action),
    );
  }

  final PipWindow _window;
  bool _inPip = false;
  (bool, bool, int, int)? _sent;

  /// Called when one of the window's buttons is tapped.
  void Function(PipAction action)? onAction;

  /// Whether the app is showing in the floating window.
  bool get inPip => _inPip;

  /// Passes [active], [playing] and the video size to the system when they
  /// changed.
  Future<void> update({
    required bool active,
    bool playing = false,
    int width = 0,
    int height = 0,
  }) async {
    final next = (active, playing, width, height);
    if (next == _sent) return;
    _sent = next;
    await _window.setVideo(
      active: active,
      playing: playing,
      width: width,
      height: height,
    );
  }
}

/// Reports which screen is in front, for routes that subscribe to it.
final pipRouteObserver = RouteObserver<ModalRoute<void>>();
