# CLAUDE.md

Project guidance for Claude Code in this repo.

## What this is

A Flutter app for Android that transcribes recordings with Gemini, then translates and summarizes them with Gemini or Claude.

## Run and test

```bash
dart format lib test
```

```bash
flutter analyze
```

```bash
flutter test
```

Analysis must be clean and every test must pass before a step is reported done.

- Release build: `flutter build apk --release --split-per-abi`. Phones take `app-arm64-v8a-release.apk`.
- Signing reads `android/key.properties`, which is gitignored and holds the keystore password. Never print or commit it.
- Raise the build number in `pubspec.yaml` (`version: name+build`) for every build that goes on a phone.

## Billing in tests

Do not run a real transcription, translation or summary. Unit tests use `MockClient` and `FakeMediaTools` (`test/fake_media_tools.dart`). On the emulator, turn on airplane mode before starting a job:

```bash
adb shell cmd connectivity airplane-mode enable
```

Split and combine use only ffmpeg and are free. Listing models is free.

## Flutter version notes

Flutter 3.50, Dart 3.14.

- Material comes from `package:material_ui/material_ui.dart`.
- Dot shorthands are used throughout (`.center`, `.rtl`).
- A `SnackBar` with an action needs `persist: false` to auto-dismiss. Every snackbar passes it.

## Architecture

State is plain `ChangeNotifier` objects.

- `LibraryScreen` (`library_screen.dart`) is the first screen: the folders and recordings, imports, shared files, library search and the mini player. It pushes `RecordingScreen` (`recording_screen.dart`) for the open recording.
- `Session` (`session.dart`) owns the open recording, its cues, its `Playback`, and the running jobs.
- `Playback` (`playback.dart`) is the player interface. `MediaSessionPlayback` (`media_session.dart`) plays audio files with `JustAudioPlayback` and videos, picture and sound together, with `VideoPlayback` (`video_playback.dart`), and shows them in the system media session through `PlaybackHandler` (`audio_service`).
- `playbackSource` (`playback_source.dart`) checks a recording's codecs with ffprobe. A file Android cannot play gets a converted copy in its sidecar folder, made once and left out of backups and zips.
- `Settings` wraps `SharedPreferences` and the Keystore-backed secrets.
- `Library` (`library.dart`) is the on-disk layout. Sidecar paths go through `sidecarDir()` and `sidecarFile()`, and per-language files through `translationFile()`, `translationFuriganaFile()` and `summaryFile()`. Do not build them by hand.
- `LanguageList` (`languages.dart`) is the user's language list, stored in `<library>/.languages.json`. Direction, font size and prompt notes come from it. Do not hardcode language checks elsewhere.
- Jobs extend `Job` (`job.dart`): a status line, streamed output, cancel.
- Pickers and action lists are bottom sheets built from `showSheet`, `SheetBody` and `SheetOption` (`sheet.dart`). Overflow menus use `MenuButton` (`menu.dart`).
- Pure logic stays out of widgets so it can be tested with temp directories and fakes.
- `MainActivity.kt` extends `AudioServiceActivity` and hosts the share, save-as, job service and PiP channels.

## Library layout

```
audios/
  <folder>/
    <name>.mp3
    .<name>/
      transcript.srt  transcript.txt  lang  furigana.srt
      translation.srt  translation.<code>.srt  furigana.<code>.srt
      summary.md  summary.<code>.md
      speakers.json  speaker-overrides.json
      audio.mp3  notes.json  notes/<id>.jpg  context.txt
      playback.mkv or playback.m4a
    .summary-flat.md  .summary-hier.md
  .languages.json
  .trash/
```

Folders are one level deep. `lang` absent means `dv`. `furigana.srt` is the transcript with readings in Aozora ruby notation (`｜漢字《かんじ》`), written only for Japanese transcripts that have readings. `transcript.srt` stays plain.

Translations and summaries are per language. English stays in `translation.srt` and `summary.md`, and other languages go in `translation.<code>.srt` and `summary.<code>.md`. A Japanese translation keeps its readings in `furigana.ja.srt`. `context.txt` is the user's note about the recording, sent with the transcription, translation and summary prompts along with the file name.

## Guards to keep

- The three SRT timestamp guards: the clamp in `parseSrt`, the write-path cleanup `cleanModelSrt`, and the repair pass `repairSrtFile` on restore. They protect different points. Keep all three.
- Prompts in `prompts.dart` match fixtures in `test/fixtures/`. A prompt change updates its fixture.
- Active-cue selection picks the shortest cue that contains the current time.

## Traps

- `dart format` reflows code. Read the current text before an exact-string edit.
- Closing the open recording removes the recording screen. Flows that close it use a context that outlives that screen.
- `AlertDialog` content with an infinite-width child renders blank. Wrap it in `SizedBox(width: double.maxFinite)`.
- Closures passed to `Isolate.run` must be created in top-level functions.
- Nothing may declare `android.permission.CAMERA`, or the system camera intent stops working. After adding a package, run `aapt2 dump permissions` on the APK.
- Release builds shrink resources. A drawable that code looks up by name must be listed in `android/app/src/main/res/raw/keep.xml`, or the lookup fails only in release builds.
- `assets/fonts/Faruma.ttf` is a Thaana-only subset, so Latin text does not render in it.
- Installing a build over a newer one fails with `INSTALL_FAILED_VERSION_DOWNGRADE`, and `flutter run` then uninstalls the app, which deletes its library.

## Emulator

- Put files in private storage: push to `/data/local/tmp`, then `adb shell run-as io.remls.transcripts cp -r /data/local/tmp/<dir> app_flutter/audios/`.
- Screenshots: `adb exec-out screencap -p`.
- Test media is synthetic, made with ffmpeg (`sine` for tones, `testsrc2` for video).

## House rules

- No incident specifics in comments. A comment says what a thing is.
- Other people's libraries must keep working across updates. A change to the sidecar layout or a stored file format needs to read the old form too.
- Never use the user's own recordings or names as examples in code, tests or docs.
