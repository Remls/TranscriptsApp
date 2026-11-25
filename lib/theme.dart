import 'package:material_ui/material_ui.dart';

/// The app's theme for [scheme].
ThemeData appTheme(ColorScheme scheme) {
  return ThemeData(colorScheme: scheme, fontFamilyFallback: const ['Faruma']);
}

/// A dark scheme in the colors of [scheme].
ColorScheme darkVariant(ColorScheme scheme) =>
    .fromSeed(seedColor: scheme.primary, brightness: .dark);

/// The app's color scheme for [brightness].
ColorScheme appColorScheme(Brightness brightness) =>
    .fromSeed(seedColor: Colors.teal, brightness: brightness);

/// Whether this phone offers colors from its wallpaper. Set when the app
/// starts.
bool wallpaperColorsAvailable = true;
