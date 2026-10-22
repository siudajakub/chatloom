// SPDX-License-Identifier: AGPL-3.0-or-later
// Room state of rooms the worker never opened (CB-02, CB-03) and the
// worker's sync filter (CB-11). A real SDK client and database; state
// arrives through `handleSync`, as in production (never `setState`), and
// the homeserver is a local fake.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/matrix_sources.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/runtime.dart';
import 'package:personal_worker/src/session_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

const _owner = '@self:example.invalid';
const _room = '!portal:example.invalid';
const _bot = '@whatsappbot:example.invalid';
const _ownGhost = '@whatsapp_4800:example.invalid';
const _contact = '@whatsapp_4900:example.invalid';
final _t0 = DateTime.utc(2026, 10, 21, 12);
var _databases = 0;

MatrixEvent _state(
  String type,
  Map<String, Object?> content, {
  String stateKey = '',
  String sender = _bot,
}) => MatrixEvent(
  type: type,
  content: content,
  senderId: sender,
  stateKey: stateKey,
  eventId: '\$state-$type-$stateKey',
  originServerTs: _t0,
);

MatrixEvent _voice(String id, String sender) => MatrixEvent(
  type: EventTypes.Message,
  content: {
    'msgtype': 'm.audio',
    'body': 'Voice message',
    'org.matrix.msc3245.voice': <String, Object?>{},
    'info': {'mimetype': 'audio/ogg', 'duration': 4000, 'size': 2048},
    'url': 'mxc://example.invalid/synthetic',
  },
  senderId: sender,
  eventId: id,
  originServerTs: _t0,
);

Future<MatrixSdkDatabase> _database() async {
  sqfliteFfiInit();
  return MatrixSdkDatabase.init(
    'worker-room-state-${_databases++}',
    database: await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    ),
    sqfliteFactory: databaseFactoryFfi,
  );
}

void main() {
  late Client client;
  Client? opened;
  late List<http.Request> requests;
  late Map<String, http.Response Function(http.Request)> routes;

  /// [important]: the client's important state types (null = the SDK
  /// defaults only, as before wave 5).
  Future<void> open({Set<String>? important}) async {
    requests = [];
    routes = {};
    final database = await _database();
    opened = client = Client(
      'worker room state fixture',
      database: database,
      importantStateEvents: important,
      httpClient: MockClient((request) async {
        requests.add(request);
        for (final entry in routes.entries) {
          if (request.url.path.contains(entry.key)) {
            return entry.value(request);
          }
        }
        return http.Response(
          jsonEncode({'errcode': 'M_UNRECOGNIZED', 'error': 'synthetic'}),
          404,
        );
      }),
    );
    client
      ..homeserver = Uri.parse('https://example.invalid')
      ..accessToken = 'synthetic'
      ..setUserId(_owner);
  }

  tearDown(() async {
    await opened?.dispose();
    opened = null;
  });

  Future<void> sync(List<MatrixEvent> state, List<MatrixEvent> timeline) =>
      client.handleSync(
        SyncUpdate(
          nextBatch: 'batch-${state.length}-${timeline.length}',
          rooms: RoomsUpdate(
            join: {
              _room: JoinedRoomUpdate(
                state: state,
                timeline: TimelineUpdate(events: timeline),
              ),
            },
          ),
        ),
      );

  List<MatrixEvent> bridgeState() => [
    _state(
      'm.room.member',
      {'membership': 'join'},
      stateKey: _owner,
      sender: _owner,
    ),
    _state('m.room.member', {'membership': 'join'}, stateKey: _bot),
    _state('m.bridge', {
      'bridgebot': _bot,
      'protocol': {'id': 'whatsapp'},
      'channel': {'id': 'synthetic-chat', 'fi.mau.receiver': '4800'},
    }, stateKey: 'whatsapp'),
  ];

  group('disappearing chats (CB-02)', () {
    const path = '/state/com.beeper.disappearing_timer';

    test('a setting stored before it was kept in memory still refuses the '
        'transcription', () async {
      await open();
      await sync(
        [
          ...bridgeState(),
          _state(beeperDisappearingTimerKey, {
            'type': 'after_read',
            'timer': 60000,
          }),
        ],
        [_voice(r'$voice', _contact)],
      );
      final room = client.getRoomById(_room)!;
      expect(room.partial, isTrue);
      // The gap: the guard used to read this as "off".
      expect(room.getState(beeperDisappearingTimerKey), isNull);
      final transport = MatrixFeatureTransport(client);
      await expectLater(
        transport.loadAudio(
          SourceEventRef(
            conversation: const ConversationRef(
              accountId: _owner,
              roomId: _room,
            ),
            eventId: r'$voice',
          ),
          Cancellation(),
        ),
        throwsA(
          isA<WorkerFailure>().having((e) => e.code, 'code', 'protected_media'),
        ),
      );
    });

    test(
      'the server decides when memory has nothing; errors fail closed',
      () async {
        await open(important: workerImportantStateEvents);
        await sync(bridgeState(), [_voice(r'$voice', _contact)]);
        final room = client.getRoomById(_room)!;
        var now = _t0;
        final lookup = DisappearingTimerLookup(client, clock: () => now);
        routes[path] = (_) => http.Response(
          jsonEncode({'type': 'after_send', 'timer': 3600000}),
          200,
        );
        expect(await lookup.limits(room), isTrue);
        // Cached: no second request within the TTL.
        final asked = requests.length;
        expect(await lookup.limits(room), isTrue);
        expect(requests.length, asked);
        // Never set: off.
        now = now.add(DisappearingTimerLookup.ttl);
        routes[path] = (_) => http.Response(
          jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'synthetic'}),
          404,
        );
        expect(await lookup.limits(room), isFalse);
        // Unknown: never treated as off.
        now = now.add(DisappearingTimerLookup.ttl);
        routes[path] = (_) => http.Response('synthetic outage', 502);
        await expectLater(
          lookup.limits(room),
          throwsA(
            isA<WorkerFailure>().having(
              (e) => e.code,
              'code',
              'source_policy_unknown',
            ),
          ),
        );
        routes[path] = (_) => http.Response(
          jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'synthetic'}),
          403,
        );
        await expectLater(lookup.limits(room), throwsA(isA<WorkerFailure>()));
      },
    );

    test('a setting arriving by sync now stays in memory', () async {
      await open(important: workerImportantStateEvents);
      await sync([
        _state(beeperDisappearingTimerKey, {'type': 'after_read', 'timer': 1}),
      ], []);
      final room = client.getRoomById(_room)!;
      expect(room.partial, isTrue);
      expect(room.getState(beeperDisappearingTimerKey), isNotNull);
      // Active in memory: refused without asking the server.
      expect(await DisappearingTimerLookup(client).limits(room), isTrue);
      expect(requests.where((r) => r.url.path.contains('/state/')), isEmpty);
    });
  });

  group('bridge info in the live feed (CB-03)', () {
    test('network and own ghost are known for rooms never opened', () async {
      // State stored by a worker that predates wave 5 (not important then);
      // this worker version keeps them in memory from now on.
      await open();
      final feed = MatrixLiveSources(
        client,
        journalRoomId: '!journal:example.invalid',
        clock: () => _t0,
      )..start();
      await sync(bridgeState(), [
        _voice(r'$mine', _ownGhost),
        _voice(r'$theirs', _contact),
      ]);
      client.importantStateEvents.addAll(workerImportantStateEvents);
      final room = client.getRoomById(_room)!;
      expect(room.partial, isTrue);
      expect(room.states['m.bridge'], isNull, reason: 'the gap');
      final items = await feed.drain();
      expect(items.map((item) => item.eventId), [r'$mine', r'$theirs']);
      expect(items.map((item) => item.network), ['whatsapp', 'whatsapp']);
      // Sent from the native app as the owner's ghost: the own-message rules
      // of the policy decide, not the incoming ones.
      expect(items.map((item) => item.outgoing), [true, false]);
      await feed.close();
    });
  });

  group('sync filter (CB-11)', () {
    test('typing, receipts and presence are not synced', () {
      final json = workerSyncFilter().toJson();
      expect(json['presence'], {
        'not_types': ['*'],
      });
      final room = json['room'] as Map;
      expect(room['ephemeral'], {
        'not_types': ['*'],
      });
      expect((room['state'] as Map)['lazy_load_members'], isTrue);
      expect(room.containsKey('timeline'), isFalse, reason: 'unchanged');
    });

    test('a changed filter is defined again and used at once', () async {
      final bodies = <Object?>[];
      final session = WorkerSessionClient(
        'worker filter fixture',
        database: await _database(),
        syncFilter: workerSyncFilter(),
        sessionHttpClient: MockClient((request) async {
          if (!request.url.path.endsWith('/filter')) {
            return http.Response('{}', 404);
          }
          bodies.add(jsonDecode(request.body));
          return http.Response(jsonEncode({'filter_id': 'worker-2'}), 200);
        }),
      );
      opened = session;
      session
        ..homeserver = Uri.parse('https://example.invalid')
        ..accessToken = 'synthetic'
        ..setUserId(_owner);
      expect(session.syncFilterId, isNull);
      await session.redefineSyncFilter();
      expect(session.syncFilterId, 'worker-2');
      expect(bodies.single, workerSyncFilter().toJson());
    });
  });
}
