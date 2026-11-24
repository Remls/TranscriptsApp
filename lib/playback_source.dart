import 'dart:io';

import 'library.dart';
import 'media_tools.dart';

/// How a recording is made playable.
enum PlaybackPlan {
  /// The file plays as it is.
  asIs,

  /// A copy with the sound converted, keeping the picture.
  convertSound,

  /// A sound-only copy, for audio Android cannot play or a picture it
  /// cannot show.
  soundOnly,
}

/// Containers Android's player opens, as `ffprobe` names them. A name may
/// list several, separated by commas.
const _playableFormats = {
  'mov',
  'mp4',
  'm4a',
  '3gp',
  '3g2',
  'matroska',
  'webm',
  'mpegts',
  'avi',
  'ogg',
  'wav',
  'flac',
  'amr',
  'mp3',
  'aac',
};

/// Sound codecs Android plays.
const _playableAudio = {
  'aac',
  'mp3',
  'opus',
  'vorbis',
  'flac',
  'amr_nb',
  'amr_wb',
  'pcm_u8',
  'pcm_s16le',
  'pcm_s24le',
  'pcm_s32le',
  'pcm_f32le',
  'pcm_alaw',
  'pcm_mulaw',
};

/// Picture codecs Android plays.
const _playableVideo = {'h264', 'hevc', 'vp8', 'vp9', 'av1', 'mpeg4', 'h263'};

/// How to make a file with [streams] playable. [isVideo] is whether it is a
/// video recording.
PlaybackPlan planPlayback(MediaStreams streams, {required bool isVideo}) {
  final container = streams.format.split(',').any(_playableFormats.contains);
  final audio = streams.audio == null || _playableAudio.contains(streams.audio);
  final video = streams.video;
  if (!isVideo || video == null) {
    return container && audio ? PlaybackPlan.asIs : PlaybackPlan.soundOnly;
  }
  if (!_playableVideo.contains(video)) return PlaybackPlan.soundOnly;
  return container && audio ? PlaybackPlan.asIs : PlaybackPlan.convertSound;
}

/// The file to play for a recording, and whether a video's picture cannot
/// be shown.
typedef PlaybackSource = ({File file, bool pictureUnavailable});

/// The file to play for [recording]: the recording itself, or a playback
/// copy in its sidecar folder, made with [media] the first time it is
/// needed. [onConverting] is called before a copy is made.
Future<PlaybackSource> playbackSource(
  Library library,
  MediaTools media,
  File recording, {
  void Function()? onConverting,
}) async {
  final isVideo = library.describe(recording).isVideo;
  final pictureCopy = library.sidecarFile(recording, Sidecar.playbackVideo);
  final soundCopy = library.sidecarFile(recording, Sidecar.playbackSound);
  if (pictureCopy.existsSync()) {
    return (file: pictureCopy, pictureUnavailable: false);
  }
  if (soundCopy.existsSync()) {
    return (file: soundCopy, pictureUnavailable: isVideo);
  }
  final streams = await media.streams(recording);
  if (streams == null) return (file: recording, pictureUnavailable: false);
  final plan = planPlayback(streams, isVideo: isVideo);
  if (plan == PlaybackPlan.asIs) {
    return (file: recording, pictureUnavailable: false);
  }
  final keepPicture = plan == PlaybackPlan.convertSound;
  final copy = keepPicture ? pictureCopy : soundCopy;
  onConverting?.call();
  copy.parent.createSync(recursive: true);
  final partial = File(
    '${copy.parent.path}/.partial-${copy.uri.pathSegments.last}',
  );
  try {
    await media.convertForPlayback(
      recording,
      partial,
      keepPicture: keepPicture,
    );
    partial.renameSync(copy.path);
  } finally {
    if (partial.existsSync()) partial.deleteSync();
  }
  return (file: copy, pictureUnavailable: isVideo && !keepPicture);
}
