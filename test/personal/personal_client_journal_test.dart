// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math';

import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:personal_core/personal_core.dart';

const _user = '@synthetic:example.org';
const _workerKey = 'synthetic-worker-key';
const _watermarkKey = 'account:$_user:${JournalWatermark.storageKey}';
final _t0 = DateTime.utc(2026, 10, 17, 8);

class _Client implements Client {
  @override
  String? userID = _user;
  @override
  Future<void> get accountDataLoading => Future<void>.value();
  @override
  final Map<String, BasicEvent> accountData = {};
  @override
  final List<Room> rooms = [];
  @override
  final Map<String, DeviceKeysList> userDeviceKeys = {_user: _Keys()};
  @override
  final onSync = CachedStreamController<SyncUpdate>();
  @override
  final onTimelineEvent = CachedStreamController<Event>();
  @override
  bool get encryptionEnabled => false;
  @override
  Future<dynamic>? userDeviceKeysLoading = Future<void>.value();
  @override
  final Encryption encryption = _Encryption();

  void verify(String key) {
    userDeviceKeys[_user]!.deviceKeys[key] = _Device(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Keys implements DeviceKeysList {
  @override
  Map<String, DeviceKeys> deviceKeys = {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Device implements DeviceKeys {
  _Device(this.curve25519Key);
  @override
  final String? curve25519Key;
  @override
  String? get ed25519Key => 'ed:$curve25519Key';
  @override
  bool get verified => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One direct (Olm-delivered) megolm session per sending device; events are
/// recorded in its replay index as the SDK does on decryption.
final _sessions = <String, _Session>{};

/// Plaintexts of undecrypted events whose session becomes available.
final _plaintexts = <String, Event>{};

String _sessionOf(String senderKey) => 'session:$senderKey';

class _Session implements SessionKey {
  _Session(this.senderKey) : sessionId = _sessionOf(senderKey);
  @override
  final String sessionId;
  @override
  final String senderKey;
  @override
  String get roomId => '!synthetic-journal:example.org';
  @override
  Map<String, String> get senderClaimedKeys => {'ed25519': 'ed:$senderKey'};
  @override
  List<String> get forwardingCurve25519KeyChain => const [];
  @override
  Map<String, dynamic> get content => {
    'algorithm': 'm.megolm.v1.aes-sha2',
    'session_id': sessionId,
    'session_key': 'synthetic',
  };
  @override
  final Map<String, String> indexes = {};
  @override
  bool get isValid => true;
  void record(Event event) => indexes['key-${indexes.length}'] =
      '${event.eventId}|${event.originServerTs.millisecondsSinceEpoch}';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_Session _sessionFor(String senderKey) =>
    _sessions.putIfAbsent(_sessionOf(senderKey), () => _Session(senderKey));

class _KeyManager implements KeyManager {
  @override
  Future<SessionKey?> loadInboundGroupSession(
    String roomId,
    String sessionId,
  ) async => _sessions[sessionId];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Encryption implements Encryption {
  @override
  final KeyManager keyManager = _KeyManager();
  @override
  Future<Event> decryptRoomEvent(
    Event event, {
    bool store = false,
    EventUpdateType updateType = EventUpdateType.timeline,
  }) async {
    final plain = _plaintexts[event.eventId];
    if (plain == null || !_sessions.containsKey(event.content['session_id'])) {
      return event;
    }
    _sessions[event.content['session_id']]!.record(plain);
    return plain;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  final reads = <String>[];
  void Function(String key)? onPut;
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<Map<String, dynamic>?> get(String key) async {
    reads.add(key);
    return records[key];
  }

  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    records[key] = value;
    onPut?.call(key);
  }

  @override
  Future<void> delete(String key) async {
    records.remove(key);
  }

  @override
  Future<void> close() async {}

  int seenReads() =>
      reads.where((key) => key.startsWith('account:$_user:seen:')).length;
  JournalWatermark? get watermark =>
      JournalWatermark.tryParse(records[_watermarkKey]);
}

/// Server history (oldest first) seen through a timeline that loads the
/// newest [initial] events and pages older ones on request, like the SDK.
class _PagedTimeline implements Timeline {
  _PagedTimeline(this.history, {required int initial, this.onUpdate}) {
    events.addAll(history.reversed.take(initial));
  }

  final List<Event> history;
  @override
  final void Function()? onUpdate;
  @override
  final List<Event> events = [];
  int requests = 0;
  bool cancelled = false;

  int get _oldest => events.isEmpty
      ? history.length
      : history.indexWhere((event) => event.eventId == events.last.eventId);

  @override
  bool get canRequestHistory => _oldest > 0;

  @override
  Future<void> requestHistory({
    int historyCount = Room.defaultHistoryCount,
    StateFilter? filter,
  }) async {
    requests++;
    onUpdate?.call();
    final end = _oldest;
    events.addAll(history.sublist(max(0, end - historyCount), end).reversed);
    onUpdate?.call();
  }

  void deliver(Event event) {
    history.add(event);
    events.insert(0, event);
    onUpdate?.call();
  }

  /// A limited sync: the gap reaches the server, the live timeline only
  /// keeps the events of this sync.
  void limitedSync(List<Event> gap, List<Event> fresh) {
    history
      ..addAll(gap)
      ..addAll(fresh);
    events
      ..clear()
      ..addAll(fresh.reversed);
    onUpdate?.call();
  }

  @override
  void cancelSubscriptions() => cancelled = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Journal implements Room {
  @override
  String get id => '!synthetic-journal:example.org';
  final history = <Event>[];
  final timelines = <_PagedTimeline>[];
  final eventReads = <String>[];
  int participantReads = 0;
  final keys = CachedStreamController<String>();

  _PagedTimeline get timeline => timelines.last;

  @override
  bool get encrypted => true;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #getState:
        return StrippedStateEvent(
          type: personalRoomMarker,
          senderId: _user,
          content: {'schema': personalSchemaVersion},
        );
      case #requestParticipants:
        participantReads++;
        return Future<List<User>>.value([]);
      case #getParticipants:
        return <User>[];
      case #setPushRuleState:
        return Future<void>.value();
      case #onSessionKeyReceived:
        return keys;
      case #getTimeline:
        final timeline = _PagedTimeline(
          history,
          initial: 30,
          onUpdate: invocation.namedArguments[#onUpdate] as void Function()?,
        );
        timelines.add(timeline);
        return Future<Timeline>.value(timeline);
      case #getEventById:
        final id = invocation.positionalArguments.first as String;
        eventReads.add(id);
        return Future<Event?>.value(
          history.where((event) => event.eventId == id).firstOrNull,
        );
      case #sendEvent:
        return Future<String?>.value(r'$synthetic-sent');
    }
    return super.noSuchMethod(invocation);
  }
}

DateTime _min(num minutes) =>
    _t0.add(Duration(milliseconds: (minutes * 60000).round()));

Event _create(_Journal room) => Event(
  room: room,
  eventId: r'$create',
  type: EventTypes.RoomCreate,
  senderId: _user,
  stateKey: '',
  originServerTs: _t0,
  content: {},
);

Event _op(
  _Journal room,
  String id,
  DateTime at,
  String kind, {
  String entity = 'worker',
  Map<String, dynamic> payload = const {},
  String senderKey = _workerKey,
  bool decrypted = true,
  // Device whose (Olm-delivered) session really encrypted it; a forger puts
  // another device's key into the envelope.
  String? sessionOwner,
}) {
  final event = Event(
    room: room,
    eventId: '\$$id',
    type: personalEventType,
    senderId: _user,
    originServerTs: at,
    content: Map<String, dynamic>.from(
      PersonalOperation(
        opId: id,
        kind: kind,
        entityId: entity,
        createdAt: at,
        payload: payload,
      ).toJson(),
    ),
    originalSource: MatrixEvent(
      type: EventTypes.Encrypted,
      content: {
        'algorithm': 'm.megolm.v1.aes-sha2',
        'sender_key': senderKey,
        'session_id': _sessionOf(sessionOwner ?? senderKey),
        'ciphertext': 'synthetic',
      },
      senderId: _user,
      eventId: '\$$id',
      originServerTs: at,
    ),
  );
  // The SDK records each event it decrypts in its session's replay index.
  if (decrypted) _sessionFor(sessionOwner ?? senderKey).record(event);
  return event;
}

Event _heartbeat(_Journal room, String id, DateTime at) =>
    _op(room, id, at, 'worker.heartbeat', payload: {'healthy': true});

Event _metadata(
  _Journal room,
  String id,
  DateTime at,
  String entity,
  int value, {
  String senderKey = _workerKey,
  bool decrypted = true,
  String? sessionOwner,
}) => _op(
  room,
  id,
  at,
  'metadata.result',
  entity: entity,
  senderKey: senderKey,
  decrypted: decrypted,
  sessionOwner: sessionOwner,
  payload: {
    'revision': 1,
    'value': {'n': value},
  },
);

Event _undecrypted(
  _Journal room,
  String id,
  DateTime at, {
  String senderKey = _workerKey,
  String? session,
}) => Event(
  room: room,
  eventId: '\$$id',
  type: EventTypes.Encrypted,
  senderId: _user,
  originServerTs: at,
  content: {
    'algorithm': 'm.megolm.v1.aes-sha2',
    'sender_key': senderKey,
    'session_id': session ?? 'missing:$id',
    'ciphertext': 'synthetic',
    'msgtype': MessageTypes.BadEncrypted,
    'can_request_session': true,
  },
);

PersonalClient _start(_Client client, _Store store, _Journal journal) {
  final personal = PersonalClient.forTesting(
    client,
    openStore: () async => store,
  );
  personal.journal = journal;
  return personal;
}

Future<void> _idle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Client client;
  setUp(() {
    _sessions.clear();
    _plaintexts.clear();
    client = _Client()..verify(_workerKey);
  });
  tearDown(() => client.onSync.close());

  test(
    'second start pages back only to the watermark and replays newer events',
    () async {
      final store = _Store();
      final journal = _Journal();
      journal.history.add(_create(journal));
      for (var i = 1; i <= 1200; i++) {
        journal.history.add(
          i % 100 == 0
              ? _metadata(journal, 'result-$i', _min(i), 'org:$i', i)
              : _heartbeat(journal, 'hb-$i', _min(i)),
        );
      }
      final first = _start(client, store, journal);
      await first.load();
      expect(first.ready, isTrue);
      expect(first.values['org:100'], {'n': 100});
      expect(first.values['org:1200'], {'n': 1200});
      expect(
        journal.timelines.first.requests,
        greaterThan(10),
        reason: 'No watermark yet: the whole journal is replayed once',
      );
      expect(store.watermark?.eventId, r'$result-1200');
      expect(store.watermark?.held, isEmpty);
      expect(
        journal.timelines,
        hasLength(2),
        reason: 'After a full replay only the resumable tail stays in memory',
      );
      expect(journal.timelines.first.cancelled, isTrue);
      expect(journal.timelines.last.events.length, lessThan(100));
      first.dispose();

      // While the app is closed the worker keeps writing.
      for (var i = 1201; i <= 1240; i++) {
        journal.history.add(
          i == 1230
              ? _metadata(journal, 'result-$i', _min(i), 'org:$i', i)
              : _heartbeat(journal, 'hb-$i', _min(i)),
        );
      }
      store.reads.clear();
      final second = _start(client, store, journal);
      addTearDown(second.dispose);
      await second.load();
      expect(second.ready, isTrue);
      expect(second.values['org:1230'], {'n': 1230});
      expect(second.values['org:100'], {
        'n': 100,
      }, reason: 'Older state comes from the encrypted replica');
      final resumed = journal.timeline;
      expect(
        resumed.requests,
        1,
        reason: 'One page reaches the watermark and its safety margin',
      );
      expect(resumed.events.length, lessThan(200));
      expect(
        store.seenReads(),
        lessThanOrEqualTo(2),
        reason: 'Only results of the resumed window are replayed',
      );
      expect(second.workerReadiness?.receivedAt, _min(1240));
      expect(store.watermark?.eventId, r'$hb-1240');
    },
  );

  test('missing, foreign or malformed watermark replays everything', () async {
    for (final saved in <Map<String, dynamic>>[
      JournalWatermark(
        roomId: '!synthetic-journal:example.org',
        eventId: r'$vanished',
        originServerTs: _min(5),
      ).toJson(),
      JournalWatermark(
        roomId: '!another-journal:example.org',
        eventId: r'$hb-2',
        originServerTs: _min(2),
      ).toJson(),
      {'schema': 99, 'eventId': r'$hb-2'},
    ]) {
      final store = _Store()..records[_watermarkKey] = saved;
      final journal = _Journal();
      journal.history.add(_create(journal));
      for (var i = 1; i <= 300; i++) {
        journal.history.add(
          i == 3
              ? _metadata(journal, 'early', _min(i), 'org:early', 3)
              : _heartbeat(journal, 'hb-$i', _min(i)),
        );
      }
      final personal = _start(client, store, journal);
      await personal.load();
      expect(personal.ready, isTrue);
      expect(personal.values['org:early'], {'n': 3}, reason: '$saved');
      expect(journal.timeline.canRequestHistory, isFalse);
      expect(store.watermark?.eventId, r'$hb-300');
      personal.dispose();
    }
  });

  test('a limited sync gap pages back instead of skipping results', () async {
    final store = _Store();
    final journal = _Journal();
    journal.history.add(_create(journal));
    for (var i = 1; i <= 50; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final personal = _start(client, store, journal);
    addTearDown(personal.dispose);
    await personal.load();
    final timeline = journal.timeline;
    final before = timeline.requests;
    timeline.limitedSync(
      [
        for (var i = 51; i <= 80; i++)
          i == 60
              ? _metadata(journal, 'gap-result', _min(i), 'org:gap', 60)
              : _heartbeat(journal, 'hb-$i', _min(i)),
      ],
      [for (var i = 81; i <= 83; i++) _heartbeat(journal, 'hb-$i', _min(i))],
    );
    await _idle();
    expect(personal.values['org:gap'], {'n': 60});
    expect(timeline.requests, greaterThan(before));
    expect(store.watermark?.eventId, r'$hb-83');
  });

  test(
    'a result from a not yet verified own device is held, then applied',
    () async {
      final store = _Store();
      final journal = _Journal();
      journal.history.add(_create(journal));
      journal.history.add(
        _metadata(
          journal,
          'late-device',
          _min(1),
          'org:late',
          1,
          senderKey: 'synthetic-new-device',
        ),
      );
      for (var i = 2; i <= 300; i++) {
        journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
      }
      final first = _start(client, store, journal);
      await first.load();
      expect(first.values['org:late'], isNull);
      expect(store.watermark?.eventId, r'$hb-300');
      expect(store.watermark?.held, [r'$late-device']);
      first.dispose();

      client.verify('synthetic-new-device');
      final second = _start(client, store, journal);
      await second.load();
      expect(journal.timeline.requests, 0);
      expect(journal.eventReads, [
        r'$late-device',
      ], reason: 'Held events outside the window are re-read by id');
      expect(second.values['org:late'], {'n': 1});
      expect(store.watermark?.held, isEmpty);
      second.dispose();

      final third = _start(client, store, journal);
      addTearDown(third.dispose);
      await third.load();
      expect(journal.eventReads, [r'$late-device']);
    },
  );

  test('verifying the device while running applies a held result', () async {
    final store = _Store();
    final journal = _Journal();
    journal.history
      ..add(_create(journal))
      ..add(
        _metadata(
          journal,
          'late-device',
          _min(1),
          'org:late',
          1,
          senderKey: 'synthetic-new-device',
        ),
      );
    for (var i = 2; i <= 40; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final personal = _start(client, store, journal);
    addTearDown(personal.dispose);
    await personal.load();
    expect(personal.values['org:late'], isNull);
    client.verify('synthetic-new-device');
    client.onSync.add(SyncUpdate(nextBatch: 'device-verified'));
    await _idle();
    expect(personal.values['org:late'], {'n': 1});
    expect(store.watermark?.held, isEmpty);
  });

  test('an undecryptable result is applied once its keys arrive', () async {
    // A verified phone whose key share was delayed: nothing newer from it
    // proves that its key can no longer arrive directly.
    const phone = 'synthetic-phone-key';
    client.verify(phone);
    final store = _Store();
    final journal = _Journal();
    journal.history
      ..add(_create(journal))
      ..add(_undecrypted(journal, 'utd', _min(1), senderKey: phone));
    for (var i = 2; i <= 300; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final first = _start(client, store, journal);
    await first.load();
    expect(store.watermark?.held, [r'$utd']);
    first.dispose();

    // Its room key arrived directly while the app was closed.
    journal.history[1] = _metadata(
      journal,
      'utd',
      _min(1),
      'org:utd',
      7,
      senderKey: phone,
    );
    final second = _start(client, store, journal);
    addTearDown(second.dispose);
    await second.load();
    expect(second.values['org:utd'], {'n': 7});
    expect(store.watermark?.held, isEmpty);
  });

  test('a held undecryptable event is replayed when its key arrives', () async {
    const phone = 'synthetic-phone-key';
    client.verify(phone);
    final store = _Store();
    final journal = _Journal();
    journal.history
      ..add(_create(journal))
      ..add(
        _undecrypted(
          journal,
          'utd',
          _min(1),
          senderKey: phone,
          session: _sessionOf(phone),
        ),
      );
    for (var i = 2; i <= 300; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final first = _start(client, store, journal);
    await first.load();
    first.dispose();
    final second = _start(client, store, journal);
    addTearDown(second.dispose);
    await second.load();
    expect(journal.eventReads, [r'$utd']);
    expect(second.values['org:utd'], isNull);

    // The room key reaches the running app: the SDK announces its session.
    _plaintexts[r'$utd'] = _metadata(
      journal,
      'utd',
      _min(1),
      'org:utd',
      9,
      senderKey: phone,
      decrypted: false,
    );
    _sessionFor(phone);
    journal.keys.add(_sessionOf(phone));
    await _idle();
    expect(second.values['org:utd'], {'n': 9});
    expect(store.watermark?.held, isEmpty);
  });

  test(
    'undecryptable history whose keys cannot arrive does not stay held',
    () async {
      final store = _Store();
      final journal = _Journal();
      journal.history.add(_create(journal));
      // Before this device existed: the worker never shared these sessions
      // with it, and it has since decrypted newer worker events directly.
      for (var i = 1; i <= 150; i++) {
        journal.history.add(_undecrypted(journal, 'old-$i', _min(i)));
      }
      for (var i = 151; i <= 300; i++) {
        journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
      }
      final personal = _start(client, store, journal);
      addTearDown(personal.dispose);
      await personal.load();
      expect(personal.ready, isTrue);
      expect(store.watermark?.eventId, r'$hb-300');
      expect(store.watermark?.held, isEmpty);
    },
  );

  test('held events are re-read by id in bounded numbers per start', () async {
    final store = _Store();
    final journal = _Journal();
    journal.history.add(_create(journal));
    // A device that never sent anything decryptable here: its events stay
    // held (a key may still arrive) until the held list is full.
    for (var i = 1; i <= 200; i++) {
      journal.history.add(
        _undecrypted(journal, 'gone-$i', _min(i), senderKey: 'synthetic-gone'),
      );
    }
    for (var i = 201; i <= 500; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final first = _start(client, store, journal);
    await first.load();
    expect(store.watermark?.held, hasLength(JournalWatermark.maxHeld));
    first.dispose();

    final second = _start(client, store, journal);
    addTearDown(second.dispose);
    await second.load();
    expect(second.ready, isTrue);
    // Held ids inside the loaded window need no read; of the rest at most 32
    // are read per start, the newest ones first, the others sampled.
    expect(journal.eventReads, hasLength(32));
    expect(journal.eventReads.toSet(), hasLength(32));
    int number(String id) => int.parse(id.split('-').last);
    final newest = journal.eventReads.take(16).map(number).toList();
    expect(newest, [for (var i = 0; i < 16; i++) newest.first - i]);
    expect(
      journal.eventReads.skip(16).map(number).every((n) => n < newest.last),
      isTrue,
    );
  });

  test(
    'a held event the server lost is dropped after repeated misses',
    () async {
      final store = _Store();
      final journal = _Journal();
      journal.history
        ..add(_create(journal))
        ..add(
          _metadata(
            journal,
            'late-device',
            _min(1),
            'org:late',
            1,
            senderKey: 'synthetic-new-device',
          ),
        );
      for (var i = 2; i <= 300; i++) {
        journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
      }
      final first = _start(client, store, journal);
      await first.load();
      expect(store.watermark?.held, [r'$late-device']);
      first.dispose();
      journal.history.removeAt(1);
      for (var start = 1; start <= 3; start++) {
        final next = _start(client, store, journal);
        await next.load();
        expect(
          store.watermark?.held,
          start < 3 ? [r'$late-device'] : isEmpty,
          reason: 'start $start',
        );
        next.dispose();
      }
    },
  );

  test('a forged envelope sender_key never applies a result', () async {
    final store = _Store();
    final journal = _Journal();
    journal.history
      ..add(_create(journal))
      ..add(
        // Encrypted by an unverified device of an access-token holder whose
        // envelope copies the worker's curve25519 key.
        _metadata(
          journal,
          'forged',
          _min(1),
          'org:forged',
          666,
          sessionOwner: 'synthetic-unverified-bridge',
        ),
      );
    for (var i = 2; i <= 20; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final personal = _start(client, store, journal);
    addTearDown(personal.dispose);
    await personal.load();
    expect(personal.ready, isTrue);
    expect(personal.values['org:forged'], isNull);
    expect(
      store.watermark?.held,
      isEmpty,
      reason: 'Its session can never vouch for the worker',
    );
    client.verify('synthetic-unverified-bridge');
    client.onSync.add(SyncUpdate(nextBatch: 'device-verified'));
    await _idle();
    expect(personal.values['org:forged'], isNull);
  });

  test(
    'trust changing inside acceptResult rescans before the watermark',
    () async {
      final store = _Store();
      final journal = _Journal();
      journal.history
        ..add(_create(journal))
        ..add(
          _metadata(
            journal,
            'late-device',
            _min(1),
            'org:late',
            1,
            senderKey: 'synthetic-new-device',
          ),
        )
        ..add(_metadata(journal, 'applied', _min(2), 'org:applied', 2));
      for (var i = 3; i <= 300; i++) {
        journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
      }
      var flipped = false;
      var savedWhileFlipped = false;
      store.onPut = (key) {
        if (!flipped && key.contains('org:applied')) {
          // The device is verified while the batch commits another result.
          flipped = true;
          client.verify('synthetic-new-device');
          return;
        }
        if (flipped &&
            key == _watermarkKey &&
            store.watermark?.held.isEmpty == true &&
            store.records['account:$_user:replica:org:late'] == null) {
          savedWhileFlipped = true;
        }
      };
      final first = _start(client, store, journal);
      await first.load();
      expect(flipped, isTrue);
      expect(
        savedWhileFlipped,
        isFalse,
        reason: 'Never settled as applied before it was applied',
      );
      expect(first.values['org:late'], {'n': 1});
      expect(store.watermark?.held, isEmpty);
      first.dispose();

      final second = _start(client, store, journal);
      addTearDown(second.dispose);
      await second.load();
      expect(second.values['org:late'], {'n': 1});
    },
  );

  test('a due reminder alert survives a restart until claimed', () async {
    final store = _Store();
    final journal = _Journal();
    journal.history
      ..add(_create(journal))
      ..add(
        _op(
          journal,
          'due',
          _min(1),
          'reminder.result',
          entity: 'reminder:fixture',
          payload: {'revision': 1, 'state': 'done', 'due': true},
        ),
      );
    for (var i = 2; i <= 200; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final first = _start(client, store, journal);
    await first.load();
    expect(first.dueReminderEvents.single.eventId, r'$due');
    expect(store.watermark?.held, [r'$due']);
    first.dispose();

    final second = _start(client, store, journal);
    addTearDown(second.dispose);
    var changes = 0;
    second.addListener(() => changes++);
    await second.load();
    expect(second.dueReminderEvents.single.eventId, r'$due');
    expect(journal.eventReads, [r'$due']);
    expect(changes, greaterThan(0));
    var shown = 0;
    await second.presentReminder(
      second.dueReminderEvents.single,
      () async => shown++,
    );
    expect(shown, 1);
    expect(second.dueReminderEvents, isEmpty);
    journal.timeline.deliver(_heartbeat(journal, 'hb-201', _min(201)));
    await _idle();
    expect(store.watermark?.held, isEmpty);
    expect(store.watermark?.eventId, r'$hb-201');
  });

  test('ready client: load is free and only real changes notify', () async {
    final store = _Store();
    final journal = _Journal();
    journal.history.add(_create(journal));
    for (var i = 1; i <= 20; i++) {
      journal.history.add(_heartbeat(journal, 'hb-$i', _min(i)));
    }
    final personal = _start(client, store, journal);
    addTearDown(personal.dispose);
    await personal.load();
    var changes = 0;
    personal.addListener(() => changes++);
    final passes = personal.debugReplayPasses;
    final participants = journal.participantReads;
    await Future.wait(List.generate(5, (_) => personal.load()));
    expect(changes, 0);
    expect(personal.debugReplayPasses, passes);
    expect(journal.participantReads, participants);
    expect(journal.timelines, hasLength(1));

    // A command from another device changes nothing listeners render.
    journal.timeline.deliver(
      _op(
        journal,
        'command',
        _min(21),
        'metadata.put',
        entity: 'draft:synthetic',
        payload: {
          'value': {'text': 'synthetic'},
        },
        senderKey: 'synthetic-phone',
      ),
    );
    await _idle();
    expect(personal.debugReplayPasses, greaterThan(passes));
    expect(changes, 0);

    final readiness = personal.workerReadiness;
    journal.timeline.deliver(_heartbeat(journal, 'hb-22', _min(22)));
    await _idle();
    expect(changes, 1, reason: 'A new heartbeat refreshes worker readiness');
    expect(personal.workerReadiness, isNot(readiness));

    client.onSync.add(
      SyncUpdate(
        nextBatch: 'idle',
        rooms: RoomsUpdate(join: {journal.id: JoinedRoomUpdate()}),
      ),
    );
    await _idle();
    expect(changes, 1);
  });

  test('a fresh heartbeat inside the resume margin survives restart', () async {
    final store = _Store();
    final journal = _Journal();
    journal.history.add(_create(journal));
    // Phone commands every ten seconds around one heartbeat, then a result.
    Event command(int i) => _op(
      journal,
      'command-$i',
      _min(i / 6),
      'metadata.put',
      entity: 'draft:$i',
      senderKey: 'synthetic-phone',
    );
    for (var i = 1; i <= 200; i++) {
      journal.history.add(command(i));
    }
    journal.history.add(_heartbeat(journal, 'heartbeat', _min(34)));
    for (var i = 210; i <= 250; i++) {
      journal.history.add(command(i));
    }
    journal.history.add(_metadata(journal, 'result', _min(42), 'org:r', 1));
    final first = _start(client, store, journal);
    await first.load();
    expect(first.workerReadiness?.receivedAt, _min(34));
    expect(store.watermark?.eventId, r'$result');
    first.dispose();

    final second = _start(client, store, journal);
    addTearDown(second.dispose);
    await second.load();
    expect(
      second.workerReadiness?.receivedAt,
      _min(34),
      reason: 'The margin before the watermark keeps a fresh heartbeat loaded',
    );
    expect(journal.timeline.requests, 1);
    expect(
      journal.timeline.canRequestHistory,
      isTrue,
      reason: 'History before the margin stays on the server',
    );
  });
}
