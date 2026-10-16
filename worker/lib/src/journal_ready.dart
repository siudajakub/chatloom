import 'dart:async';
import 'package:matrix/matrix.dart';
import 'ports.dart';

/// A room can arrive in sync before createRoom's response reaches the caller.
/// Check the processed cache rather than waiting for a second join event.
Future<Room> waitForJoinedJournal(
  Client client,
  String id, {
  Duration timeout = const Duration(seconds: 60),
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final until = DateTime.now().add(timeout);
  while (true) {
    final room = client.getRoomById(id);
    if (room?.membership == Membership.join) return room!;
    if (!DateTime.now().isBefore(until)) {
      throw const WorkerFailure('journal_join_sync_timeout');
    }
    await Future<void>.delayed(interval);
  }
}
