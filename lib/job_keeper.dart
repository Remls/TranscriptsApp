import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'job.dart';
import 'session.dart';

/// The system service that keeps the app working while it is not on screen.
abstract class BackgroundKeeper {
  /// Starts or updates the ongoing notification with [text].
  Future<void> keepAlive(String text);

  /// Ends the ongoing notification.
  Future<void> release();

  /// Posts a one-off notification that a job has ended.
  Future<void> announce(String title, String text);
}

class AndroidBackgroundKeeper implements BackgroundKeeper {
  const AndroidBackgroundKeeper();

  static const _channel = MethodChannel('transcripts/jobs');

  @override
  Future<void> keepAlive(String text) =>
      _channel.invokeMethod('keepAlive', {'text': text});

  @override
  Future<void> release() => _channel.invokeMethod('release');

  @override
  Future<void> announce(String title, String text) =>
      _channel.invokeMethod('announce', {'title': title, 'text': text});
}

const _labels = {
  JobKind.transcribe: 'Transcription',
  JobKind.translate: 'Translation',
  JobKind.summary: 'Summary',
  JobKind.folderFlat: 'Folder summary',
  JobKind.folderHierarchical: 'Folder summary',
  JobKind.rechunk: 'Split',
  JobKind.combine: 'Combine',
};

/// Holds the background service for as long as any job runs, mirrors the
/// job's status into its notification, and announces jobs that end while the
/// app is not on screen.
class JobKeeper {
  JobKeeper(this._keeper, {required this._isOnScreen});

  final BackgroundKeeper _keeper;
  final bool Function() _isOnScreen;
  final _running = <Job, (JobKind, String)>{};
  String? _shown;

  void attach(Session session) {
    session.onJobStarted = _started;
    session.onJobFinished = _finished;
  }

  @visibleForTesting
  void debugStarted(JobKind kind, String target, Job job) =>
      _started(kind, target, job);

  @visibleForTesting
  void debugFinished(JobKind kind, String target, Job job) =>
      _finished(kind, target, job);

  String get _text {
    if (_running.length > 1) return '${_running.length} jobs running';
    final MapEntry(key: job, value: (kind, _)) = _running.entries.single;
    return job.status.isEmpty
        ? _labels[kind]!
        : '${_labels[kind]}: ${job.status}';
  }

  void _refresh() {
    if (_running.isEmpty) return;
    final text = _text;
    if (text == _shown) return;
    _shown = text;
    _keeper.keepAlive(text);
  }

  void _started(JobKind kind, String target, Job job) {
    _running[job] = (kind, target);
    job.addListener(_refresh);
    _refresh();
  }

  void _finished(JobKind kind, String target, Job job) {
    job.removeListener(_refresh);
    _running.remove(job);
    if (_running.isEmpty) {
      _shown = null;
      _keeper.release();
    } else {
      _refresh();
    }
    if (_isOnScreen() || job.state == JobState.cancelled) return;
    final name = p.basenameWithoutExtension(target);
    _keeper.announce(
      job.state == JobState.done
          ? '${_labels[kind]} finished'
          : '${_labels[kind]} failed',
      job.state == JobState.done ? name : '$name: ${job.error}',
    );
  }
}
