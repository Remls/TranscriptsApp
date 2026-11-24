import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import 'languages.dart';
import 'pip.dart';
import 'playback.dart';
import 'player_bar.dart';
import 'ruby.dart';
import 'ruby_text.dart';
import 'session.dart';
import 'settings.dart';
import 'srt.dart';
import 'theme.dart';
import 'video_panel.dart';

const _hideAfter = Duration(seconds: 3);
const _fade = Duration(milliseconds: 200);

/// The mode after [current] when cycling, skipping the translation when
/// there is none.
SubtitleMode nextSubtitleMode(
  SubtitleMode current, {
  required bool hasTranslation,
}) {
  final next = switch (current) {
    .off => SubtitleMode.transcript,
    .transcript => SubtitleMode.translation,
    .translation => SubtitleMode.off,
  };
  return next == .translation && !hasTranslation ? .off : next;
}

/// The text lines of [cue], without speaker labels, taken from [readings]
/// where it has the same line with readings added.
List<String> subtitleLines(Cue cue, {Cue? readings}) {
  final marked = readings?.items.length == cue.items.length
      ? readings!.items
      : null;
  return [
    for (final (i, item) in cue.items.indexed)
      if (item.text.trim().isNotEmpty)
        withReadings(item.text.trim(), marked?[i].text.trim()) ??
            item.text.trim(),
  ];
}

String _subtitleLabel(SubtitleMode mode) => switch (mode) {
  .off => 'Off',
  .transcript => 'Transcript',
  .translation => 'Translation',
};

/// The video of [picture] filling the screen, with playback controls that
/// fade out while it plays, and subtitles.
class FullscreenVideo extends StatefulWidget {
  const FullscreenVideo({
    super.key,
    required this.picture,
    required this.session,
    required this.pip,
  });

  final VideoPicture picture;
  final Session session;
  final PipController pip;

  @override
  State<FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<FullscreenVideo>
    with WidgetsBindingObserver {
  bool _controlsShown = true;
  bool _exiting = false;
  Completer<void>? _portrait;
  Timer? _hideTimer;
  StreamSubscription<bool>? _playingSub;

  /// The side of the last double-tap skip while its marker shows: -1 for
  /// back, 1 for forward.
  int? skipIntervalSide;
  Timer? skipIntervalTimer;
  double _doubleTapX = 0;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.picture.fullscreen = true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (widget.picture.controller.value.aspectRatio > 1) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _playingSub = _session.player.playingStream.listen((playing) {
      if (playing) {
        _scheduleHide();
      } else {
        _hideTimer?.cancel();
        if (mounted) setState(() => _controlsShown = true);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    skipIntervalTimer?.cancel();
    _playingSub?.cancel();
    widget.picture.fullscreen = false;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  bool get _isPortrait {
    final size =
        WidgetsBinding.instance.platformDispatcher.implicitView!.physicalSize;
    return size.height >= size.width;
  }

  @override
  void didChangeMetrics() {
    final portrait = _portrait;
    if (portrait != null && !portrait.isCompleted && _isPortrait) {
      portrait.complete();
    }
  }

  /// Leaves fullscreen, turning the screen back to portrait first so the
  /// recording screen is never drawn in landscape on the way out.
  Future<void> _exit() async {
    if (_exiting) return;
    setState(() => _exiting = true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!_isPortrait) {
      final portrait = _portrait = Completer<void>();
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await portrait.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    if (mounted) Navigator.pop(context);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_session.player.playing) return;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) setState(() => _controlsShown = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsShown = !_controlsShown);
    if (_controlsShown) _scheduleHide();
  }

  void _doubleTapSkip(double width) {
    final side = _doubleTapX < width / 2 ? -1 : 1;
    _session.seekBy(skipInterval * side);
    skipIntervalTimer?.cancel();
    setState(() => skipIntervalSide = side);
    skipIntervalTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => skipIntervalSide = null);
    });
  }

  void _cycleSubtitles() {
    final settings = _session.settings;
    settings.setSubtitleMode(
      nextSubtitleMode(
        settings.subtitleMode,
        hasTranslation: _session.translatedCues.isNotEmpty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = darkVariant(Theme.of(context).colorScheme);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: ListenableBuilder(
        listenable: widget.pip,
        builder: (context, _) => widget.pip.inPip
            ? PipVideo(picture: widget.picture)
            : Theme(
                data: appTheme(scheme),
                child: Scaffold(
                  backgroundColor: Colors.black,
                  body: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      fit: .expand,
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: .opaque,
                            onTap: _toggleControls,
                            onDoubleTapDown: (d) =>
                                _doubleTapX = d.localPosition.dx,
                            onDoubleTap: () =>
                                _doubleTapSkip(constraints.maxWidth),
                            child: Center(
                              child: AspectRatio(
                                aspectRatio:
                                    widget.picture.controller.value.aspectRatio,
                                child: VideoPlayer(widget.picture.controller),
                              ),
                            ),
                          ),
                        ),
                        if (!_exiting) ...[
                          _subtitles(),
                          if (skipIntervalSide != null)
                            skipIntervalMarker(skipIntervalSide!),
                          _controls(context),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _subtitles() {
    return ListenableBuilder(
      listenable: Listenable.merge([_session, _session.settings]),
      builder: (context, _) {
        final mode = _session.settings.subtitleMode;
        final translated =
            mode == .translation && _session.translatedCues.isNotEmpty;
        final recording = _session.recording;
        return SubtitleLayer(
          cues: switch (mode) {
            .off => const [],
            _ => translated ? _session.translatedCues : _session.cues,
          },
          readings:
              mode == .transcript &&
                  _session.settings.readings &&
                  _session.furiganaCues.isNotEmpty
              ? _session.furiganaCues
              : null,
          index: translated
              ? _session.translationActiveIndex
              : _session.activeIndex,
          language: translated || recording == null
              ? _session.languages.resolve('en')
              : _session.languages.resolve(recording.lang),
          raised: _controlsShown,
        );
      },
    );
  }

  Widget skipIntervalMarker(int side) {
    return Align(
      alignment: side < 0 ? const Alignment(-0.6, 0) : const Alignment(0.6, 0),
      child: IgnorePointer(
        child: _RoundButton(
          icon: side < 0 ? Icons.replay_10 : Icons.forward_10,
          size: 64,
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final player = _session.player;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_controlsShown,
        child: AnimatedOpacity(
          opacity: _controlsShown ? 1 : 0,
          duration: _fade,
          child: Listener(
            behavior: .translucent,
            onPointerDown: (_) => _scheduleHide(),
            child: Stack(
              children: [
                const Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: .topCenter,
                          end: .bottomCenter,
                          colors: [
                            Colors.black54,
                            Colors.transparent,
                            Colors.transparent,
                            Colors.black87,
                          ],
                          stops: [0, 0.25, 0.6, 1],
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Exit fullscreen',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _exit,
                      ),
                      Expanded(
                        child: Text(
                          _session.recording?.name ?? '',
                          maxLines: 1,
                          overflow: .ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                Center(
                  child: Row(
                    mainAxisSize: .min,
                    children: [
                      _RoundButton(
                        icon: Icons.replay_10,
                        size: 56,
                        tooltip: 'Back 10 seconds',
                        onPressed: () => _session.seekBy(-skipInterval),
                      ),
                      const SizedBox(width: 40),
                      StreamBuilder<bool>(
                        stream: player.playingStream,
                        builder: (context, snap) {
                          final playing = snap.data ?? player.playing;
                          return _RoundButton(
                            icon: playing ? Icons.pause : Icons.play_arrow,
                            size: 76,
                            tooltip: playing ? 'Pause' : 'Play',
                            onPressed: playing ? player.pause : player.play,
                          );
                        },
                      ),
                      const SizedBox(width: 40),
                      _RoundButton(
                        icon: Icons.forward_10,
                        size: 56,
                        tooltip: 'Forward 10 seconds',
                        onPressed: () => _session.seekBy(skipInterval),
                      ),
                    ],
                  ),
                ),
                Align(
                  alignment: .bottomCenter,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Column(
                        mainAxisSize: .min,
                        children: [
                          PositionBar(player: player),
                          Row(
                            children: [
                              SpeedButton(session: _session),
                              const Spacer(),
                              ListenableBuilder(
                                listenable: _session.settings,
                                builder: (context, _) {
                                  final mode = _session.settings.subtitleMode;
                                  return TextButton.icon(
                                    onPressed: _cycleSubtitles,
                                    icon: Icon(
                                      mode == .off
                                          ? Icons.closed_caption_off_outlined
                                          : Icons.closed_caption,
                                    ),
                                    label: Text(_subtitleLabel(mode)),
                                  );
                                },
                              ),
                              IconButton(
                                tooltip: 'Exit fullscreen',
                                icon: const Icon(Icons.fullscreen_exit),
                                onPressed: _exit,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The subtitle for the cue at [index] in [cues], above the bottom edge and
/// raised while the controls show. Empty [cues] show nothing.
class SubtitleLayer extends StatelessWidget {
  const SubtitleLayer({
    super.key,
    required this.cues,
    required this.index,
    required this.language,
    required this.raised,
    this.readings,
  });

  final List<Cue> cues;

  /// [cues] with readings above their kanji, shown where they match.
  final List<Cue>? readings;
  final ValueListenable<int> index;
  final Language language;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: _fade,
      left: 24,
      right: 24,
      bottom: raised ? 112 : 24,
      child: SafeArea(
        top: false,
        child: ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (context, i, _) => i < 0 || i >= cues.length
              ? const SizedBox.shrink()
              : _SubtitleText(
                  lines: subtitleLines(
                    cues[i],
                    readings: i < (readings?.length ?? 0) ? readings![i] : null,
                  ),
                  language: language,
                ),
        ),
      ),
    );
  }
}

/// A white icon on a dark circle.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.size,
    this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final double size;
  final String? tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed ?? () {},
      iconSize: size * 0.55,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black45,
        foregroundColor: Colors.white,
        fixedSize: Size.square(size),
      ),
      icon: Icon(icon),
    );
  }
}

/// The lines of one subtitle, each on a dark band, in the direction and size
/// [language] gives it.
class _SubtitleText extends StatelessWidget {
  const _SubtitleText({required this.lines, required this.language});

  final List<String> lines;
  final Language language;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Colors.white,
      height: 1.4,
      shadows: const [Shadow(blurRadius: 4)],
    );
    final rubyStyle = style.copyWith(height: rubyLineHeight);
    return Column(
      mainAxisSize: .min,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text.rich(
                  hasRuby(line)
                      ? rubySpan(
                          line,
                          rubyStyle,
                          (text, _) => [TextSpan(text: text)],
                        )
                      : TextSpan(text: line, style: style),
                  textAlign: .center,
                  textDirection: lineIsRtl(line, rtl: language.rtl)
                      ? .rtl
                      : .ltr,
                  textScaler: TextScaler.linear(language.textScale),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
