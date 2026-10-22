// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_read_button.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Client extends ConversationClient {
  @override
  Uri get baseUri => Uri.parse('https://fixture.invalid');
}

class _Room extends ConversationRoom {
  Event? latest;
  final receipts = <(String?, String?, bool?)>[];
  Completer<void>? gate;
  bool fail = false;

  _Room(super.client, super.id);

  @override
  Event? get lastEvent => latest;

  void incoming(String id) => latest = Event(
    room: this,
    eventId: id,
    type: EventTypes.Message,
    senderId: '@fixture:example.invalid',
    originServerTs: DateTime.utc(2026, 10, 21),
    content: {'msgtype': MessageTypes.Text, 'body': 'Fictional message'},
  );

  /// The user's own message that failed to send: the preview is a local echo.
  Event echo() => latest = Event(
    room: this,
    eventId: 'fixture-transaction',
    type: EventTypes.Message,
    senderId: client.userID!,
    status: EventStatus.error,
    originServerTs: DateTime.utc(2026, 10, 21, 0, 1),
    content: {'msgtype': MessageTypes.Text, 'body': 'Fictional message'},
  );

  @override
  Future<void> setReadMarker(
    String? eventId, {
    String? mRead,
    bool? public,
  }) async {
    receipts.add((eventId, mRead, public));
    if (fail) throw StateError('Offline fixture');
    await gate?.future;
  }
}

Future<void> _mount(
  WidgetTester tester,
  List<Room> rooms, {
  Iterable<Event> Function(Room room)? loaded,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: ConversationReadButton(rooms: rooms, loadedEvents: loaded),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.personalIncognito.setItem(true);
    await AppSettings.sendPublicReadReceipts.setItem(false);
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
  });

  testWidgets('one tap sends a public receipt in incognito without a dialog', (
    tester,
  ) async {
    final room = _Room(_Client(), '!fixture:example.invalid')
      ..incoming(r'$one');
    room.gate = Completer<void>();
    await _mount(tester, [room]);
    final button = find.byType(ConversationReadButton);
    expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    expect(room.receipts, [(r'$one', r'$one', true)]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(AppSettings.personalIncognito.value, isTrue);
    expect(AppSettings.sendPublicReadReceipts.value, isFalse);
    room.gate!.complete();
    await tester.pumpAndSettle();
    // Automatic reads remain suppressed after the manual action.
    await PersonalPrivacy.markRead(room, r'$two', publicReceipt: true);
    expect(room.receipts, hasLength(1));
  });

  testWidgets('merged sources freeze cutoffs and a partial failure can retry', (
    tester,
  ) async {
    final client = _Client();
    final a = _Room(client, '!a:example.invalid')..incoming(r'$a');
    final b = _Room(client, '!b:example.invalid')..incoming(r'$b');
    a.gate = Completer<void>();
    b.fail = true;
    await _mount(tester, [a, b]);
    await tester.tap(find.byType(ConversationReadButton));
    await tester.pump();
    b.incoming(r'$new');
    expect(b.receipts, [(r'$b', r'$b', true)]);
    a.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t mark as read.'), findsOneWidget);

    // The snackbar's Retry runs the same explicit read (CS-13).
    b.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(b.receipts.last, (r'$new', r'$new', true));
  });

  testWidgets('a pending own message as the preview marks the newest server '
      'event of the loaded timeline; a source with nothing to mark is '
      'skipped, not an error', (tester) async {
    final client = _Client();
    final a = _Room(client, '!a:example.invalid')..incoming(r'$loaded');
    final loaded = a.latest!;
    final echo = a.echo();
    final b = _Room(client, '!b:example.invalid');
    await _mount(
      tester,
      [a, b],
      loaded: (room) => room == a ? [echo, loaded] : const [],
    );
    await tester.tap(find.byType(ConversationReadButton));
    await tester.pumpAndSettle();
    expect(a.receipts, [(r'$loaded', r'$loaded', true)]);
    expect(b.receipts, isEmpty);
    expect(
      find.text('Could not mark all messages as read. Tap to retry.'),
      findsNothing,
    );
  });

  test('public override requires an explicit manual action', () async {
    await AppSettings.personalIncognito.setItem(false);
    final room = _Room(_Client(), '!fixture:example.invalid')
      ..incoming(r'$one');
    await PersonalPrivacy.markRead(room, r'$one', publicReceipt: true);
    expect(room.receipts, [(r'$one', r'$one', false)]);
  });

  testWidgets('locked or background surfaces cannot send receipts', (
    tester,
  ) async {
    final room = _Room(_Client(), '!fixture:example.invalid')
      ..incoming(r'$one');
    await _mount(tester, [room]);
    PersonalPrivacy.surfaceUnlocked = false;
    await tester.tap(find.byType(ConversationReadButton));
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = false;
    await tester.tap(find.byType(ConversationReadButton));
    expect(room.receipts, isEmpty);
    PersonalPrivacy.surfaceForeground = true;
  });
}
