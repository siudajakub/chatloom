// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_worker/src/journal_session_rotation.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:test/test.dart';

/// Mirrors the SDK: a discarded session is replaced by a fresh one, created
/// at the moment of the next encrypted send.
class FakeOutboundSession implements OutboundSessionPort {
  FakeOutboundSession(this.created);

  DateTime? created;
  int reads = 0;
  int discards = 0;
  bool failReads = false;
  bool failDiscard = false;

  @override
  Future<DateTime?> createdAt() async {
    reads++;
    if (failReads) throw StateError('database');
    return created;
  }

  @override
  Future<void> discard() async {
    if (failDiscard) throw StateError('database');
    discards++;
    created = null;
  }

  void send(DateTime at) => created ??= at;
}

void main() {
  final start = DateTime.utc(2026, 10, 17, 12);

  test('rotates once at start, then only when older than 24 h', () async {
    var now = start;
    final session = FakeOutboundSession(
      start.subtract(const Duration(days: 2)),
    );
    final rotation = JournalSessionRotation(session, clock: () => now);

    expect(await rotation.rotateIfDue(), JournalRotationReason.startup);
    expect(session.discards, 1);
    session.send(now);

    // The daemon loop runs every two seconds: a day of cycles rotates once
    // more, when the fresh session turns 24 h old.
    final reasons = <JournalRotationReason>[];
    for (var s = 2; s <= const Duration(hours: 25).inSeconds; s += 2) {
      now = start.add(Duration(seconds: s));
      final reason = await rotation.rotateIfDue();
      if (reason != null) reasons.add(reason);
      session.send(now);
    }
    expect(reasons, [JournalRotationReason.maxAge]);
    expect(session.discards, 2);
    // In-memory checks are throttled to one per minute.
    expect(session.reads, lessThanOrEqualTo(1 + 25 * 60 + 1));
  });

  test('a fresh session at start is still rotated once', () async {
    final session = FakeOutboundSession(start);
    final rotation = JournalSessionRotation(session, clock: () => start);
    expect(await rotation.rotateIfDue(), JournalRotationReason.startup);
    session.send(start);
    expect(await rotation.rotateIfDue(), isNull);
    expect(session.discards, 1);
  });

  test('no session yet: nothing to discard, next send creates one', () async {
    var now = start;
    final session = FakeOutboundSession(null);
    final rotation = JournalSessionRotation(session, clock: () => now);
    expect(await rotation.rotateIfDue(), isNull);
    expect(session.discards, 0);
    session.send(now);
    now = now.add(const Duration(hours: 1));
    expect(await rotation.rotateIfDue(), isNull);
    expect(session.discards, 0);
  });

  test('a clock stepping backwards does not pin an old session', () async {
    var now = start;
    final session = FakeOutboundSession(null);
    final rotation = JournalSessionRotation(session, clock: () => now);
    await rotation.rotateIfDue();
    session.send(now);
    now = start.subtract(const Duration(hours: 3));
    expect(await rotation.rotateIfDue(), JournalRotationReason.maxAge);
  });

  test('failure defers publication and retries the startup rotation', () async {
    var now = start;
    final session = FakeOutboundSession(start)..failDiscard = true;
    final rotation = JournalSessionRotation(session, clock: () => now);
    await expectLater(
      rotation.rotateIfDue(),
      throwsA(
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'journal_session_rotation_deferred',
        ),
      ),
    );
    session.failDiscard = false;
    now = now.add(const Duration(seconds: 2));
    expect(await rotation.rotateIfDue(), JournalRotationReason.startup);

    session
      ..send(now)
      ..failReads = true;
    now = now.add(const Duration(minutes: 2));
    await expectLater(rotation.rotateIfDue(), throwsA(isA<WorkerFailure>()));
  });
}
