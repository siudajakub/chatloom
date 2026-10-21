// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline stand-in for the SDK database writes of optimistic media sends.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:matrix/matrix.dart';

/// Records echo writes and stored files instead of the SDK database.
class FakeEchoes implements OutgoingEchoWriter {
  final log = <String>[];
  final events = <String, MatrixEvent>{};
  final files = <Uri, Uint8List>{};
  Object? failWrites;

  /// Fails the echo write number [failWriteNumber] (1-based), once.
  int? failWriteNumber;
  int _writes = 0;

  /// Holds echo writes (a slow database) until completed.
  Completer<void>? writeGate;

  @override
  Future<void> write(Room room, MatrixEvent event) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (failWrites != null) throw failWrites!;
    if (++_writes == failWriteNumber) {
      throw StateError('Fictional storage failure');
    }
    final status = event.unsigned?[messageSendingStatusKey];
    log.add('echo:${event.eventId}:$status');
    events[event.eventId] = event;
  }

  @override
  Future<Event?> read(Room room, String transactionId) async {
    final event = events[transactionId];
    return event == null ? null : Event.fromMatrixEvent(event, room);
  }

  @override
  Future<void> storeFile(Room room, Uri key, Uint8List bytes) async {
    log.add('file:$key');
    files[key] = bytes;
  }

  @override
  Future<Uint8List?> getFile(Room room, Uri key) async => files[key];

  int? statusOf(String id) =>
      events[id]?.unsigned?[messageSendingStatusKey] as int?;
}
