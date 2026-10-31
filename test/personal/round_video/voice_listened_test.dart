// SPDX-License-Identifier: AGPL-3.0-or-later
// "Mark listened" on an incoming Telegram voice note (J, 2026-10-31): only
// incoming voice notes in a portal whose bridge declares playback receipts,
// and the final privacy gate lets exactly that request through. Synthetic
// room state; no live account.
import 'dart:convert';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/audio_player.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/privacy_transport.dart';
import 'package:chatloom/personal/round_video/telegram_media_protocol.dart';
import 'package:chatloom/personal/round_video/telegram_room_binding.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/voice_playback.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@fixture-owner:example.invalid';
const _sender = '@fixture-contact:example.invalid';
const _bot = '@fixture-bridge:example.invalid';
const _login = 'fixture-own-login';
const _roomId = '!fixture-voice:example.invalid';
const _key = 'fixture-state';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation _) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('synthetic voice listened', database: _NoDatabase());
  @override
  bool get encryptionEnabled => true;
  @override
  String? get userID => _owner;
  @override
  String? get deviceID => 'fixture-device';
  @override
  Uri? get baseUri => Uri.parse('https://fixture.invalid');
}

class _Room extends Room {
  _Room(Client client)
    : super(id: _roomId, client: client, membership: Membership.join);
  final events = <String, Event>{};
  final sent = <String>[];
  @override
  Future<Event?> getEventById(String eventID) async => events[eventID];
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) async {
    sent.add(type);
    return r'$fixture-receipt';
  }
}

/// The account's encrypted private record, in memory.
class _Storage implements VoicePlayedStorage {
  Map<String, dynamic>? value;
  int reads = 0, writes = 0;
  bool failing = false;
  @override
  Future<Map<String, dynamic>?> read() async {
    reads++;
    if (failing) throw StateError('Encrypted storage is not open');
    return value;
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    if (failing) throw StateError('Encrypted storage is not open');
    this.value = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }
}

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String stateKey = _key,
  String sender = _bot,
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: stateKey,
    content: content,
    senderId: sender,
    eventId: r'$fixture-state',
    originServerTs: DateTime.utc(2026),
  ),
);

_Room _room({bool playbackReceipts = true}) {
  final client = _Client();
  final room = _Room(client);
  client.rooms.add(room);
  final info = <String, dynamic>{
    'bridgebot': _bot,
    'creator': _bot,
    'protocol': {'id': 'telegram'},
    'channel': {'fi.mau.receiver': _login},
  };
  _state(room, 'm.bridge', info);
  _state(room, 'uk.half-shot.bridge', info);
  _state(room, bridgeFeaturesEventType, {
    'id': 'fi.mau.telegram.capabilities.round.v1+fixture',
  });
  _state(room, telegramMediaCapabilitiesEventType, {
    'version': 1,
    'matrix_user_id': _owner,
    'account_id': _login,
    'room_id': _roomId,
    'bridge_state_key': _key,
    'playback_receipts': playbackReceipts,
  });
  _state(room, EventTypes.RoomMember, {'membership': 'join'}, stateKey: _bot);
  _state(
    room,
    EventTypes.Encryption,
    {'algorithm': AlgorithmTypes.megolmV1AesSha2},
    stateKey: '',
    sender: _owner,
  );
  TelegramRoomBinding.installTrustedIdentity(
    client,
    const RoundBridgeIdentity(
      accountId: _login,
      roomId: _roomId,
      stateKey: _key,
      senderId: _bot,
    ),
  );
  return room;
}

Event _audio(
  _Room room, {
  String sender = _sender,
  bool voice = true,
  Map<String, dynamic> extra = const {},
}) {
  final event = Event(
    room: room,
    type: EventTypes.Message,
    content: {
      'msgtype': MessageTypes.Audio,
      'body': 'voice.ogg',
      'url': 'mxc://fixture.invalid/voice',
      if (voice) 'org.matrix.msc3245.voice': <String, dynamic>{},
      ...extra,
    },
    senderId: sender,
    eventId: r'$fixture-voice',
    originServerTs: DateTime.utc(2026),
  );
  room.events[event.eventId] = event;
  return event;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  final defaultStorage = TelegramRoundService.voiceMarksStorage;
  setUp(() {
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
    // Memory only unless a test gives the account a store.
    TelegramRoundService.voiceMarksStorage = (_) => null;
  });
  tearDown(() => TelegramRoundService.voiceMarksStorage = defaultStorage);

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'a mark survives a restart; the action stays hidden while loading',
    () async {
      final storage = _Storage();
      TelegramRoundService.voiceMarksStorage = (_) => storage;
      final room = _room();
      final client = room.client;
      final voice = _audio(room);
      var service = TelegramRoundService.of(client);
      expect(service.canMarkVoiceListened(voice), isFalse, reason: 'loading');
      var notified = 0;
      service.addListener(() => notified++);
      await settle();
      expect(notified, greaterThan(0));
      expect(service.canMarkVoiceListened(voice), isTrue);

      // The bridge's state is known (none yet): the tap sends the receipt.
      service.debugSetMediaState(voice, null);
      await service.markVoiceListened(voice);
      expect(room.sent, [telegramMediaPlayedEventType]);
      expect(service.canMarkVoiceListened(voice), isFalse);
      await settle();
      expect(storage.value, {
        'marks': ['$_roomId:${voice.eventId}'],
      });

      // A new process: the stored mark keeps the action away.
      await TelegramRoundService.closeFor(client);
      service = TelegramRoundService.of(client);
      addTearDown(() => TelegramRoundService.closeFor(client));
      expect(service.canMarkVoiceListened(voice), isFalse);
      await settle();
      expect(service.canMarkVoiceListened(voice), isFalse);
      expect(room.sent, hasLength(1));
    },
  );

  test('a note the bridge reports listened offers no action', () async {
    final room = _room();
    final voice = _audio(room);
    final service = TelegramRoundService.of(room.client);
    addTearDown(() => TelegramRoundService.closeFor(room.client));
    service.debugSetMediaState(voice, {'media_unread': true});
    expect(service.canMarkVoiceListened(voice), isTrue);
    service.debugSetMediaState(voice, {'media_unread': false});
    expect(service.canMarkVoiceListened(voice), isFalse);
  });

  group('VoiceListenedMarks', () {
    test('bounded, newest kept, written once loaded', () async {
      final storage = _Storage()
        ..value = {
          'marks': [
            for (var i = 0; i < VoiceListenedMarks.capacity; i++) 'r:$i',
          ],
        };
      var ready = 0;
      final marks = VoiceListenedMarks(storage, onReady: () => ready++);
      // A mark while the stored ones load stays the newest.
      marks.add('r:new');
      expect(marks.ready, isFalse);
      await settle();
      expect(ready, 1);
      expect(marks.ready, isTrue);
      expect(marks.contains('r:new'), isTrue);
      expect(marks.contains('r:0'), isFalse, reason: 'the oldest is dropped');
      expect(marks.contains('r:1'), isTrue);
      final stored = storage.value!['marks'] as List;
      expect(stored, hasLength(VoiceListenedMarks.capacity));
      expect(stored.last, 'r:new');
      expect(storage.reads, 1);
    });

    test('an unreadable store keeps this session\'s marks only', () async {
      final storage = _Storage()..failing = true;
      final marks = VoiceListenedMarks(storage);
      expect(marks.ready, isFalse);
      await settle();
      expect(marks.ready, isTrue);
      marks.add('r:1');
      await settle();
      expect(marks.contains('r:1'), isTrue);
    });
  });

  testWidgets('the action takes the bubble foreground on a private palette', (
    tester,
  ) async {
    final room = _room();
    final voice = _audio(room);
    addTearDown(() => TelegramRoundService.closeFor(room.client));
    TelegramRoundService.of(room.client).debugSetMediaState(voice, null);
    // A light private bubble whose text is dark: the theme's light text on
    // it would be unreadable.
    const ink = Color(0xFF16213A);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: MarkListenedButton(event: voice, color: ink),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.text('Mark listened');
    expect(label, findsOneWidget);
    final text = tester.widget<RichText>(
      find.descendant(of: label, matching: find.byType(RichText)),
    );
    expect(text.text.style?.color, ink);
    final icon = find.byIcon(Icons.hearing_outlined);
    expect(IconTheme.of(tester.element(icon)).color, ink);
    // Unmount before the service closes.
    await tester.pumpWidget(const SizedBox());
  });

  test('only an incoming voice note with declared receipts offers it', () {
    final room = _room();
    final service = TelegramRoundService.of(room.client);
    addTearDown(() => TelegramRoundService.closeFor(room.client));
    expect(service.canMarkVoiceListened(_audio(room)), isTrue);
    expect(service.canMarkVoiceListened(_audio(room, sender: _owner)), isFalse);
    expect(service.canMarkVoiceListened(_audio(room, voice: false)), isFalse);
    expect(
      service.canMarkVoiceListened(_audio(room, extra: {'view_once': true})),
      isFalse,
    );
    // Round receipts keep their own gate: a voice note is not a round.
    expect(service.canExplicitlyReport(_audio(room)), isFalse);

    final undeclared = _room(playbackReceipts: false);
    addTearDown(() => TelegramRoundService.closeFor(undeclared.client));
    expect(
      TelegramRoundService.of(
        undeclared.client,
      ).canMarkVoiceListened(_audio(undeclared)),
      isFalse,
    );
  });

  test('the privacy gate passes a granted voice receipt only', () async {
    final room = _room();
    final client = room.client;
    PersonalPrivacy.bind(client);
    addTearDown(() => PersonalPrivacy.forget(client));
    Future<void> authorize(Event source) {
      final content = <String, dynamic>{
        'version': 1,
        'request_id': 'request-fixture',
        'created_at_ms': 0,
        'source': {
          'account_id': _login,
          'room_id': _roomId,
          'event_id': source.eventId,
        },
        'manual': true,
        'incognito': true,
        'explicit_grant': true,
      };
      return withMediaPlayedGrant(
        roomId: _roomId,
        eventId: source.eventId,
        sourceAccountId: _login,
        requestId: 'request-fixture',
        server: client.baseUri!,
        explicit: true,
        isCurrent: () => true,
        action: () async => client.authorizeOutgoingEvent!(
          room,
          telegramMediaPlayedType,
          content,
        ),
      );
    }

    await authorize(_audio(room));
    await expectLater(
      authorize(_audio(room, voice: false)),
      throwsA(isA<PrivacySuppressed>()),
    );
  });
}
