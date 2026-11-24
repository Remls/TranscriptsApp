import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'combine_screen.dart';
import 'library.dart';
import 'library_actions.dart' as actions;
import 'library_list.dart';
import 'rechunk.dart';
import 'session.dart';
import 'share_sheet.dart';
import 'split_screen.dart';

/// Opens the combine screen for [folder] with [preselected] ticked. Resolves
/// to the combined recording, or null when nothing was combined.
Future<File?> combineInFolder(
  BuildContext context,
  Session session,
  Directory folder,
  Set<String> preselected,
) {
  return Navigator.push<File>(
    context,
    MaterialPageRoute(
      builder: (_) => CombineScreen(
        session: session,
        folder: folder,
        preselected: preselected,
      ),
    ),
  );
}

/// Every recording in [section] when they share one format, else none.
Set<String> allIfOneFormat(LibrarySection section) {
  final formats = {
    for (final r in section.recordings) p.extension(r.file.path).toLowerCase(),
  };
  return formats.length == 1
      ? {for (final r in section.recordings) r.file.path}
      : {};
}

/// Runs [action] on [recording]. Resolves to the recording a split or
/// combine produced, or null. [onChanged] is called when an undone trash
/// changes the library.
Future<File?> runRecordingAction(
  BuildContext context,
  Session session,
  Recording recording,
  RecordingAction action,
  VoidCallback onChanged,
) async {
  switch (action) {
    case RecordingAction.share:
      await showShareSheet(context, session, recording);
    case RecordingAction.split:
      return Navigator.push<File>(
        context,
        MaterialPageRoute(
          builder: (_) => SplitScreen(session: session, recording: recording),
        ),
      );
    case RecordingAction.combine:
      return combineInFolder(context, session, recording.file.parent, {
        for (final f in familyMembers(recording.file)) f.path,
      });
    case RecordingAction.rename:
      await actions.renameRecording(context, session, recording);
    case RecordingAction.move:
      await actions.moveRecording(context, session, recording);
    case RecordingAction.trash:
      await actions.trashRecording(context, session, recording, onChanged);
  }
  return null;
}
