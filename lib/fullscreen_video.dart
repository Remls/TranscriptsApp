import 'dart:async';
import 'dart:math';

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
import 'sheet.dart';
import 'srt.dart';
import 'theme.dart';
import 'video_panel.dart';

const _hideAfter = Duration(seconds: 3);
const _fade = Duration(milliseconds: 200);

/// What fullscreen video shows as subtitles.
enum SubtitleMode { off, transcript, translation }

/// The first of [preferred] that the recording has, or off.
SubtitleMode firstSubtitles(
  List<SubtitleMode> preferred, {
  required bool hasTranscript,
  required bool hasTranslation,
}) {
  for (final mode in preferred) {
    if (mode == .transcript && hasTranscript) return mode;
    if (mode == .translation && hasTranslation) return mode;
  }
  return .off;
}

/// A choice in the subtitle menu: a mode, with the translation's language
/// for [SubtitleMode.translation].
typedef SubtitleChoice = (SubtitleMode, String?);

/// The subtitle menu's choices for a recording with a transcript when
/// [hasTranscript], translated into [translations]. Empty when there is
/// nothing to show.
List<SubtitleChoice> subtitleChoices({
  required bool hasTranscript,
  required List<String> translations,
}) => [
  if (hasTranscript) ...[
    (SubtitleMode.off, null),
    (SubtitleMode.transcript, null),
    for (final lang in translations) (SubtitleMode.translation, lang),
  ],
];

/// The text lines of [cue], without speaker labels, taken from [readings]
/// where it has the same line with readings added. When the lines come from
/// more than one speaker, each starts with a dash. [speakerOf] gives the
/// speaker of each line by its index.
List<String> subtitleLines(
  Cue cue, {
  Cue? readings,
  String? Function(int item)? speakerOf,
}) {
  final marked = readings?.items.length == cue.items.length
      ? readings!.items
      : null;
  final shown = [
    for (final (i, item) in cue.items.indexed)
      if (item.text.trim().isNotEmpty) i,
  ];
  final speakers = {
    for (final i in shown) speakerOf?.call(i) ?? cue.items[i].speaker,
  };
  final dash = speakers.length > 1 ? '– ' : '';
  return [
    for (final i in shown)
      dash +
          (withReadings(cue.items[i].text.trim(), marked?[i].text.trim()) ??
              cue.items[i].text.trim()),
  ];
}

/// The narrowest width up to [maxWidth] that lays [span] out in as few
/// lines as [maxWidth] does, so that its lines come out about even.
/// [placeholders] are the sizes of its widgets, in order.
double balancedWidth(
  InlineSpan span,
  double maxWidth, {
  required TextScaler textScaler,
  required TextDirection textDirection,
  List<PlaceholderDimensions> placeholders = const [],
}) {
  final painter = TextPainter(
    text: span,
    textDirection: textDirection,
    textScaler: textScaler,
  )..setPlaceholderDimensions(placeholders);
  int lines(double width) {
    painter.layout(maxWidth: width);
    return painter.computeLineMetrics().length;
  }

  final target = lines(maxWidth);
  var width = maxWidth;
  if (target > 1) {
    var low = 0.0;
    while (width - low > 1) {
      final middle = (low + width) / 2;
      if (lines(middle) > target) {
        low = middle;
      } else {
        width = middle;
      }
    }
  }
  painter.dispose();
  return width.ceilToDouble();
}

/// How long fullscreen takes to open or close when not dragged.
const fullscreenTransition = Duration(milliseconds: 250);

/// [video] at [t] of the way from [from] to filling the screen, over black
/// that fades in with it. A wide video on an upright screen instead zooms
/// in from the top of [from], before the screen turns sideways. [drop]
/// moves it down and shrinks it over the black, for a drag that closes
/// fullscreen.
class FullscreenFrame extends StatelessWidget {
  const FullscreenFrame({
    super.key,
    required this.t,
    required this.from,
    required this.aspectRatio,
    required this.video,
    this.drop = 0,
  });

  final double t;
  final Rect from;
  final double aspectRatio;
  final Widget video;
  final double drop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = constraints.biggest;
        final width = min(screen.width, screen.height * aspectRatio);
        final full = aspectRatio > 1 && screen.height > screen.width
            ? Rect.fromLTWH(
                from.center.dx - from.width * 0.65,
                from.top,
                from.width * 1.3,
                from.height * 1.3,
              )
            : Rect.fromCenter(
                center: screen.center(Offset.zero),
                width: width,
                height: width / aspectRatio,
              );
        final dropped = (drop / screen.height).clamp(0.0, 1.0);
        final scale = 1 - dropped * 0.3;
        final open = Rect.fromCenter(
          center: full.center + Offset(0, drop),
          width: full.width * scale,
          height: full.height * scale,
        );
        return Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withValues(alpha: t)),
            ),
            Positioned.fromRect(rect: Rect.lerp(from, open, t)!, child: video),
          ],
        );
      },
    );
  }
}

/// The route [FullscreenVideo] opens in. It is see-through, so the video can
/// grow out of the panel at [from] over the recording screen, and it starts
/// at [startProgress] to carry on from a drag that opened it.
class FullscreenRoute extends PageRoute<void> {
  FullscreenRoute({
    required this.from,
    required this.builder,
    this.startProgress = 0,
  });

  /// Where the video sits in the panel, in global coordinates.
  final Rect from;
  final WidgetBuilder builder;
  final double startProgress;

  @override
  bool get opaque => false;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  Duration get transitionDuration => fullscreenTransition;

  @override
  AnimationController createAnimationController() =>
      super.createAnimationController()..value = startProgress;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  /// Hands the route's progress to a drag.
  void startDrag() {
    navigator!.didStartUserGesture();
    controller!.stop();
  }

  double get dragProgress => controller!.value;
  set dragProgress(double value) => controller!.value = value.clamp(0, 1);

  /// Ends a drag by opening the route fully or closing it.
  void endDrag({required bool open}) {
    if (open) {
      controller!.forward();
    } else {
      navigator!.pop();
    }
    navigator!.didStopUserGesture();
  }
}

/// The video of [picture] filling the screen, with playback controls that
/// fade out while it plays, and subtitles. Opened in a [FullscreenRoute]; a
/// drag down closes it.
class FullscreenVideo extends StatefulWidget {
  const FullscreenVideo({
    super.key,
    required this.picture,
    required this.session,
    required this.pip,
    required this.subtitles,
  });

  final VideoPicture picture;
  final Session session;
  final PipController pip;

  /// The subtitles shown when the screen opens.
  final SubtitleMode subtitles;

  @override
  State<FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<FullscreenVideo>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _controlsShown = true;
  bool _exiting = false;
  bool _entered = false;
  FullscreenRoute? _route;

  /// How far a drag has moved the video down while the screen is landscape.
  late final _drop = AnimationController.unbounded(vsync: this);

  /// Whether a drag down is moving the route itself, in portrait.
  bool _routeDrag = false;
  late SubtitleMode _subtitleMode = widget.subtitles;
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = _route = ModalRoute.of(context)! as FullscreenRoute;
    route.animation!.addStatusListener(_onRouteStatus);
    _onRouteStatus(route.animation!.status);
  }

  /// Once fully open, hides the system bars and turns wide videos sideways.
  void _onRouteStatus(AnimationStatus status) {
    if (status != .completed || _entered || _exiting) return;
    _entered = true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (widget.picture.controller.value.aspectRatio > 1) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteStatus);
    _drop.dispose();
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
    if (mounted) setState(() {});
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

  double get _dragDistance => MediaQuery.sizeOf(context).height * 0.6;

  void _dragStart(DragStartDetails details) {
    if (_exiting || !_entered) return;
    _routeDrag = _isPortrait;
    if (_routeDrag) _route!.startDrag();
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (_exiting || !_entered) return;
    final delta = details.primaryDelta ?? 0;
    if (_routeDrag) {
      _route!.dragProgress -= delta / _dragDistance;
    } else {
      _drop.value = max(0, _drop.value + delta);
    }
  }

  void _dragEnd(DragEndDetails details) {
    if (_exiting || !_entered) return;
    final velocity = details.primaryVelocity ?? 0;
    final progress = _routeDrag
        ? 1 - _route!.dragProgress
        : _drop.value / _dragDistance;
    final close = velocity > 700 || (progress > 0.3 && velocity >= -700);
    if (_routeDrag) {
      if (close) {
        setState(() => _exiting = true);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
      _route!.endDrag(open: !close);
    } else if (close) {
      _exit();
    } else {
      _drop.animateTo(0, duration: fullscreenTransition, curve: Curves.easeOut);
    }
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

  Widget _subtitlesButton() {
    return Builder(
      builder: (buttonContext) => IconButton(
        tooltip: 'Subtitles',
        onPressed: () => _pickSubtitles(buttonContext),
        icon: Icon(
          _subtitleMode == .off
              ? Icons.closed_caption_disabled_outlined
              : Icons.closed_caption,
        ),
      ),
    );
  }

  /// Asks which subtitles to show: off, the transcript or a translation.
  /// The sheet takes its colors from [context], inside fullscreen's dark
  /// theme.
  Future<void> _pickSubtitles(BuildContext context) async {
    _hideTimer?.cancel();
    final languages = _session.languages;
    final recording = _session.recording;
    final choices = subtitleChoices(
      hasTranscript: _session.cues.isNotEmpty,
      translations: recording?.translations ?? const [],
    );
    final shown = (
      _subtitleMode,
      _subtitleMode == .translation ? _session.translationLang : null,
    );
    final choice = await showSheet<SubtitleChoice>(
      context,
      builder: (context) => SheetBody(
        title: 'Subtitles',
        header: choices.isEmpty
            ? Text(
                'Transcribe this recording to show subtitles.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              )
            : null,
        children: [
          for (final choice in choices)
            SheetOption(
              leading: Icon(switch (choice.$1) {
                .off => Icons.closed_caption_disabled_outlined,
                .transcript => Icons.subject,
                .translation => Icons.translate,
              }),
              title: switch (choice.$1) {
                .off => 'Off',
                .transcript =>
                  'Transcript (${languages.resolve(recording?.lang ?? defaultLang).name})',
                .translation =>
                  'Translation (${languages.resolve(choice.$2!).name})',
              },
              selected: choice == shown,
              onTap: () => Navigator.pop(context, choice),
            ),
        ],
      ),
    );
    if (choice != null && mounted) {
      final (mode, lang) = choice;
      if (lang != null) _session.showTranslation(lang);
      setState(() => _subtitleMode = mode);
    }
    _scheduleHide();
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
                  backgroundColor: Colors.transparent,
                  body: LayoutBuilder(
                    builder: (context, constraints) => AnimatedBuilder(
                      animation: Listenable.merge([_route!.animation, _drop]),
                      builder: (context, _) {
                        final t = _route!.animation!.value;
                        final turning =
                            _isPortrait &&
                            widget.picture.controller.value.aspectRatio > 1;
                        final settled = t >= 1 && _drop.value == 0 && !turning;
                        return Stack(
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
                                onVerticalDragStart: _dragStart,
                                onVerticalDragUpdate: _dragUpdate,
                                onVerticalDragEnd: _dragEnd,
                                child: FullscreenFrame(
                                  t: t,
                                  from: _route!.from,
                                  drop: _drop.value,
                                  aspectRatio: widget
                                      .picture
                                      .controller
                                      .value
                                      .aspectRatio,
                                  video: VideoPlayer(widget.picture.controller),
                                ),
                              ),
                            ),
                            if (settled && !_exiting) ...[
                              _subtitles(),
                              if (skipIntervalSide != null)
                                skipIntervalMarker(skipIntervalSide!),
                              _controls(context),
                            ],
                          ],
                        );
                      },
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
        final mode = _subtitleMode;
        final translated =
            mode == .translation && _session.translatedCues.isNotEmpty;
        final recording = _session.recording;
        return SubtitleLayer(
          cues: switch (mode) {
            .off => const [],
            _ => translated ? _session.translatedCues : _session.cues,
          },
          readings: !_session.settings.readings || mode == .off
              ? null
              : translated
              ? _session.translationFuriganaCues.isEmpty
                    ? null
                    : _session.translationFuriganaCues
              : _session.furiganaCues.isEmpty
              ? null
              : _session.furiganaCues,
          index: translated
              ? _session.translationActiveIndex
              : _session.activeIndex,
          language: _session.languages.resolve(
            translated || recording == null
                ? _session.translationLang
                : recording.lang,
          ),
          raised: _controlsShown,
          aspectRatio: widget.picture.controller.value.aspectRatio,
          speakerOverrides: translated ? const {} : _session.speakerOverrides,
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
                              SpeedButton(
                                session: _session,
                                onOpen: () => _hideTimer?.cancel(),
                                onClose: _scheduleHide,
                              ),
                              const Spacer(),
                              _subtitlesButton(),
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
    this.aspectRatio = 16 / 9,
    this.speakerOverrides = const {},
  });

  final List<Cue> cues;

  /// [cues] with readings above their kanji, shown where they match.
  final List<Cue>? readings;
  final ValueListenable<int> index;
  final Language language;
  final bool raised;

  /// The video's width over its height, for sizing the text to the picture.
  final double aspectRatio;

  /// Speaker ids keyed by "cueIndex:itemIndex", replacing the SRT's own label.
  final Map<String, String> speakerOverrides;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final videoHeight = min(screen.height, screen.width / aspectRatio);
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
                    speakerOf: (item) => speakerOverrides['$i:$item'],
                  ),
                  language: language,
                  fontSize: (videoHeight * 0.045).clamp(14, 30),
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
/// [language] gives it. Each line is at most about 26 em wide, and lines that
/// wrap are evened out.
class _SubtitleText extends StatelessWidget {
  const _SubtitleText({
    required this.lines,
    required this.language,
    required this.fontSize,
  });

  final List<String> lines;
  final Language language;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Colors.white,
      fontSize: fontSize,
      fontWeight: .w500,
      height: 1.35,
    );
    final rubyStyle = style.copyWith(height: rubyLineHeight);
    final scaler = TextScaler.linear(language.textScale);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = min(
          constraints.maxWidth - 16,
          scaler.scale(fontSize) * 26,
        );
        return Column(
          mainAxisSize: .min,
          children: [
            for (final line in lines)
              _line(line, style, rubyStyle, scaler, maxWidth),
          ],
        );
      },
    );
  }

  Widget _line(
    String line,
    TextStyle style,
    TextStyle rubyStyle,
    TextScaler scaler,
    double maxWidth,
  ) {
    final ruby = hasRuby(line);
    final span = ruby
        ? rubySpan(line, rubyStyle, (text, _) => [TextSpan(text: text)])
        : TextSpan(text: line, style: style);
    final direction = lineIsRtl(line, rtl: language.rtl)
        ? TextDirection.rtl
        : TextDirection.ltr;
    final width = balancedWidth(
      span,
      maxWidth,
      textScaler: scaler,
      textDirection: direction,
      placeholders: [
        if (ruby)
          for (final segment in parseRuby(line))
            if (segment.reading != null)
              rubyWordDimensions(
                segment.base,
                segment.reading!,
                rubyStyle,
                scale: scaler.scale(fontSize) / fontSize,
              ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: Text.rich(
              span,
              textAlign: .center,
              textDirection: direction,
              textScaler: scaler,
            ),
          ),
        ),
      ),
    );
  }
}
