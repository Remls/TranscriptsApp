import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_screen.dart';
import 'job_keeper.dart';
import 'library.dart';
import 'media_tools.dart';
import 'pip.dart';
import 'session.dart';
import 'settings.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'io.remls.transcripts.playback',
    androidNotificationChannelName: 'Playback',
    androidNotificationOngoing: true,
    androidNotificationIcon: 'drawable/ic_stat_lines',
  );
  final base = await getApplicationDocumentsDirectory();
  final library = Library(Directory(p.join(base.path, 'audios')));
  final prefs = await SharedPreferences.getInstance();
  final settings = await Settings.load(prefs, const KeystoreSecretStore());
  final session = Session(library, prefs, settings, FfmpegMediaTools());
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
      builder: (wallpaperLight, wallpaperDark) => ListenableBuilder(
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
            home: HomeScreen(session: session, pip: pip),
          );
        },
      ),
    );
  }
}
