// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/ui/conversation_activity_widgets.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

const _owner = '@owner:example.invalid';
const _peer = '@peer:example.invalid';

class _Db implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('No IO');
}

class _Client extends Client {
  _Client() : super('activity widgets', database: _Db());
  @override
  String get userID => _owner;
  final direct = <String, List<String>>{};
  @override
  Map<String, List<String>> get directChats => direct;
}

class _Bridges extends BridgeHealthMonitor {
  _Bridges(super.client);
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  BridgeHealth? problemFor(Room room) => null;
}

Room _room(_Client client, String name, {String? network}) {
  final room = Room(
    id: '!$name:example.invalid',
    client: client,
    summary: RoomSummary.fromJson({
      'm.joined_member_count': 2,
      'm.invited_member_count': 0,
    }),
  );
  client.rooms.add(room);
  client.direct[_peer] = [...?client.direct[_peer], room.id];
  void state(String type, String key, Map<String, dynamic> content) {
    room.setState(
      Event(
        room: room,
        type: type,
        stateKey: key,
        content: content,
        senderId: _owner,
        eventId: '\$fixture-$type-$key',
        originServerTs: DateTime.utc(2026),
      ),
    );
  }

  for (final id in [_owner, _peer]) {
    state(EventTypes.RoomMember, id, {
      'membership': 'join',
      'displayname': 'Alex',
    });
  }
  if (network != null) {
    state('m.bridge', '', {
      'protocol': {'id': network},
    });
  }
  return room;
}

void main() {
  setUpAll(() async {
    final text = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      text.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
    }
    await text.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  late _Client client;
  late ConnectionStatusMonitor connection;
  late StreamController<SyncStatusUpdate> statuses;
  late SyncStatusUpdate currentStatus;
  var now = DateTime.utc(2026, 10, 23);

  setUp(() {
    client = _Client();
    now = DateTime.utc(2026, 10, 23);
    statuses = StreamController<SyncStatusUpdate>.broadcast();
    currentStatus = const SyncStatusUpdate(SyncStatus.finished);
    connection = ConnectionStatusMonitor(
      statuses: () => statuses.stream,
      current: () => currentStatus,
      firstSync: () => false,
      hasNetwork: () async => false,
      offlineGrace: Duration.zero,
    );
    ConnectionStatusMonitor.debugOverride(client, connection);
    BridgeHealthMonitor.debugOverride(client, _Bridges(client));
  });
  tearDown(() async {
    connection.dispose();
    await statuses.close();
    OwnSenderResolver.of(client).dispose();
  });

  Widget host(Iterable<Room> rooms, {bool sources = false}) => MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Scaffold(
      body: ConversationActivityBuilder(
        client: client,
        rooms: rooms,
        now: () => now,
        builder: (context, activity) => Column(
          children: [
            ConversationActivityAvatar(
              activity: activity,
              child: const SizedBox.square(
                dimension: 40,
                child: Text('private avatar'),
              ),
            ),
            ConversationActivityStatus(
              client: client,
              rooms: rooms,
              activity: activity,
              sourceLabels: sources,
            ),
            Text(
              conversationTypingText(context, activity, sourceLabels: sources),
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('online preserves avatar and error takes priority', (
    tester,
  ) async {
    final room = _room(client, 'native');
    await tester.pumpWidget(host([room]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-online-dot')), findsNothing);
    client.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pumpAndSettle();
    expect(find.text('private avatar'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conversation-online-dot')),
      findsOneWidget,
    );
    expect(find.text('Currently active'), findsOneWidget);
    client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.error));
    currentStatus = const SyncStatusUpdate(SyncStatus.error);
    statuses.add(currentStatus);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-online-dot')), findsNothing);
    expect(find.text('Currently active'), findsNothing);
    expect(find.text('Waiting for network…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('merged typing names both sources and expires without sync', (
    tester,
  ) async {
    final whatsapp = _room(client, 'wa', network: 'whatsapp');
    final signal = _room(client, 'signal', network: 'signal');
    for (final room in [whatsapp, signal]) {
      room.ephemerals['m.typing'] = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': [_peer],
        },
      );
    }
    await tester.pumpWidget(host([whatsapp, signal], sources: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('WhatsApp, Signal'), findsWidgets);
    expect(find.textContaining('Alex and Alex'), findsNothing);
    expect(find.text('is typing · WhatsApp, Signal'), findsWidgets);
    client.onPresenceChanged.add(
      CachedPresence(PresenceType.online, null, null, true, _peer),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('conversation-online-dot')), findsNothing);
    now = now.add(client.typingIndicatorTimeout);
    await tester.pump(client.typingIndicatorTimeout);
    await tester.pumpAndSettle();
    expect(find.textContaining('WhatsApp, Signal'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'changing sources drops old typing and unmount disposes observer',
    (tester) async {
      final first = _room(client, 'first', network: 'whatsapp');
      final second = _room(client, 'second', network: 'signal');
      first.ephemerals['m.typing'] = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': [_peer],
        },
      );
      await tester.pumpWidget(host([first], sources: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('WhatsApp'), findsWidgets);
      await tester.pumpWidget(host([second], sources: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('WhatsApp'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(client.typingIndicatorTimeout);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('capture real activity header states at narrow large text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      const captureKey = ValueKey('conversation-activity-capture');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 240);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final native = _room(client, 'native-capture');
      final whatsapp = _room(client, 'wa-capture', network: 'whatsapp');
      final signal = _room(client, 'signal-capture', network: 'signal');

      Widget captureHost(List<Room> rooms, {bool large = false}) => MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(NotionSpace.md),
              child: ConversationActivityBuilder(
                client: client,
                rooms: rooms,
                now: () => now,
                builder: (context, activity) => Align(
                  alignment: Alignment.topCenter,
                  child: NotionCompactChatHeader(
                    avatar: ConversationActivityAvatar(
                      activity: activity,
                      child: const NotionInitialAvatar(name: 'Alex'),
                    ),
                    name: 'Alex',
                    status: ConversationActivityStatus(
                      client: client,
                      rooms: rooms,
                      activity: activity,
                      sourceLabels: rooms.length > 1,
                    ),
                    onDetails: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      Future<void> capture(String name) async {
        final directory = Platform.environment['CONVERSATION_CAPTURE_DIR'];
        if (directory == null) return;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(captureKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$directory/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.pumpWidget(captureHost([native]));
      await tester.pumpAndSettle();
      client.onPresenceChanged.add(
        CachedPresence(PresenceType.online, null, null, true, _peer),
      );
      await tester.pumpAndSettle();
      expect(find.text('Currently active'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Currently active')), findsWidgets);
      await capture('native-header-online');

      final typing = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': [_peer],
        },
      );
      for (final room in [whatsapp, signal]) {
        room.ephemerals['m.typing'] = typing;
      }
      await tester.pumpWidget(captureHost([whatsapp, signal]));
      await tester.pumpAndSettle();
      expect(find.text('is typing · WhatsApp, Signal'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('is typing · WhatsApp, Signal')),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('conversation-online-dot')),
        findsNothing,
      );
      await capture('merged-header-typing');

      tester.view.physicalSize = const Size(320, 240);
      await tester.pumpWidget(captureHost([whatsapp, signal], large: true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final narrowStatus = tester.renderObject<RenderParagraph>(
        find.text('is typing · WhatsApp, Signal'),
      );
      expect(narrowStatus.didExceedMaxLines, isTrue);
      expect(
        find.bySemanticsLabel(RegExp('is typing · WhatsApp, Signal')),
        findsWidgets,
      );
      await capture('merged-header-narrow-large-text');

      signal.ephemerals.remove('m.typing');
      await tester.pumpWidget(captureHost([signal]));
      await tester.pumpAndSettle();
      expect(find.textContaining('WhatsApp'), findsNothing);
      expect(
        find.byKey(const ValueKey('conversation-online-dot')),
        findsNothing,
      );
      await capture('header-source-switch');
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });
}
