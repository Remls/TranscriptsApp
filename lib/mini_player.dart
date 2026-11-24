import 'package:material_ui/material_ui.dart';

import 'library.dart';

/// A bar for the loaded recording: its name and folder, play/pause, and a
/// line showing how far it has played. Tapping it calls [onOpen].
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.recording,
    required this.playing,
    required this.progress,
    required this.onPlay,
    required this.onPause,
    required this.onOpen,
  });

  final Recording recording;

  /// Whether the recording is playing.
  final Stream<bool> playing;

  /// How far the recording has played, from 0 to 1.
  final Stream<double> progress;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final folder = recording.relPath.contains('/')
        ? recording.relPath.substring(0, recording.relPath.indexOf('/'))
        : null;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: InkWell(
          onTap: onOpen,
          child: Column(
            mainAxisSize: .min,
            children: [
              StreamBuilder<double>(
                stream: progress,
                builder: (context, snap) => LinearProgressIndicator(
                  minHeight: 2,
                  value: snap.data ?? 0,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                child: Row(
                  children: [
                    Icon(
                      recording.isVideo
                          ? Icons.videocam_outlined
                          : Icons.graphic_eq,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: .min,
                        crossAxisAlignment: .start,
                        children: [
                          Text(
                            recording.name,
                            maxLines: 1,
                            overflow: .ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (folder != null)
                            Text(
                              folder,
                              maxLines: 1,
                              overflow: .ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream: playing,
                      builder: (context, snap) {
                        final now = snap.data ?? false;
                        return IconButton(
                          tooltip: now ? 'Pause' : 'Play',
                          icon: Icon(now ? Icons.pause : Icons.play_arrow),
                          onPressed: now ? onPause : onPlay,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
