// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/summary/summary_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';

final _now = DateTime.utc(2026, 11, 3, 12);

SummaryHistoryEntry _entry(
  int age, {
  String? id,
  String? omission,
  String? text,
  bool attachment = false,
}) {
  final timestamp = _now.subtract(Duration(hours: age));
  return SummaryHistoryEntry(
    id: id ?? 'fixture-$age',
    timestamp: timestamp,
    omission: omission,
    unreadAttachment: attachment,
    message: omission == null
        ? SummaryMessage(
            timestamp: timestamp,
            sender: 'Fixture participant',
            text: text ?? 'Fixture message $age',
          )
        : null,
  );
}

class _Source implements SummaryHistorySource {
  _Source(this.pages, {this.stall = false, this.failure});
  final List<List<SummaryHistoryEntry>> pages;
  final bool stall;
  final Object? failure;
  var page = 0;
  var disposed = false;
  final initialized = Completer<void>();
  Completer<void>? pending;

  @override
  Future<void> initialize({required int pageSize}) async {
    initialized.complete();
  }

  @override
  List<SummaryHistoryEntry> get entries => [
    for (var i = 0; i <= page; i++) ...pages[i],
  ];
  @override
  bool get hasMore => stall || page + 1 < pages.length;
  @override
  Object get position => page;
  @override
  Future<void> loadOlder({required int pageSize}) async {
    if (failure != null) throw failure!;
    if (pending != null) await pending!.future;
    if (!stall) page++;
  }

  @override
  void dispose() => disposed = true;
}

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('summary fixtures', database: _Database());
  @override
  String get userID => '@owner:example.invalid';
}

void main() {
  const collector = SummaryHistoryCollector();
  Future<SummarySource> collect(_Source source, SummaryRequest request) =>
      collector.collect(source: source, request: request, now: _now);

  test('last N consumes unreadable slots instead of replacing them', () async {
    final source = _Source([
      [_entry(0), _entry(1, omission: 'encrypted')],
      [_entry(2), _entry(3), _entry(4)],
    ]);
    final result = await collect(source, const SummaryRequest(amount: 3));
    expect(result.messages.map((m) => m.text), [
      'Fixture message 2',
      'Fixture message 0',
    ]);
    expect(result.omittedMessages, 1);
    expect(result.complete, false);
    expect(result.coverageNote, contains('1 encrypted'));
    expect(source.disposed, true);
  });

  test('pagination deduplicates overlapping pages and sorts output', () async {
    final source = _Source([
      [_entry(0), _entry(1)],
      [_entry(1), _entry(2), _entry(3)],
    ]);
    final result = await collect(source, const SummaryRequest(amount: 4));
    expect(result.messages.map((m) => m.text), [
      'Fixture message 3',
      'Fixture message 2',
      'Fixture message 1',
      'Fixture message 0',
    ]);
    expect(result.complete, true);
  });

  test(
    'hour window includes boundary and excludes future sync events',
    () async {
      final source = _Source([
        [_entry(-1), _entry(0), _entry(1)],
        [_entry(2), _entry(3)],
        [_entry(5)],
      ]);
      final result = await collect(
        source,
        const SummaryRequest(scope: SummaryScopeKind.hours, amount: 2),
      );
      expect(result.messages.length, 3);
      expect(
        result.messages.first.timestamp,
        _now.subtract(const Duration(hours: 2)),
      );
      expect(source.page, 1);
    },
  );

  test('day window uses the fixed request clock', () async {
    final source = _Source([
      [_entry(0), _entry(23), _entry(24), _entry(25)],
      [_entry(48)],
    ]);
    final result = await collect(
      source,
      const SummaryRequest(scope: SummaryScopeKind.days, amount: 1),
    );
    expect(result.messages.length, 3);
    expect(source.page, 0);
  });

  test(
    'an old backfill among recent messages does not close the time window',
    () async {
      final source = _Source([
        [_entry(0), _entry(48), _entry(1)],
        [_entry(2), _entry(3), _entry(49)],
        [_entry(72)],
      ]);
      final result = await collect(
        source,
        const SummaryRequest(scope: SummaryScopeKind.hours, amount: 3),
      );
      expect(result.messages.length, 4);
      expect(source.page, 1);
    },
  );

  test(
    'whole conversation loads until available history is exhausted',
    () async {
      final source = _Source([
        [_entry(0)],
        [_entry(1)],
        [_entry(2)],
      ]);
      final result = await collect(
        source,
        const SummaryRequest(scope: SummaryScopeKind.all),
      );
      expect(result.messages.length, 3);
      expect(source.page, 2);
      expect(result.coverageNote, contains('available to this account'));
    },
  );

  test('fewer available messages carries an explicit count', () async {
    final result = await collect(
      _Source([
        [_entry(0), _entry(1)],
      ]),
      const SummaryRequest(amount: 10),
    );
    expect(result.complete, true);
    expect(result.coverageNote, contains('Only 2 of the requested 10'));
  });

  test(
    'stalled pagination refuses to label a partial whole conversation',
    () async {
      final source = _Source([
        [_entry(0)],
      ], stall: true);
      await expectLater(
        collect(source, const SummaryRequest(scope: SummaryScopeKind.all)),
        throwsA(
          isA<SummaryException>().having(
            (e) => e.code,
            'code',
            'summary_history_incomplete',
          ),
        ),
      );
      expect(source.disposed, true);
    },
  );

  test('page bound refuses silently truncated history', () async {
    final source = _Source([
      [_entry(0)],
      [_entry(1)],
      [_entry(2)],
    ]);
    await expectLater(
      const SummaryHistoryCollector(maxPages: 1).collect(
        source: source,
        request: const SummaryRequest(scope: SummaryScopeKind.all),
        now: _now,
      ),
      throwsA(
        isA<SummaryException>().having(
          (e) => e.code,
          'code',
          'summary_history_incomplete',
        ),
      ),
    );
    expect(source.disposed, true);
  });

  test(
    'SDK failures become safe errors without forwarding sensitive detail',
    () async {
      final source = _Source([
        [_entry(0)],
        [_entry(1)],
      ], failure: StateError('sensitive SDK response fixture'));
      await expectLater(
        collect(source, const SummaryRequest(scope: SummaryScopeKind.all)),
        throwsA(
          isA<SummaryException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains('sensitive')),
          ),
        ),
      );
      expect(source.disposed, true);
    },
  );

  test('cancel stops a pending page immediately and disposes source', () async {
    final source = _Source([
      [_entry(0)],
      [_entry(1)],
    ])..pending = Completer<void>();
    final cancellation = SummaryCancellation();
    final operation = collector.collect(
      source: source,
      request: const SummaryRequest(scope: SummaryScopeKind.all),
      cancellation: cancellation,
      now: _now,
      onProgress: (_) => cancellation.cancel(),
    );
    await expectLater(operation, throwsA(isA<SummaryCancelledException>()));
    expect(source.disposed, true);
    source.pending!.complete();
  });

  test('cancel before reading performs no initialization', () async {
    final source = _Source([
      [_entry(0)],
    ]);
    final cancellation = SummaryCancellation()..cancel();
    await expectLater(
      collector.collect(
        source: source,
        request: const SummaryRequest(),
        cancellation: cancellation,
        now: _now,
      ),
      throwsA(isA<SummaryCancelledException>()),
    );
    expect(source.initialized.isCompleted, false);
    expect(source.disposed, true);
  });

  test(
    'invalid time amounts fail before date arithmetic or source access',
    () async {
      final source = _Source([
        [_entry(0)],
      ]);
      await expectLater(
        collect(
          source,
          const SummaryRequest(
            scope: SummaryScopeKind.hours,
            amount: 9223372036854775807,
          ),
        ),
        throwsA(
          isA<SummaryException>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(source.initialized.isCompleted, false);
      expect(source.disposed, true);
    },
  );

  test(
    'UTF-8 upload bound refuses a large message without truncating it',
    () async {
      final source = _Source([
        [_entry(0, text: 'ą' * 200)],
      ]);
      await expectLater(
        const SummaryHistoryCollector(maxSourceBytes: 300).collect(
          source: source,
          request: const SummaryRequest(amount: 1),
          now: _now,
        ),
        throwsA(
          isA<SummaryException>().having(
            (e) => e.code,
            'code',
            'source_too_large',
          ),
        ),
      );
    },
  );

  test(
    'attachments retain placeholders with an honest coverage note',
    () async {
      final result = await collect(
        _Source([
          [_entry(0, text: '[Image; contents not read]', attachment: true)],
        ]),
        const SummaryRequest(amount: 1),
      );
      expect(result.messages.length, 1);
      expect(result.omittedMessages, 0);
      expect(result.complete, false);
      expect(result.coverageNote, contains('contents were not read'));
    },
  );

  test('no readable messages fails before an upload can be created', () async {
    await expectLater(
      collect(
        _Source([
          [_entry(0, omission: 'encrypted')],
        ]),
        const SummaryRequest(amount: 1),
      ),
      throwsA(
        isA<SummaryException>().having((e) => e.code, 'code', 'no_messages'),
      ),
    );
  });

  group('Matrix projection', () {
    late Room room;
    late Timeline timeline;

    setUp(() {
      room = Room(id: '!fixture:example.invalid', client: _Client());
      timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: []),
      );
    });
    tearDown(() => timeline.cancelSubscriptions());

    Event event(
      Map<String, dynamic> content, {
      String type = EventTypes.Message,
      String id = r'$fixture',
      Map<String, dynamic>? unsigned,
    }) => Event(
      room: room,
      type: type,
      content: content,
      eventId: id,
      senderId: '@contact:example.invalid',
      originServerTs: _now,
      unsigned: unsigned,
    );
    SummaryHistoryEntry? project(
      Event source, {
      String? transcript,
      bool hidden = false,
    }) => MatrixSummaryHistorySource.project(
      source,
      timeline: timeline,
      sender: 'Fixture participant',
      transcript: transcript,
      hidden: hidden,
    );

    test('edited content replaces original without counting edit events', () {
      final original = event({'msgtype': 'm.text', 'body': 'Old fixture text'});
      final edit = event({
        'msgtype': 'm.text',
        'body': '* New fixture text',
        'm.new_content': {'msgtype': 'm.text', 'body': 'New fixture text'},
        'm.relates_to': {'rel_type': 'm.replace', 'event_id': original.eventId},
      }, id: r'$edit');
      timeline.addAggregatedEvent(edit);
      expect(project(original)?.message?.text, 'New fixture text');
      expect(project(edit), null);
    });

    test('reply fallback is excluded from the model input', () {
      final source = event({
        'msgtype': 'm.text',
        'body':
            '> <@fixture:example.invalid> Quoted old content\n\nActual new reply',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$quoted'},
        },
      });
      expect(project(source)?.message?.text, 'Actual new reply');
    });

    test('a media filename is a placeholder rather than invented content', () {
      final source = event({
        'msgtype': 'm.image',
        'body': 'private-fixture.jpg',
      });
      final projected = project(source)!;
      expect(projected.message!.text, '[Image attachment; contents not read]');
      expect(projected.message!.text, isNot(contains('private-fixture.jpg')));
      expect(projected.unreadAttachment, true);
    });

    test('explicit media caption and existing transcript are retained', () {
      final source = event({
        'msgtype': 'm.audio',
        'body': 'A useful caption',
        'filename': 'fixture.ogg',
      });
      final projected = project(
        source,
        transcript: 'An existing fictional transcript',
      )!;
      expect(projected.message!.text, contains('existing transcript'));
      expect(
        projected.message!.text,
        contains('An existing fictional transcript'),
      );
      expect(projected.message!.text, contains('Caption: A useful caption'));
      expect(projected.unreadAttachment, false);
    });

    test(
      'disappearing and protected content cannot leak through transcripts',
      () {
        for (final protection in [
          {
            'com.beeper.disappearing_timer': {
              'type': 'after_send',
              'timer': 60000,
            },
          },
          {'com.beeper.view_once': true},
          {'protected_content': true},
        ]) {
          final source = event({
            'msgtype': 'm.audio',
            'body': 'fixture',
            ...protection,
          });
          final projected = project(
            source,
            transcript: 'Must never be uploaded',
          )!;
          expect(projected.message, null);
          expect(projected.omission, 'protected or disappearing');
        }
      },
    );

    test('hidden messages and non-message state cannot be included', () {
      expect(
        project(event({'msgtype': 'm.text', 'body': 'hidden'}), hidden: true),
        null,
      );
      expect(
        project(event({'name': 'Group'}, type: EventTypes.RoomName)),
        null,
      );
    });

    test('an edit cannot remove the original protective metadata', () {
      final original = event({
        'msgtype': 'm.audio',
        'body': 'fixture',
        'com.beeper.view_once': true,
      });
      timeline.addAggregatedEvent(
        event({
          'msgtype': 'm.audio',
          'body': '* fixture',
          'm.new_content': {'msgtype': 'm.audio', 'body': 'fixture'},
          'm.relates_to': {
            'rel_type': 'm.replace',
            'event_id': original.eventId,
          },
        }, id: r'$unprotected-edit'),
      );
      expect(
        project(original, transcript: 'Must not be included')?.message,
        null,
      );
      expect(project(original)?.omission, 'protected or disappearing');
    });

    test('unavailable bridge messages retain their last-N slot', () {
      final source = event({
        'msgtype': 'm.notice',
        'body': 'Waiting for this message',
        'fi.mau.whatsapp.undecryptable': true,
      });
      expect(project(source)?.omission, 'unavailable');
    });

    test('encrypted or deleted messages remain omitted slots', () {
      expect(
        project(
          event({'ciphertext': 'fixture'}, type: EventTypes.Encrypted),
        )!.omission,
        'encrypted',
      );
      final deleted = event(
        {},
        unsigned: {
          'redacted_because': {
            'type': EventTypes.Redaction,
            'event_id': r'$redaction',
            'sender': '@contact:example.invalid',
            'origin_server_ts': _now.millisecondsSinceEpoch,
            'content': {'redacts': r'$fixture'},
          },
        },
      );
      expect(project(deleted)!.omission, 'deleted');
    });

    test('poll questions are represented without inferring results', () {
      final source = event({
        'org.matrix.msc3381.poll.start': {
          'question': {'org.matrix.msc1767.text': 'Fictional decision?'},
          'answers': [
            {'id': 'yes', 'org.matrix.msc1767.text': 'Yes'},
          ],
        },
      }, type: PollEventContent.startType);
      expect(project(source)?.message?.text, '[Poll] Fictional decision?');
    });
  });
}
