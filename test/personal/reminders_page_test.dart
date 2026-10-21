// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/reminder_list.dart';
import 'package:chatloom/personal/ui/reminders_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart' show PersonalOperation;

// Fictional conversation; no real identifiers.
const _conversation = {
  'accountId': '@fixture:example.invalid',
  'roomId': '!fixture:example.invalid',
  'network': 'telegram',
};

Map<String, dynamic> _job(
  String state, {
  required DateTime due,
  int revision = 1,
  String? errorCode,
  String? actualState,
  bool untilReply = false,
}) => {
  'id': 'unused',
  'kind': 'reminder',
  'conversation': _conversation,
  'dueAt': due.toUtc().toIso8601String(),
  'state': state,
  'revision': revision,
  'untilReply': untilReply,
  'errorCode': ?errorCode,
  'actualState': ?actualState,
};

PersonalOperation _op(String kind, String entity, Map<String, dynamic> body) =>
    PersonalOperation(
      opId: 'op-$kind-$entity',
      kind: kind,
      entityId: entity,
      createdAt: DateTime.utc(2026, 10, 21),
      payload: body,
    );

class _Recorder {
  final calls = <(String, String, Map<String, dynamic>, int?)>[];
  Future<Object?> call(
    String kind,
    String entityId,
    Map<String, dynamic> payload, {
    int? baseRevision,
  }) async {
    calls.add((kind, entityId, payload, baseRevision));
    return null;
  }
}

Widget _host(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  // Tuesday 21 October 2026, 10:00 local.
  final now = DateTime(2026, 10, 21, 10);

  group('ReminderList', () {
    test('shows a just-saved reminder before the worker answers', () {
      final list = ReminderList.from(
        reminders: const {},
        pending: [
          _op('reminder.create', 'new', {
            'id': 'new',
            'conversation': _conversation,
            'dueAt': now
                .add(const Duration(hours: 2))
                .toUtc()
                .toIso8601String(),
            'untilReply': false,
          }),
        ],
        now: now,
      );
      expect(list.upcoming.single.id, 'new');
      expect(list.upcoming.single.status, ReminderStatus.saving);
      expect(list.upcoming.single.busy, isTrue);
      expect(list.upcoming.single.editable, isFalse);
      expect(list.upcoming.single.roomId, '!fixture:example.invalid');
    });

    test('hides deleted and cancelled reminders, keeps skipped ones', () {
      final list = ReminderList.from(
        reminders: {
          'deleting': _job('queued', due: now.add(const Duration(days: 1))),
          'cancelled': _job('cancelled', due: now.add(const Duration(days: 1))),
          'replied': _job(
            'cancelled',
            due: now.subtract(const Duration(hours: 1)),
            errorCode: 'replied',
          ),
        },
        pending: [
          _op('reminder.cancel', 'deleting', {'id': 'deleting'}),
        ],
        now: now,
      );
      expect(list.upcoming, isEmpty);
      expect(list.past.single.id, 'replied');
      expect(list.past.single.status, ReminderStatus.skipped);
    });

    test('sorts upcoming soonest first and recent newest first', () {
      final list = ReminderList.from(
        reminders: {
          'later': _job('queued', due: now.add(const Duration(days: 3))),
          'soon': _job(
            'waitingKeys',
            due: now.add(const Duration(hours: 1)),
            untilReply: true,
          ),
          'old': _job('done', due: now.subtract(const Duration(days: 3))),
          'recent': _job('done', due: now.subtract(const Duration(hours: 1))),
          'ancient': _job('done', due: now.subtract(const Duration(days: 40))),
        },
        pending: const [],
        now: now,
      );
      expect(list.upcoming.map((e) => e.id), ['soon', 'later']);
      expect(list.upcoming.first.status, ReminderStatus.checking);
      expect(list.upcoming.first.editable, isTrue);
      expect(list.past.map((e) => e.id), ['recent', 'old']);
    });

    test('a reminder fired without a reply check says so', () {
      final list = ReminderList.from(
        reminders: {
          'checked': _job('done', due: now.subtract(const Duration(hours: 1))),
          'unchecked': {
            ..._job(
              'done',
              due: now.subtract(const Duration(hours: 2)),
              untilReply: true,
            ),
            'due': true,
            'replyCheck': 'skipped',
            'replyCheckError': 'waiting_keys',
          },
        },
        pending: const [],
        now: now,
      );
      expect(list.past.map((e) => e.id), ['checked', 'unchecked']);
      expect(list.past.first.replyCheckSkipped, isFalse);
      expect(list.past.last.status, ReminderStatus.done);
      expect(list.past.last.replyCheckSkipped, isTrue);
    });

    test('a refused create stays visible only while its time is ahead', () {
      final list = ReminderList.from(
        reminders: {
          'refused': _job(
            'conflict',
            due: now.add(const Duration(hours: 5)),
            revision: 0,
          ),
          'stale': _job(
            'conflict',
            due: now.subtract(const Duration(hours: 5)),
            revision: 0,
          ),
          'cancelRefused': _job(
            'conflict',
            due: now.add(const Duration(hours: 6)),
            actualState: 'queued',
          ),
        },
        pending: const [],
        now: now,
      );
      expect(list.upcoming.map((e) => (e.id, e.status)), [
        ('refused', ReminderStatus.notSaved),
        ('cancelRefused', ReminderStatus.scheduled),
      ]);
    });
  });

  group('times', () {
    test('presets are one tap, in the future and sensible', () {
      final presets = reminderPresets(now);
      expect(presets.map((p) => p.label), [
        'In 1 hour',
        'In 3 hours',
        'This evening',
        'Tomorrow morning',
        'Next week',
      ]);
      expect(presets.map((p) => p.at), [
        DateTime(2026, 10, 21, 11),
        DateTime(2026, 10, 21, 13),
        DateTime(2026, 10, 21, 18),
        DateTime(2026, 10, 22, 9),
        DateTime(2026, 10, 26, 9),
      ]);
      for (final preset in presets) {
        expect(reminderTimeValid(preset.at, now), isTrue);
      }
    });

    test('evening disappears late in the day; next week skips today', () {
      final late = reminderPresets(DateTime(2026, 10, 21, 17, 30));
      expect(late.map((p) => p.label), isNot(contains('This evening')));
      final monday = reminderPresets(DateTime(2026, 10, 26, 8));
      expect(monday.last.at, DateTime(2026, 11, 2, 9));
    });

    test('labels use relative days', () {
      const l = DefaultMaterialLocalizations();
      expect(reminderWhen(DateTime(2026, 10, 21, 18), now, l), 'Today · 18:00');
      expect(
        reminderWhen(DateTime(2026, 10, 22, 9), now, l),
        'Tomorrow · 09:00',
      );
      expect(
        reminderWhen(DateTime(2026, 10, 20, 9), now, l),
        'Yesterday · 09:00',
      );
      expect(
        reminderDay(DateTime(2026, 10, 30), now, l),
        l.formatMediumDate(DateTime(2026, 10, 30)),
      );
      expect(reminderTimeValid(now, now), isFalse);
    });
  });

  group('commands', () {
    test('create sends only the documented fields', () async {
      final recorder = _Recorder();
      final id = await createReminder(
        recorder.call,
        conversation: _conversation,
        dueAt: DateTime.utc(2026, 10, 22, 7),
        untilReply: false,
      );
      final (kind, entity, payload, _) = recorder.calls.single;
      expect(kind, 'reminder.create');
      expect(entity, id);
      expect(payload, {
        'id': id,
        'conversation': _conversation,
        'dueAt': '2026-10-22T07:00:00.000Z',
        'untilReply': false,
      });
    });

    test(
      'reschedule creates the new reminder before cancelling the old',
      () async {
        final recorder = _Recorder();
        final entry = ReminderList.from(
          reminders: {
            'old': {
              ..._job(
                'queued',
                due: now.add(const Duration(hours: 4)),
                revision: 3,
              ),
              'anchorEventId': r'$fixture-anchor',
            },
          },
          pending: const [],
          now: now,
        ).upcoming.single;
        await rescheduleReminder(
          recorder.call,
          entry,
          dueAt: now.add(const Duration(days: 1)),
          untilReply: true,
        );
        expect(recorder.calls.map((c) => c.$1), [
          'reminder.create',
          'reminder.cancel',
        ]);
        expect(recorder.calls.first.$3['anchorEventId'], r'$fixture-anchor');
        expect(recorder.calls.first.$3['untilReply'], isTrue);
        expect(recorder.calls.last.$2, 'old');
        expect(recorder.calls.last.$4, 3);
      },
    );
  });

  group('editor', () {
    testWidgets('defaults to a plain reminder and returns the chosen preset', (
      tester,
    ) async {
      ReminderEditorResult? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => result = await showReminderEditor(
                    context,
                    chatName: 'Fixture chat',
                    clock: () => now,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Remind me'), findsOneWidget);
      expect(find.text('Fixture chat'), findsOneWidget);
      // The first preset is preselected, so Save works at once.
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('11:00'), findsOneWidget);
      await tester.tap(find.text('Tomorrow morning'));
      await tester.pumpAndSettle();
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(find.text('09:00'), findsOneWidget);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.value, isFalse);
      await tester.tap(find.text('Save reminder'));
      await tester.pumpAndSettle();
      expect(result?.dueAt, DateTime(2026, 10, 22, 9));
      expect(result?.untilReply, isFalse);
      expect(result?.delete, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a time that has passed is explained and cannot be saved', (
      tester,
    ) async {
      var clock = now;
      final entry = ReminderEntry(
        id: 'fixture',
        conversation: _conversation,
        dueAt: now.add(const Duration(minutes: 5)),
        untilReply: true,
        status: ReminderStatus.scheduled,
      );
      await tester.pumpWidget(
        _host(
          ReminderEditor(
            chatName: 'Fixture chat',
            editing: entry,
            clock: () => clock,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose a time in the future.'), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('Delete reminder'), findsOneWidget);
      clock = now.add(const Duration(minutes: 10));
      // Any rebuild re-checks the time.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Choose a time in the future.'), findsOneWidget);
      final save = tester.widget<ButtonStyleButton>(
        find
            .ancestor(
              of: find.text('Save reminder'),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first,
      );
      expect(save.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
