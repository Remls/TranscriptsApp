import 'package:flutter_test/flutter_test.dart';
import 'package:transcripts/pip.dart';

class _FakeWindow implements PipWindow {
  final calls = <(bool, bool, int, int)>[];
  void Function(bool inPip)? handler;
  void Function(PipAction action)? actionHandler;

  @override
  Future<void> setVideo({
    required bool active,
    required bool playing,
    required int width,
    required int height,
  }) async {
    calls.add((active, playing, width, height));
  }

  @override
  void listen({
    required void Function(bool inPip) onModeChanged,
    required void Function(PipAction action) onAction,
  }) {
    handler = onModeChanged;
    actionHandler = onAction;
  }
}

void main() {
  test('pip is allowed only for a playing, shown, ready video in front', () {
    bool allowed({
      bool isVideo = true,
      bool showVideo = true,
      bool playing = true,
      bool videoReady = true,
      bool inFront = true,
    }) => pipAllowed(
      isVideo: isVideo,
      showVideo: showVideo,
      playing: playing,
      videoReady: videoReady,
      inFront: inFront,
    );

    expect(allowed(), isTrue);
    expect(allowed(isVideo: false), isFalse);
    expect(allowed(showVideo: false), isFalse);
    expect(allowed(playing: false), isFalse);
    expect(allowed(videoReady: false), isFalse);
    expect(allowed(inFront: false), isFalse);
  });

  test('the controller sends only changed states', () async {
    final window = _FakeWindow();
    final pip = PipController(window);

    await pip.update(active: true, playing: true, width: 1280, height: 720);
    await pip.update(active: true, playing: true, width: 1280, height: 720);
    await pip.update(active: false, width: 1280, height: 720);
    await pip.update(active: false);
    await pip.update(active: false);

    expect(window.calls, [
      (true, true, 1280, 720),
      (false, false, 1280, 720),
      (false, false, 0, 0),
    ]);
  });

  test('the controller follows the window mode', () {
    final window = _FakeWindow();
    final pip = PipController(window);
    var notified = 0;
    pip.addListener(() => notified++);

    window.handler!(true);
    expect(pip.inPip, isTrue);
    window.handler!(true);
    window.handler!(false);
    expect(pip.inPip, isFalse);
    expect(notified, 2);
  });

  test('window buttons reach the controller', () {
    final window = _FakeWindow();
    final pip = PipController(window);
    final actions = <PipAction>[];
    window.actionHandler!(PipAction.play);
    pip.onAction = actions.add;
    window.actionHandler!(PipAction.back);
    window.actionHandler!(PipAction.pause);
    expect(actions, [PipAction.back, PipAction.pause]);
  });
}
