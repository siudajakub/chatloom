// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:test/test.dart';

const owner = '@fixture:example.invalid';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No database allowed');
}

class _Client extends Client {
  _Client() : super('dictation fixture', database: _Database());
  @override
  String? get userID => owner;
  @override
  bool get encryptionEnabled => true;
  @override
  Future<MatrixEvent> getOneRoomEvent(String roomId, String eventId) async =>
      MatrixEvent(
        type: EventTypes.Message,
        content: const {},
        senderId: owner,
        eventId: eventId,
        originServerTs: DateTime.utc(2026, 11, 5, 12),
      );
}

class _Room extends Room {
  _Room(Client client) : super(id: '!private:example.invalid', client: client);
  bool encryptedValue = true;
  bool marker = true;
  List<String> members = [owner];
  @override
  bool get encrypted => encryptedValue;
  @override
  Membership get membership => Membership.join;
  @override
  Future<List<User>> requestParticipants([
    List<Membership> memberships = const [Membership.join, Membership.invite],
    bool suppressWarning = false,
    bool? cache,
    bool enforceFetchFromServer = false,
  ]) async => [
    for (final id in members) User(id, room: this, membership: 'join'),
  ];
  @override
  StrippedStateEvent? getState(String type, [String stateKey = '']) =>
      type == personalRoomMarker && marker
      ? StrippedStateEvent(
          type: type,
          senderId: owner,
          content: {'schema': personalSchemaVersion},
          stateKey: '',
        )
      : null;
}

void main() {
  final now = DateTime.utc(2026, 11, 5, 12);
  late _Client client;
  late _Room room;
  setUp(() {
    client = _Client();
    room = _Room(client);
    client.rooms.add(room);
  });
  Event audio({
    Map<String, dynamic>? patch,
    String sender = owner,
    String type = EventTypes.Message,
    DateTime? timestamp,
  }) => Event(
    type: type,
    room: room,
    eventId: r'$audio',
    senderId: sender,
    originServerTs: timestamp ?? now,
    content: {
      'msgtype': MessageTypes.Audio,
      DictationLimits.sourceMarker: 'dictation-fixture',
      'file': {'url': 'mxc://example.invalid/audio'},
      'info': {'size': 3, 'duration': 12000, 'mimetype': 'audio/ogg'},
      ...?patch,
    },
  );
  String? rejection(Event event) => MatrixDictationSource.sourceRejection(
    event,
    owner: owner,
    dictationId: 'dictation-fixture',
    now: now,
  );
  test('only owned marked encrypted attachment metadata accepted', () {
    expect(rejection(audio()), isNull);
    for (final event in [
      audio(sender: '@other:example.invalid'),
      audio(patch: {DictationLimits.sourceMarker: 'dictation-other'}),
      audio(patch: {'msgtype': MessageTypes.Video}),
      audio(patch: {'file': null}),
      audio(
        patch: {
          'info': {'size': DictationLimits.maxBytes + 1, 'duration': 12},
        },
      ),
      audio(
        patch: {
          'info': {'size': 3, 'duration': 300001},
        },
      ),
      audio(
        patch: {
          'info': {'duration': 12},
        },
      ),
    ]) {
      expect(rejection(event), 'invalid_dictation_source');
    }
  });
  test('view-limited and disappearing source metadata never transcribes', () {
    for (final patch in <Map<String, dynamic>>[
      {'view_once': true}, {'ttl_seconds': 60},
      {beeperDisappearingTimerKey: {'type': 'after_read', 'timer': 60000}},
      {'com.beeper.view_limited': {'count': 1}},
    ]) { expect(rejection(audio(patch: patch)), 'protected_media'); }
  });

  test('expired future and undecryptable sources refuse before download', () {
    expect(
      rejection(audio(timestamp: now.subtract(const Duration(minutes: 16)))),
      'dictation_source_timeout',
    );
    expect(
      rejection(audio(timestamp: now.add(const Duration(minutes: 2)))),
      'dictation_source_timeout',
    );
    expect(rejection(audio(type: EventTypes.Encrypted)), 'waiting_keys');
  });
  test(
    'plaintext source event is rejected even inside encrypted journal',
    () async {
      final source = MatrixDictationSource(client, room.id);
      await expectLater(
        source.loadDictation(r'$audio', 'dictation-fixture', Cancellation()),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'dictation_source_unencrypted',
          ),
        ),
      );
    },
  );

  test('self journal membership is checked before source fetching', () async {
    final source = MatrixDictationSource(client, room.id);
    room.members = [owner, '@intruder:example.invalid'];
    await expectLater(
      source.loadDictation(r'$audio', 'dictation-fixture', Cancellation()),
      throwsA(
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'journal_membership_changed',
        ),
      ),
    );
    room.members = [];
    await expectLater(
      source.loadDictation(r'$audio', 'dictation-fixture', Cancellation()),
      throwsA(
        isA<WorkerFailure>().having(
          (e) => e.code,
          'code',
          'journal_membership_changed',
        ),
      ),
    );
  });
  test(
    'unencrypted unmarked and absent journals refuse before source fetching',
    () async {
      final source = MatrixDictationSource(client, room.id);
      room.encryptedValue = false;
      await expectLater(
        source.loadDictation(r'$audio', 'dictation-fixture', Cancellation()),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'journal_unavailable',
          ),
        ),
      );
      room.encryptedValue = true;
      room.marker = false;
      await expectLater(
        source.loadDictation(r'$audio', 'dictation-fixture', Cancellation()),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'journal_unavailable',
          ),
        ),
      );
      client.rooms.clear();
      await expectLater(
        source.loadDictation(r'$audio', 'dictation-fixture', Cancellation()),
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.code,
            'code',
            'journal_unavailable',
          ),
        ),
      );
    },
  );
}
