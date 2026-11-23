import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

enum JobState { running, done, failed, cancelled }

/// A failure whose message is shown to the user as is.
class JobFailure implements Exception {
  const JobFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A cancellable unit of API work with a status line and streamed output.
abstract class Job extends ChangeNotifier {
  Job({http.Client Function()? clientFactory})
    : clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() clientFactory;

  JobState state = JobState.running;
  String status = '';
  String? error;

  /// The model text streamed so far in the current phase.
  final output = StringBuffer();

  /// Stops work that is not an HTTP request when the job is cancelled.
  void Function()? onCancel;

  final _clients = <http.Client>[];
  bool _cancelled = false;

  /// A client that [cancel] closes, aborting its requests.
  http.Client openClient() {
    if (_cancelled) throw const JobFailure('cancelled');
    final client = clientFactory();
    _clients.add(client);
    return client;
  }

  void cancel() {
    if (state != JobState.running) return;
    _cancelled = true;
    for (final client in _clients) {
      client.close();
    }
    onCancel?.call();
  }

  void setStatus(String value) {
    status = value;
    notifyListeners();
  }

  void resetOutput() {
    output.clear();
    notifyListeners();
  }

  void appendOutput(String chunk) {
    output.write(chunk);
    notifyListeners();
  }

  Future<void> run() async {
    try {
      await perform();
      _finish(JobState.done);
    } catch (e) {
      if (_cancelled) {
        _finish(JobState.cancelled);
      } else {
        _finish(
          JobState.failed,
          e is http.ClientException
              ? 'Network error. Check the internet connection.'
              : '$e',
        );
      }
    } finally {
      for (final client in _clients) {
        client.close();
      }
    }
  }

  @protected
  Future<void> perform();

  void _finish(JobState result, [String? message]) {
    state = result;
    error = message;
    status = switch (result) {
      JobState.done => 'Done',
      JobState.cancelled => 'Cancelled',
      _ => message ?? '',
    };
    notifyListeners();
  }
}
