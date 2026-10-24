// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/conversation_mute.dart';
import 'package:chatloom/personal/ui/scheduled_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// Fictional job; no real identifiers or message text.
Map<String, dynamic> _job(
  String state, {
  required DateTime due,
  bool attempted = false,
  Map<String, dynamic>? content,
}) => {
  'id': 'fixture',
  'state': state,
  'dueAt': due.toUtc().toIso8601String(),
  'attempted': attempted,
  'target': {
    'conversation': {
      'accountId': '@fixture:example.invalid',
      'roomId': '!fixture:example.invalid',
      'network': 'telegram',
    },
  },
  'content': content ?? {'msgtype': 'm.text', 'body': 'Fixture text'},
};

void main() {
  // Tuesday 21 October 2026, 10:00 local.
  final now = DateTime(2026, 10, 21, 10);
  final later = now.add(const Duration(hours: 3));

  group('scheduledStatus', () {
    ScheduledStatus status(
      String state, {
      bool pending = false,
      DateTime? at,
    }) => scheduledStatus(
      _job(state, due: at ?? later),
      pending: pending,
      now: now,
    );

    test('human words and sections instead of worker states', () {
      expect(status('queued').note, isNull);
      expect(status('queued').group, ScheduledGroup.upcoming);
      expect(status('queued', at: now).note, 'Sending…');
      expect(status('waitingSync').note, 'Saving…');
      expect(status('waitingKeys').note, 'Waiting for encryption keys');
      expect(status('waitingKeys').group, ScheduledGroup.attention);
      expect(status('paused').note, 'Paused');
      expect(status('failed').group, ScheduledGroup.attention);
      expect(status('failed').danger, isTrue);
      expect(status('failed').note, contains('schedule it again'));
      expect(status('done').note, 'Sent');
      expect(status('done').group, ScheduledGroup.recent);
      expect(status('cancelled').group, ScheduledGroup.recent);
      expect(status('mystery').note, contains('Check private sync'));
      for (final s in ['queued', 'waitingKeys', 'waitingSync', 'paused']) {
        expect(status(s).note ?? '', isNot(contains(s)));
      }
    });

    test('a change waiting for the worker reads as saving', () {
      expect(status('queued', pending: true).note, 'Saving…');
      expect(status('done', pending: true).note, 'Sent');
    });
  });

  test('preview: one line of text, attachments by kind', () {
    expect(
      scheduledPreview(
        _job(
          'queued',
          due: later,
          content: {'msgtype': 'm.text', 'body': 'Line one\nline two'},
        ),
      ),
      'Line one line two',
    );
    expect(
      scheduledPreview(
        _job(
          'queued',
          due: later,
          content: {'msgtype': 'm.image', 'body': 'fixture.jpg'},
        ),
      ),
      'Photo · fixture.jpg',
    );
    final long = scheduledPreview(
      _job(
        'queued',
        due: later,
        content: {'msgtype': 'm.text', 'body': 'x' * 200},
      ),
    );
    expect(long.length, 80);
    expect(long.endsWith('…'), isTrue);
  });

  test('source label names the network and the relation', () {
    final reply = _job(
      'queued',
      due: later,
      content: {
        'msgtype': 'm.text',
        'body': 'Fixture',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$fixture'},
        },
      },
    );
    expect(scheduledSourceLabel(reply), 'Telegram · Reply');
  });

  test('timed mute subtitle', () {
    const l10n = DefaultMaterialLocalizations();
    expect(conversationMuteSubtitle(null, now, l10n), 'Muted');
    expect(
      conversationMuteSubtitle(DateTime(2026, 10, 21, 14, 30), now, l10n),
      'Muted until Today · 14:30',
    );
    expect(
      conversationMuteSubtitle(DateTime(2026, 10, 22, 9), now, l10n),
      'Muted until Tomorrow · 09:00',
    );
  });

  testWidgets('the edit sheet returns trimmed text and the kept time', (
    tester,
  ) async {
    ({String? text, DateTime at})? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showScheduledEditor(
                context,
                chatName: 'Fixture chat',
                text: 'Fixture text',
                at: later,
                clock: () => now,
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit scheduled message'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('scheduled-edit-text')),
      '',
    );
    await tester.pump();
    // An empty message cannot be saved.
    await tester.tap(find.byKey(const ValueKey('scheduled-edit-save')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('scheduled-edit-text')),
      '  New fixture  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('scheduled-edit-save')));
    await tester.pumpAndSettle();
    expect(result?.text, 'New fixture');
    expect(result?.at, later);
    expect(tester.takeException(), isNull);
  });
}
