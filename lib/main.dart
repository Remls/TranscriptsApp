import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_screen.dart';
import 'job_keeper.dart';
import 'library.dart';
import 'media_session.dart';
import 'media_tools.dart';
import 'pip.dart';
import 'playback.dart';
import 'session.dart';
import 'settings.dart';
import 'theme.dart';
import 'video_playback.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final handler = await AudioService.init(
    builder: PlaybackHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'io.remls.transcripts.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
      androidNotificationIcon: 'drawable/ic_stat_lines',
      fastForwardInterval: skipInterval,
      rewindInterval: skipInterval,
    ),
  );
  final base = await getApplicationDocumentsDirectory();
  final library = Library(Directory(p.join(base.path, 'audios')));
  final prefs = await SharedPreferences.getInstance();
  final settings = await Settings.load(prefs, const KeystoreSecretStore());
  final session = Session(
    library,
    prefs,
    settings,
    FfmpegMediaTools(),
    player: MediaSessionPlayback(
      audioPlayback: JustAudioPlayback(),
      videoPlayback: VideoPlayback(),
      handler: handler,
      isVideo: (file) =>
          videoExts.contains(p.extension(file.path).toLowerCase()),
    ),
  );
  JobKeeper(
    const AndroidBackgroundKeeper(),
    isOnScreen: () =>
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  ).attach(session);
  runApp(
    TranscriptsApp(
      session: session,
      pip: PipController(const AndroidPipWindow()),
    ),
  );
}

class TranscriptsApp extends StatelessWidget {
  const TranscriptsApp({super.key, required this.session, required this.pip});

  final Session session;
  final PipController pip;

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (wallpaperLight, wallpaperDark) {
        wallpaperColorsAvailable = wallpaperLight != null;
        return ListenableBuilder(
          listenable: session.settings,
          builder: (context, _) {
            final wallpaper = session.settings.wallpaperColors;
            return MaterialApp(
              title: 'Transcripts',
              theme: appTheme(
                (wallpaper ? wallpaperLight : null) ?? appColorScheme(.light),
              ),
              darkTheme: appTheme(
                (wallpaper ? wallpaperDark : null) ?? appColorScheme(.dark),
              ),
              themeMode: session.settings.themeMode,
              navigatorObservers: [pipRouteObserver],
              home: LibraryScreen(session: session, pip: pip),
            );
          },
        );
      },
    );
  }
}
