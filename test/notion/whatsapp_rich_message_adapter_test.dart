// SPDX-License-Identifier: AGPL-3.0-or-later
// Real renderer and Matrix relation aggregator, with fictional events and an
// in-memory relations endpoint. No account, external HTTP or send is used.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/html_message.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/pages/chat/events/whatsapp_rich_message.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Client extends Client {
  _Client() : super('WhatsApp read-only fixture', database: _NoDatabase());
  @override
  String get userID => '@me:example.invalid';
  int relationRequests = 0;
  final pages = <List<MatrixEvent>>[];
  int? delayedPage;
  Future<void>? pageDelay;
  final failingPages = <int>{};

  @override
  Future<GetRelatingEventsWithRelTypeResponse> getRelatingEventsWithRelType(
    String roomId,
    String eventId,
    String relType, {
    String? from,
    String? to,
    int? limit,
    Direction? dir,
    bool? recurse,
  }) async {
    relationRequests++;
    final page = from == null ? 0 : int.parse(from);
    if (page == delayedPage) await pageDelay;
    if (failingPages.contains(page)) {
      throw StateError('synthetic relations failure');
    }
    return GetRelatingEventsWithRelTypeResponse(
      chunk: page < pages.length ? pages[page] : [],
      nextBatch: page + 1 < pages.length ? '${page + 1}' : null,
    );
  }
}

Map<String, dynamic> _interactive() => {
  'schema_version': 1,
  'body': 'Fictional event update',
  'formatted_body': '<b>Fictional event update</b>',
  'actions': [
    {'kind': 'url', 'label': 'View Post', 'url': 'https://example.org/post'},
  ],
};

Map<String, dynamic> _poll() => {
  'msgtype': 'm.text',
  'body': 'Lunch?\n1. Soup\n2. Rice\nOpen WhatsApp to vote',
  'fi.mau.whatsapp.poll': <String, dynamic>{},
  WhatsAppPollSnapshot.startKey: {
    'kind': 'org.matrix.msc3381.poll.disclosed',
    'question': {WhatsAppPollSnapshot.textKey: 'Lunch?'},
    'max_selections': 1,
    'answers': [
      {'id': 'soup', WhatsAppPollSnapshot.textKey: 'Soup'},
      {'id': 'rice', WhatsAppPollSnapshot.textKey: 'Rice'},
    ],
  },
};

void main() {
  late _Client client;
  late Room room;
  late Timeline timeline;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() {
    client = _Client();
    room = Room(id: '!fixture:example.invalid', client: client);
    timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: []),
    );
  });
  tearDown(() => timeline.cancelSubscriptions());

  Event event(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
  }) => Event(
    room: room,
    eventId: r'$poll',
    senderId: '@sender:example.invalid',
    originServerTs: DateTime.utc(2026),
    type: type,
    content: content,
  );

  Widget host(Event e) => MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    home: Scaffold(
      body: SizedBox(
        width: 320,
        child: MessageContent(
          e,
          timeline: timeline,
          textColor: NotionColors.dark.text,
          linkColor: NotionColors.dark.accent,
          borderRadius: NotionRadius.mdAll,
          selected: false,
          bigEmojis: const {},
        ),
      ),
    ),
  );

  Event vote(String id, String answer, int seconds) => Event(
    room: room,
    eventId: id,
    senderId: '@voter:example.invalid',
    originServerTs: DateTime.utc(2026, 1, 1, 0, 0, seconds),
    type: PollEventContent.responseType,
    content: {
      'm.relates_to': {'rel_type': 'm.reference', 'event_id': r'$poll'},
      PollEventContent.responseType: {
        'answers': answer.isEmpty ? [] : [answer],
      },
    },
  );

  test('display copy preserves source, media and original fallback', () {
    final original = event({
      'msgtype': 'm.image',
      'filename': 'image.jpg',
      'body': 'Fictional event update\nView Post https://example.org/post',
      'file': {'url': 'mxc://example.invalid/image', 'v': 'v2'},
      'info': {'w': 320, 'h': 240},
      WhatsAppInteractiveContent.contentKey: _interactive(),
    });
    final source = original.toJson();
    final display = whatsAppDisplayEvent(
      original,
      WhatsAppInteractiveContent.fromContent(original.content)!,
    );
    expect(display.room, same(original.room));
    expect(display.eventId, original.eventId);
    expect(display.type, original.type);
    expect(display.content['file'], original.content['file']);
    expect(display.content['filename'], 'image.jpg');
    expect(display.body, 'Fictional event update');
    expect(original.toJson(), source);
    expect(
      display.content,
      isNot(contains(WhatsAppInteractiveContent.contentKey)),
    );
    final other = event(
      {...original.content}..remove(WhatsAppInteractiveContent.contentKey),
    );
    expect(MediaAlbums.of([original, other]), everyElement(isNull));
  });

  testWidgets('CTA renders its clean body once with real URL', (tester) async {
    final e = event({
      'msgtype': 'm.text',
      'body': 'Fallback <cta_url> Use the WhatsApp app to click buttons',
      WhatsAppInteractiveContent.contentKey: _interactive(),
    });
    await tester.pumpWidget(host(e));
    expect(find.byType(NotionWhatsAppActions), findsOneWidget);
    expect(find.text('View Post'), findsOneWidget);
    expect(
      tester.widget<HtmlMessage>(find.byType(HtmlMessage)).html,
      '<b>Fictional event update</b>',
    );
    expect(client.relationRequests, 0);
    expect(e.body, contains('<cta_url>'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('old/lost and invalid CTA data retain the fallback', (
    tester,
  ) async {
    for (final extension in [
      null,
      {..._interactive(), 'schema_version': 2},
    ]) {
      await tester.pumpWidget(
        host(
          event({
            'msgtype': 'm.text',
            'body': '<cta_url> Use the WhatsApp app to click buttons',
            WhatsAppInteractiveContent.contentKey: ?extension,
          }),
        ),
      );
      expect(find.byType(NotionWhatsAppActions), findsNothing);
      expect(
        tester.widget<HtmlMessage>(find.byType(HtmlMessage)).html,
        contains('&lt;cta_url&gt;'),
      );
    }
  });

  for (final type in [EventTypes.Message, PollEventContent.startType]) {
    testWidgets('poll $type needs no top-level text and is read-only', (
      tester,
    ) async {
      final e = event(_poll(), type: type);
      await tester.pumpWidget(host(e));
      await tester.pumpAndSettle();
      expect(find.byType(NotionReadOnlyPoll), findsOneWidget);
      expect(find.text('Lunch?'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(client.relationRequests, 1);
      await tester.tap(find.text('Soup'));
      await tester.pumpWidget(host(e));
      await tester.pumpAndSettle();
      expect(client.relationRequests, 1);
      expect(e.type, type);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('paginated results, revote, redaction and unvote stay current', (
    tester,
  ) async {
    final older = vote(r'$a', 'soup', 1);
    final newer = vote(r'$b', 'rice', 2);
    client.pages.addAll([
      [older],
      [newer],
    ]);
    final e = event(_poll());
    await tester.pumpWidget(host(e));
    await tester.pumpAndSettle();
    NotionReadOnlyPoll card() => tester.widget(find.byType(NotionReadOnlyPoll));
    expect(client.relationRequests, 2);
    expect(card().options.map((o) => o.votes), [0, 1]);
    // A fetched relation is not necessarily in timeline.events. The adapter
    // still observes its redaction without reviving the older Soup vote.
    client.onTimelineEvent.add(
      Event(
        room: room,
        eventId: r'$redaction',
        senderId: '@voter:example.invalid',
        originServerTs: DateTime.utc(2026, 1, 1, 0, 0, 3),
        type: EventTypes.Redaction,
        content: {},
        redacts: newer.eventId,
      ),
    );
    await tester.pumpAndSettle();
    expect(card().options.map((o) => o.votes), [null, null]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host(e));
    await tester.pumpAndSettle();
    expect(card().options.map((o) => o.votes), [null, null]);
    client.onTimelineEvent.add(vote(r'$c', 'soup', 4));
    await tester.pumpAndSettle();
    expect(card().options.map((o) => o.votes), [1, 0]);
    client.onTimelineEvent.add(vote(r'$d', '', 5));
    await tester.pumpAndSettle();
    expect(card().options.map((o) => o.votes), [null, null]);
    expect(client.relationRequests, 2);
  });

  testWidgets('redaction before a pending relations page tombstones its vote', (
    tester,
  ) async {
    final gate = Completer<void>();
    client.delayedPage = 1;
    client.pageDelay = gate.future;
    client.pages.addAll([
      [vote(r'$early', 'soup', 1)],
      [vote(r'$late', 'rice', 2)],
    ]);
    await tester.pumpWidget(host(event(_poll())));
    await tester.pump();
    expect(client.relationRequests, 2);
    client.onTimelineEvent.add(
      Event(
        room: room,
        eventId: r'$redact-late',
        senderId: '@voter:example.invalid',
        originServerTs: DateTime.utc(2026, 1, 1, 0, 0, 3),
        type: EventTypes.Redaction,
        content: {},
        redacts: r'$late',
      ),
    );
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    final card = tester.widget<NotionReadOnlyPoll>(
      find.byType(NotionReadOnlyPoll),
    );
    expect(card.options.map((o) => o.votes), [null, null]);
  });

  testWidgets(
    'partial relation failure preserves results and exposes failure',
    (tester) async {
      client.pages.addAll([
        [vote(r'$first', 'soup', 1)],
        [],
      ]);
      client.failingPages.add(1);
      final e = event(_poll());
      await tester.pumpWidget(host(e));
      await tester.pumpAndSettle();
      var card = tester.widget<NotionReadOnlyPoll>(
        find.byType(NotionReadOnlyPoll),
      );
      expect(card.options.map((o) => o.votes), [1, 0]);
      expect(card.status, contains('could not be loaded'));
      // A fresh mount retries the failed relation request, without any send.
      await tester.pumpWidget(const SizedBox.shrink());
      client.failingPages.clear();
      await tester.pumpWidget(host(e));
      await tester.pumpAndSettle();
      card = tester.widget<NotionReadOnlyPoll>(find.byType(NotionReadOnlyPoll));
      expect(card.status, contains('Results from available votes'));
      expect(client.relationRequests, 4);
    },
  );

  test(
    'first and coalesced relation callers receive explicit failure',
    () async {
      final gate = Completer<void>();
      client.delayedPage = 0;
      client.pageDelay = gate.future;
      client.failingPages.add(0);
      final first = timeline.fetchAggregatedEvents(
        r'$poll',
        RelationshipTypes.reference,
        throwOnError: true,
      );
      final second = timeline.fetchAggregatedEvents(
        r'$poll',
        RelationshipTypes.reference,
        throwOnError: true,
      );
      final checks = [
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ];
      gate.complete();
      await Future.wait(checks);
      expect(client.relationRequests, 1);
      client.failingPages.clear();
      await timeline.fetchAggregatedEvents(
        r'$poll',
        RelationshipTypes.reference,
        throwOnError: true,
      );
      expect(client.relationRequests, 2);
    },
  );
}
