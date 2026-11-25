import 'package:material_ui/material_ui.dart';

import 'playback.dart';
import 'session.dart';
import 'srt.dart';
import 'menu.dart';

String _speedLabel(double speed) {
  final text = speed == speed.roundToDouble()
      ? speed.toStringAsFixed(0)
      : speed.toString();
  return '$text×';
}

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.session, required this.onAddNote});

  final Session session;

  /// Adds a note at the current position.
  final VoidCallback onAddNote;

  Playback get _player => session.player;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Column(
            mainAxisSize: .min,
            children: [
              PositionBar(player: _player),
              Row(
                children: [
                  SizedBox(width: 72, child: SpeedButton(session: session)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Back 10 seconds',
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => session.seekBy(-skipInterval),
                  ),
                  const SizedBox(width: 8),
                  StreamBuilder<bool>(
                    stream: _player.playingStream,
                    builder: (context, snap) {
                      final playing = snap.data ?? _player.playing;
                      return IconButton.filled(
                        iconSize: 32,
                        tooltip: playing ? 'Pause' : 'Play',
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        onPressed: playing ? _player.pause : _player.play,
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Forward 10 seconds',
                    icon: const Icon(Icons.forward_10),
                    onPressed: () => session.seekBy(skipInterval),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 72,
                    child: Align(
                      alignment: .centerRight,
                      child: IconButton(
                        tooltip: 'Add note here',
                        icon: const Icon(Icons.note_add_outlined),
                        onPressed: onAddNote,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The seek bar of [player], with the elapsed and total time on either side.
class PositionBar extends StatefulWidget {
  const PositionBar({super.key, required this.player});

  final Playback player;

  @override
  State<PositionBar> createState() => _PositionBarState();
}

class _PositionBarState extends State<PositionBar> {
  /// The slider value in seconds while the thumb is being dragged.
  double? _dragValue;

  Playback get _player => widget.player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return StreamBuilder<Duration?>(
      stream: _player.durationStream,
      builder: (context, durationSnap) {
        final total =
            (durationSnap.data ?? _player.duration ?? Duration.zero)
                .inMilliseconds /
            1000;
        return StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (context, positionSnap) {
            final position =
                (positionSnap.data ?? _player.position).inMilliseconds / 1000;
            final value = (_dragValue ?? position).clamp(0.0, total);
            return Row(
              children: [
                Text(formatClock(value), style: timeStyle),
                Expanded(
                  child: Slider(
                    value: value,
                    max: total > 0 ? total : 1,
                    onChanged: total > 0
                        ? (v) => setState(() => _dragValue = v)
                        : null,
                    onChangeEnd: (v) {
                      _player.seek(Duration(milliseconds: (v * 1000).round()));
                      setState(() => _dragValue = null);
                    },
                  ),
                ),
                Text(formatClock(total), style: timeStyle),
              ],
            );
          },
        );
      },
    );
  }
}

/// The playback speed of [session], with a menu of [playbackSpeeds].
class SpeedButton extends StatelessWidget {
  const SpeedButton({
    super.key,
    required this.session,
    this.onOpen,
    this.onClose,
  });

  final Session session;

  /// Called when the speed menu opens and closes.
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        return MenuButton(
          tooltip: 'Playback speed',
          onOpen: onOpen,
          onClose: onClose,
          groups: [
            [
              for (final s in playbackSpeeds)
                menuEntry(
                  null,
                  _speedLabel(s),
                  () => session.setSpeed(s),
                  selected: s == session.speed,
                ),
            ],
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Text(
              _speedLabel(session.speed),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        );
      },
    );
  }
}
