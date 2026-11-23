import 'package:flutter_test/flutter_test.dart';
import 'package:transcripts/job.dart';
import 'package:transcripts/job_keeper.dart';
import 'package:transcripts/session.dart';

class _FakeKeeper implements BackgroundKeeper {
  final calls = <String>[];

  @override
  Future<void> keepAlive(String text) async => calls.add('keep: $text');

  @override
  Future<void> release() async => calls.add('release');

  @override
  Future<void> announce(String title, String text) async =>
      calls.add('announce: $title | $text');
}

class _FakeJob extends Job {
  @override
  Future<void> perform() async {}

  void end(JobState result, [String? message]) {
    state = result;
    error = message;
  }
}

void main() {
  late _FakeKeeper keeper;
  late bool onScreen;
  late JobKeeper jobs;

  void start(JobKind kind, String target, Job job) =>
      jobs.debugStarted(kind, target, job);
  void finish(JobKind kind, String target, Job job) =>
      jobs.debugFinished(kind, target, job);

  setUp(() {
    keeper = _FakeKeeper();
    onScreen = true;
    jobs = JobKeeper(keeper, isOnScreen: () => onScreen);
  });

  test('holds the service while a job runs and mirrors its status', () {
    final job = _FakeJob();
    start(JobKind.transcribe, 'set/talk.mp3', job);
    job.setStatus('Uploading 4.0 MB');
    job.setStatus('Uploading 4.0 MB');
    job.appendOutput('text');
    job.setStatus('Transcribing');
    job.end(JobState.done);
    finish(JobKind.transcribe, 'set/talk.mp3', job);

    expect(keeper.calls, [
      'keep: Transcription',
      'keep: Transcription: Uploading 4.0 MB',
      'keep: Transcription: Transcribing',
      'release',
    ]);
  });

  test('stays held until the last of several jobs ends', () {
    final a = _FakeJob();
    final b = _FakeJob();
    start(JobKind.translate, 'a.mp3', a);
    start(JobKind.summary, 'b.mp3', b);
    a.end(JobState.done);
    finish(JobKind.translate, 'a.mp3', a);
    b.setStatus('Summarizing');
    b.end(JobState.done);
    finish(JobKind.summary, 'b.mp3', b);

    expect(keeper.calls, [
      'keep: Translation',
      'keep: 2 jobs running',
      'keep: Summary',
      'keep: Summary: Summarizing',
      'release',
    ]);
  });

  test('announces results only while the app is off screen', () {
    final seen = _FakeJob()..end(JobState.done);
    start(JobKind.summary, 'a.mp3', seen);
    finish(JobKind.summary, 'a.mp3', seen);
    expect(keeper.calls.where((c) => c.startsWith('announce')), isEmpty);

    onScreen = false;
    final done = _FakeJob();
    start(JobKind.transcribe, 'set/talk.mp3', done);
    done.end(JobState.done);
    finish(JobKind.transcribe, 'set/talk.mp3', done);
    final failed = _FakeJob();
    start(JobKind.combine, '/library/set', failed);
    failed.end(JobState.failed, 'boom');
    finish(JobKind.combine, '/library/set', failed);
    final cancelled = _FakeJob();
    start(JobKind.rechunk, 'x.mp3', cancelled);
    cancelled.end(JobState.cancelled);
    finish(JobKind.rechunk, 'x.mp3', cancelled);

    expect(keeper.calls.where((c) => c.startsWith('announce')), [
      'announce: Transcription finished | talk',
      'announce: Combine failed | set: boom',
    ]);
  });
}
