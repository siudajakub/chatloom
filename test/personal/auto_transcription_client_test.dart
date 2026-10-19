// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: in-memory private store, fixture rooms, no journal or network.
// Every test must finish in seconds; never wait on real storage from a
// fake-async widget test.
@Timeout(Duration(seconds: 60))
library;

import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/storage/personal_store.dart';
import 'package:fluffychat/personal/ui/chat_preferences_page.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:fluffychat/personal/ui/transcription_settings.dart';
import 'package:fluffychat/personal/worker_readiness.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<Map<String, dynamic>?> get(String key) async => records[key];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async =>
      records[key] = value;
  @override
  Future<void> delete(String key) async => records.remove(key);
  @override
  Future<void> close() async {}
}

/// Real replica and policy logic; only journal readiness is simulated.
class _Personal extends PersonalClient {
  _Personal(super.client, _Store store)
    : super.forTesting(openStore: () async => store);
  bool fakeReady = true;
  bool fakeWorkerOnline = true;
  int notifications = 0;
  @override
  Future<void> load() async {}
  @override
  bool get ready => fakeReady;
  @override
  bool get workerOnline => fakeWorkerOnline;
  @override
  void notifyListeners() {
    notifications++;
    super.notifyListeners();
  }

  Iterable<PersonalOperation> get requests =>
      pending.values.where((op) => op.kind == 'transcript.request');
}

Event voice(
  Room room,
  String id, {
  Duration age = const Duration(seconds: 20),
  bool outgoing = false,
  bool marker = true,
}) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: outgoing ? room.client.userID! : '@anna:example.invalid',
  originServerTs: DateTime.now().subtract(age),
  content: {
    'msgtype': MessageTypes.Audio,
    'body': 'Voice message',
    'url': 'mxc://example.invalid/voice',
    'info': {'duration': 12000, 'mimetype': 'audio/ogg'},
    if (marker) 'org.matrix.msc3245.voice': <String, dynamic>{},
  },
);

Event round(Room room, String id, {Map<String, dynamic> extra = const {}}) =>
    Event(
      room: room,
      eventId: id,
      type: EventTypes.Message,
      senderId: '@anna:example.invalid',
      originServerTs: DateTime.now(),
      content: {
        'msgtype': 'm.video',
        'body': 'Round',
        'url': 'mxc://example.invalid/round',
        'info': {
          'mimetype': 'video/mp4',
          'w': 384,
          'h': 384,
          'duration': 9000,
          roundMessageMarker: true,
          ...extra,
        },
      },
    );

Future<void> flushTimers() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

String baselineKey(Client client) =>
    'account:${client.userID}:autoTranscriptionBaseline';

WorkerReadiness heartbeat(String? auto) =>
    WorkerReadiness(receivedAt: DateTime.now(), autoTranscription: auto);

void main() {
  late ConversationClient client;
  late ConversationRoom cloud;
  late ConversationRoom local;
  late _Store store;
  late _Personal personal;

  setUp(() async {
    client = ConversationClient();
    cloud = ConversationRoom(client, '!cloud:example.invalid');
    local = ConversationRoom(
      client,
      '!telegram:beeper.local',
      network: 'telegram',
    );
    store = _Store();
    // This device first saw the default policy with a scanning worker an
    // hour ago (see the baseline tests below).
    store.records[baselineKey(client)] = {
      'since': DateTime.now()
          .subtract(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
    };
    personal = _Personal(client, store);
    personal.workerReadiness = heartbeat('scan');
    await personal.loadLocal();
    await personal.loadAutoTranscriptionBaseline();
  });
  tearDown(() {
    personal.fakeReady = false;
    personal.cancelAutoTranscriptionTimers();
  });

  test(
    'policy defaults to automatic and round-trips through metadata',
    () async {
      expect(personal.transcriptionPolicy.auto, isTrue);
      expect(personal.transcriptionDefaultLanguage, isNull);
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.copyWith(defaultLanguage: () => 'hy'),
      );
      expect(
        personal.values[transcriptionPolicyEntity]?['defaultLanguage'],
        'hy',
      );
      expect(personal.transcriptionDefaultLanguage, 'hy');
      expect(
        personal.pending.values.single.kind,
        'metadata.put',
        reason: 'Saved as private journal metadata for the worker and devices',
      );
    },
  );

  test('only incoming voice notes and transcribable rounds qualify', () {
    expect(
      PersonalClient.autoTranscriptionKind(voice(cloud, r'$v')),
      AutoTranscriptionKind.voice,
    );
    expect(
      PersonalClient.autoTranscriptionKind(voice(cloud, r'$f', marker: false)),
      isNull,
      reason: 'An audio file without the voice marker is not a voice note',
    );
    expect(
      PersonalClient.autoTranscriptionKind(round(local, r'$r')),
      AutoTranscriptionKind.round,
    );
    expect(
      PersonalClient.autoTranscriptionKind(
        round(local, r'$once', extra: {'fi.mau.telegram.view_once': true}),
      ),
      isNull,
    );
    expect(
      PersonalClient.autoTranscriptionKind(local.message(r'$t', 'hello')),
      isNull,
    );
  });

  test(
    'cloud voice is pending and requested at once with the default language',
    () async {
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.copyWith(defaultLanguage: () => 'hy'),
      );
      final event = voice(cloud, r'$cloud');
      expect(personal.autoTranscriptPending(event), isTrue);
      await flushTimers();
      final request = personal.requests.single;
      expect(request.payload['origin'], 'auto');
      expect(request.payload['language'], 'hy');
      expect(request.entityId, personal.transcriptId(event));
      expect(
        request.entityId,
        transcriptEntityId(personal.source(event)),
        reason: 'Client and worker derive the same entity',
      );
      // The optimistic job replaces the pending hint; no second request.
      expect(personal.autoTranscriptPending(event), isFalse);
      await flushTimers();
      expect(personal.requests, hasLength(1));
    },
  );

  test('nothing automatic unless the worker reports its switch on', () async {
    // An old worker (no field) ignores `origin: auto` and would run the
    // request as an unlimited manual job; 'off' means the operator said no.
    for (final auto in [null, 'off']) {
      personal.workerReadiness = heartbeat(auto);
      expect(personal.autoTranscriptionAvailable, isFalse);
      for (final event in [
        voice(cloud, '\$cloud-$auto'),
        voice(local, '\$local-$auto'),
        voice(
          local,
          '\$late-$auto',
          age: const Duration(minutes: 2, seconds: 30),
        ),
      ]) {
        expect(personal.autoTranscriptPending(event), isFalse);
        expect(
          personal.autoTranscriptionBlockFor(event, DateTime.now()),
          'worker_off',
        );
      }
      await flushTimers();
      expect(personal.requests, isEmpty, reason: 'worker reports $auto');
    }
    // A catch-up scheduled while the switch was on re-checks it when firing.
    personal.workerReadiness = heartbeat('scan');
    expect(personal.autoTranscriptPending(voice(cloud, r'$flip')), isTrue);
    personal.workerReadiness = heartbeat('off');
    await flushTimers();
    expect(personal.requests, isEmpty);
    // The user's explicit request is unaffected.
    await personal.transcribe(voice(cloud, r'$manual'));
    expect(personal.requests.single.payload.containsKey('origin'), isFalse);
  });

  test('a never-saved policy starts its window when first seen', () async {
    final fresh = _Store();
    final device = _Personal(client, fresh)
      ..workerReadiness = heartbeat('scan');
    addTearDown(() {
      device.fakeReady = false;
      device.cancelAutoTranscriptionTimers();
    });
    await device.loadLocal();
    final before = voice(cloud, r'$before', age: const Duration(minutes: 1));
    // Unknown window start: no spinner, no request, and the start is
    // recorded now (locally, never as journal metadata).
    expect(device.autoTranscriptPending(before), isFalse);
    expect(
      device.autoTranscriptionBlockFor(before, DateTime.now()),
      'before_enabled',
    );
    await device.loadAutoTranscriptionBaseline();
    expect(fresh.records[baselineKey(client)]?['since'], isA<String>());
    expect(device.pending, isEmpty);
    expect(device.autoTranscriptPending(before), isFalse);
    expect(
      device.autoTranscriptionBlockFor(before, DateTime.now()),
      'before_enabled',
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final after = voice(cloud, r'$after', age: Duration.zero);
    expect(device.autoTranscriptPending(after), isTrue);
    await flushTimers();
    expect(device.requests.map((op) => op.payload['source']['eventId']), [
      r'$after',
    ]);
    // A restart keeps the recorded start instead of moving it.
    final saved = fresh.records[baselineKey(client)]!['since'];
    final restarted = _Personal(client, fresh)
      ..workerReadiness = heartbeat('scan');
    await restarted.loadLocal();
    await restarted.loadAutoTranscriptionBaseline();
    expect(fresh.records[baselineKey(client)]!['since'], saved);
    expect(
      restarted.autoTranscriptionBlockFor(before, DateTime.now()),
      'before_enabled',
    );
    restarted.fakeReady = false;
    restarted.cancelAutoTranscriptionTimers();
  });

  test(
    'chats with a disappearing timer are never sent automatically',
    () async {
      cloud.state(beeperDisappearingTimerKey, {
        'type': 'after_read',
        'timer': 86400000,
      });
      final event = voice(cloud, r'$disappearing');
      expect(
        personal.autoTranscriptionBlockFor(event, DateTime.now()),
        'disappearing',
      );
      expect(personal.autoTranscriptPending(event), isFalse);
      // Malformed state fails closed; mautrix's explicit off ({}) allows it.
      cloud.state(beeperDisappearingTimerKey, {'type': 7});
      expect(
        personal.autoTranscriptionBlockFor(event, DateTime.now()),
        'disappearing',
      );
      await flushTimers();
      expect(personal.requests, isEmpty);
      cloud.state(beeperDisappearingTimerKey, {});
      expect(personal.autoTranscriptionBlockFor(event, DateTime.now()), isNull);
      // A disappearing message itself is not a candidate at all.
      expect(
        PersonalClient.autoTranscriptionKind(
          round(
            local,
            r'$timed',
            extra: {
              beeperDisappearingTimerKey: {'type': 'after_send', 'timer': 1000},
            },
          ),
        ),
        isNull,
      );
    },
  );

  test('local bridge rooms give the worker scan a grace period', () async {
    final fresh = voice(local, r'$fresh');
    expect(personal.autoTranscriptPending(fresh), isTrue);
    await flushTimers();
    expect(personal.requests, isEmpty);
    // Past the grace period the visible device asks instead.
    final late = voice(
      local,
      r'$late',
      age: const Duration(minutes: 2, seconds: 30),
    );
    expect(personal.autoTranscriptPending(late), isTrue);
    await flushTimers();
    expect(personal.requests.single.payload['source']['eventId'], r'$late');
    // Older than the pending window: no spinner, but still caught up.
    final older = voice(local, r'$older', age: const Duration(minutes: 30));
    expect(personal.autoTranscriptPending(older), isFalse);
    await flushTimers();
    expect(personal.requests, hasLength(2));
  });

  test(
    'own, muted, disabled, offline and old messages are left alone',
    () async {
      expect(
        personal.autoTranscriptPending(voice(cloud, r'$own', outgoing: true)),
        isFalse,
      );
      expect(
        personal.autoTranscriptPending(
          voice(cloud, r'$old', age: const Duration(hours: 25)),
        ),
        isFalse,
      );
      personal.fakeWorkerOnline = false;
      expect(
        personal.autoTranscriptPending(voice(cloud, r'$offline')),
        isFalse,
      );
      personal.fakeWorkerOnline = true;
      await personal.put('org:${cloud.id}', {'muted': true});
      expect(personal.autoTranscriptPending(voice(cloud, r'$muted')), isFalse);
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.withChatOverride(cloud.id, true),
      );
      expect(
        personal.autoTranscriptPending(voice(cloud, r'$always')),
        isTrue,
        reason: 'Per-chat Always outranks the chat mute',
      );
      await flushTimers();
      expect(personal.requests.map((op) => op.payload['source']['eventId']), [
        r'$always',
      ]);
      // A scheduled catch-up re-checks the policy when it fires.
      final scheduled = voice(cloud, r'$scheduled');
      expect(personal.autoTranscriptPending(scheduled), isTrue);
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.withAuto(false, DateTime.now()),
      );
      expect(personal.autoTranscriptPending(voice(local, r'$off')), isFalse);
      await flushTimers();
      expect(personal.requests, hasLength(1));
    },
  );

  test('an expired pending window notifies so the spinner clears', () async {
    final event = voice(
      local,
      r'$expiring',
      age: const Duration(minutes: 2, seconds: 59, milliseconds: 800),
    );
    expect(personal.autoTranscriptPending(event), isTrue);
    // The worker disappears before this device could ask.
    personal.fakeWorkerOnline = false;
    final before = personal.notifications;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(personal.notifications, greaterThan(before));
    expect(personal.requests, isEmpty);
    personal.fakeWorkerOnline = true;
    expect(personal.autoTranscriptPending(event), isFalse);
  });

  group('settings', () {
    Future<void> mount(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      );
      await tester.pump();
    }

    // Widget tests run in a fake-async zone: the client and its replica must
    // be created inside it, so every storage future completes on pump().
    Future<_Personal> fakeZonePersonal() async {
      final created = _Personal(client, _Store());
      await created.loadLocal();
      return created;
    }

    testWidgets('Transcriptions section edits the synced policy', (
      tester,
    ) async {
      final personal = await fakeZonePersonal();
      final runs = <Future<void>>[];
      await mount(
        tester,
        ListenableBuilder(
          listenable: personal,
          builder: (context, _) => TranscriptionSettingsSection(
            personal: personal,
            run: (action) {
              final future = action();
              runs.add(future);
              return future;
            },
          ),
        ),
      );
      expect(find.text('Transcribe automatically'), findsOneWidget);
      expect(find.textContaining('sent to OpenAI'), findsOneWidget);
      expect(find.text('Telegram'), findsOneWidget);
      expect(find.text('Automatic: 0 completed'), findsOneWidget);
      expect(
        tester
            .widget<NotionSettingsToggle>(
              find.byKey(const ValueKey('transcription-auto')),
            )
            .value,
        isTrue,
      );

      Future<void> saved() async {
        await tester.pumpAndSettle();
        await Future.wait(runs);
        await tester.pump();
      }

      await tester.tap(find.text('Default language'));
      await tester.pumpAndSettle();
      expect(find.text('Հայերեն'), findsOneWidget);
      expect(find.text('Polski'), findsOneWidget);
      await tester.tap(find.text('Armenian'));
      await saved();
      expect(personal.transcriptionDefaultLanguage, 'hy');

      await tester.tap(find.text('Maximum length'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 min'));
      await saved();
      expect(personal.transcriptionPolicy.maxSeconds, 600);

      await tester.tap(find.text('Daily limit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('\$0.25'));
      await saved();
      expect(personal.transcriptionPolicy.dailyBudgetUsd, 0.25);

      NotionSettingsToggle telegram() => tester.widget<NotionSettingsToggle>(
        find.byKey(const ValueKey('transcription-network-telegram')),
      );

      // With automatic transcription off, network toggles keep showing the
      // saved choice but cannot be changed.
      await tester.tap(find.byKey(const ValueKey('transcription-auto')));
      await saved();
      expect(personal.transcriptionPolicy.auto, isFalse);
      expect(telegram().value, isTrue);
      expect(telegram().onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('transcription-auto')));
      await saved();
      expect(personal.transcriptionPolicy.auto, isTrue);

      await tester.tap(
        find.byKey(const ValueKey('transcription-network-telegram')),
      );
      await saved();
      expect(personal.transcriptionPolicy.networkEnabled('telegram'), isFalse);

      await tester.tap(find.byKey(const ValueKey('transcription-auto')));
      await saved();
      expect(personal.transcriptionPolicy.auto, isFalse);
      expect(telegram().value, isFalse);
      expect(personal.transcriptionPolicy.defaultLanguage, 'hy');
    });

    test('usage costs use cents and never round small spend to zero', () {
      expect(transcriptionUsageLabel(0), '\$0.00');
      expect(transcriptionUsageLabel(.0012), '< \$0.01');
      expect(transcriptionUsageLabel(.0123), '\$0.01');
      expect(transcriptionUsageLabel(1), '\$1.00');
    });

    testWidgets('per-chat override row saves Always and Never', (tester) async {
      final personal = await fakeZonePersonal();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(client, preferences),
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: ChatPreferencesPage(personal: personal, room: cloud),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Automatic transcription'), findsOneWidget);
      // The page shows a progress bar while saving: no pumpAndSettle then.
      Future<void> choose(String current, String next) async {
        await tester.tap(find.text(current).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(next).last);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
      }

      await choose('Default', 'Never');
      expect(personal.transcriptionPolicy.chatOverrides, {cloud.id: false});
      await choose('Never', 'Always');
      expect(personal.transcriptionPolicy.chatOverrides, {cloud.id: true});
    });
  });
}
