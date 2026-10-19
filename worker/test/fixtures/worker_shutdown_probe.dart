// Synthetic child process: no native crypto, account, credentials or provider.
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/local_sources.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/reminder_relay.dart';
import 'package:personal_worker/src/session_client.dart';

class FixtureDatabase implements DatabaseApi {
  bool closed = false;
  @override
  Future<void> close() async => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected database access');
}

class FixtureMatrix implements FeatureTransport {
  @override
  String get accountId => '@fixture:example.invalid';
  @override
  String get deviceId => 'fixture';
  @override
  bool get verified => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected Matrix access');
}

Future<void> main(List<String> arguments) async {
  final database = FixtureDatabase();
  final session = WorkerSessionClient(
    'shutdown fixture',
    database: database,
    sessionHttpClient: http.Client(),
  );
  final local = LocalSourceTransport(FixtureMatrix(), arguments[1]);
  final relay = HttpReminderWakeHintSink(
    url: Uri.parse('${arguments[0]}/internal/reminder'),
    token: 'fixture',
  );
  const source = SourceEventRef(
    conversation: ConversationRef(
      accountId: '@fixture:example.invalid',
      roomId: '!fixture:beeper.local',
    ),
    eventId: r'$fixture',
  );
  final stopped = Completer<void>();
  final subscription = ProcessSignal.sigterm.watch().listen((_) {
    session.stopNetwork();
    local.close();
    relay.close();
    if (database.closed) throw StateError('database closed before cycle ended');
    if (!stopped.isCompleted) stopped.complete();
  });
  Future<bool> interrupted(Future<dynamic> request) async {
    try {
      await request;
      return false;
    } catch (_) {
      return !database.closed;
    }
  }

  final pending = [
    interrupted(session.httpClient.get(Uri.parse('${arguments[0]}/sync'))),
    interrupted(local.request(source, 'metadata', Cancellation())),
    interrupted(
      relay.publish(
        ReminderWakeHint(hintId: 'a' * 64, emittedAt: DateTime.utc(2026)),
      ),
    ),
  ];
  await stopped.future;
  final results = await Future.wait(pending);
  // Mirrors the daemon ordering: wait for operations, then dispose storage.
  await session.dispose();
  await subscription.cancel();
  if (!results.every((result) => result) || !database.closed) {
    throw StateError('incomplete shutdown');
  }
  stdout.writeln('shutdown-clean');
}
