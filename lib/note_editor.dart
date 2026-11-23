import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'notes.dart';
import 'session.dart';
import 'srt.dart';

enum _Result { save, delete }

/// The longest edge, in pixels, a picture is stored and sent with.
const _maxPictureEdge = 1568.0;

/// Opens the editor for a new note at [at] seconds (the current position
/// when null), or for [existing]. Playback pauses while it is open and
/// resumes afterwards if it was playing.
Future<void> editNote(
  BuildContext context,
  Session session, {
  double? at,
  Note? existing,
}) async {
  final player = session.player;
  final wasPlaying = player.playing;
  final total = (player.duration?.inMilliseconds ?? 0) / 1000;
  var time = existing?.time ?? at ?? player.position.inMilliseconds / 1000;
  if (wasPlaying) await player.pause();
  if (!context.mounted) return;

  final text = TextEditingController(text: existing?.text ?? '');
  final stored = existing == null ? null : session.noteImageOf(existing);
  File? picked;
  var removed = false;

  final result = await showDialog<_Result>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        void nudge(double seconds) => setDialogState(() {
          time = (time + seconds).clamp(0, total > 0 ? total : double.infinity);
        });
        Widget step(String label, double seconds) => TextButton(
          onPressed: () => nudge(seconds),
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 36),
            padding: EdgeInsets.zero,
          ),
          child: Text(label),
        );
        Future<void> pick(ImageSource source) async {
          final image = await ImagePicker().pickImage(
            source: source,
            maxWidth: _maxPictureEdge,
            maxHeight: _maxPictureEdge,
            imageQuality: 85,
          );
          if (image == null) return;
          setDialogState(() {
            picked = File(image.path);
            removed = false;
          });
        }

        final picture = picked ?? (removed ? null : stored);
        return AlertDialog(
          title: Text(existing == null ? 'Add note' : 'Edit note'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: .min,
                crossAxisAlignment: .start,
                children: [
                  Row(
                    mainAxisAlignment: .spaceBetween,
                    children: [
                      step('-5s', -5),
                      step('-1s', -1),
                      Text(
                        formatClock(time),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      step('+1s', 1),
                      step('+5s', 5),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: text,
                    autofocus: existing == null,
                    minLines: 2,
                    maxLines: 6,
                    textCapitalization: .sentences,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Context for the summary',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  if (picture != null)
                    Stack(
                      alignment: .topRight,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            picture,
                            height: 120,
                            width: double.infinity,
                            fit: .cover,
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Remove picture',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setDialogState(() {
                            picked = null;
                            removed = true;
                          }),
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => pick(ImageSource.gallery),
                            icon: const Icon(Icons.image_outlined, size: 18),
                            label: const Text('Gallery'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => pick(ImageSource.camera),
                            icon: const Icon(
                              Icons.photo_camera_outlined,
                              size: 18,
                            ),
                            label: const Text('Camera'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () => Navigator.pop(context, _Result.delete),
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: text.text.trim().isEmpty && picture == null
                  ? null
                  : () => Navigator.pop(context, _Result.save),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );

  if (session.recording != null) {
    switch (result) {
      case _Result.save:
        session.saveNote(
          Note(
            id: existing?.id ?? newNoteId(),
            time: time,
            text: text.text.trim(),
            image: existing?.image,
          ),
          newImage: picked,
          removeImage: removed,
        );
      case _Result.delete:
        session.deleteNote(existing!);
      case null:
        break;
    }
  }
  if (wasPlaying) player.play();
}

/// Shows [picture] full screen, with pinch to zoom.
void showPicture(BuildContext context, File picture) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: InteractiveViewer(maxScale: 6, child: Image.file(picture)),
        ),
      ),
    ),
  );
}
