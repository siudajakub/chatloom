// SPDX-License-Identifier: AGPL-3.0-or-later
// Long transcripts travel as a preview result plus text slices (CB-01).
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

class _Store {
  final data = <String, Map<String, dynamic>>{};
  final writes = <String>[];
  Future<Map<String, dynamic>?> read(String key) async => data[key] == null
      ? null
      : Map<String, dynamic>.from(jsonDecode(jsonEncode(data[key])) as Map);
  Future<void> write(String key, Map<String, dynamic> value) async {
    writes.add(key);
    data[key] = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  }
}

const _conversation = ConversationRef(
  accountId: '@synthetic:example.invalid',
  roomId: '!synthetic:example.invalid',
);
const _source = SourceEventRef(
  conversation: _conversation,
  eventId: r'$synthetic',
);
final _at = DateTime.utc(2026, 10, 21);
const _entity = 'transcript:synthetic';

/// About 45 minutes of Polish speech (~1000 characters a minute), with
/// diacritics, quotes, newlines and a few emoji.
String _longTranscript({int minutes = 45}) {
  final line = StringBuffer();
  var minute = 0;
  while (line.length < minutes * 1000) {
    line.write(
      'Minuta ${minute++}: zażółć gęślą jaźń, "cytat" i \\ ukośnik 🎙️ — '
      'dalej mówimy o planach na jutro, o pogodzie i o zakupach.\n',
    );
  }
  return line.toString();
}

int _encodedBytes(String text) => utf8.encode(jsonEncode(text)).length - 2;

PersonalOperation _op(String id, String kind, Map<String, dynamic> payload) =>
    PersonalOperation(
      opId: id,
      kind: kind,
      entityId: _entity,
      baseRevision: payload['revision'] as int? ?? 0,
      createdAt: _at,
      payload: payload,
    );

Map<String, dynamic> _job(int revision, String state, {Object? text}) => {
  'id': _entity,
  'source': _source.toJson(),
  'state': state,
  'language': null,
  'text': text,
  'model': 'gpt-transcribe',
  'durationSeconds': 2700.0,
  'estimatedCostUsd': 0.2,
  'errorCode': null,
  'kind': 'transcript',
  'revision': revision,
  'acceptedOpId': 'request',
};

/// The done result and slices exactly as the worker publishes them.
(PersonalOperation, List<PersonalOperation>) _published(
  String text, {
  int revision = 3,
  String prefix = 'r',
}) {
  final publication = TranscriptTextPublication.of(text)!;
  return (
    _op('$prefix-done', 'transcript.result', {
      ..._job(revision, 'done', text: publication.preview),
      'textParts': publication.meta.toJson(),
    }),
    [
      for (var i = 0; i < publication.parts.length; i++)
        _op(
          '$prefix-part-$i',
          transcriptTextPartKind,
          publication.partPayload(_entity, revision, i),
        ),
    ],
  );
}

PersonalReplica _replica(_Store store) => PersonalReplica(
  read: store.read,
  write: store.write,
  newOperationId: () => 'local-op',
  clock: () => _at,
)..restore(store.data);

void main() {
  group('splitting', () {
    test('slices stay within the budget and join to the text', () {
      final text = _longTranscript();
      final parts = splitTranscriptText(text);
      expect(parts.length, greaterThanOrEqualTo(2));
      expect(parts.join(), text);
      for (final part in parts) {
        expect(
          _encodedBytes(part),
          lessThanOrEqualTo(transcriptTextEventBudget),
        );
      }
    });

    test('surrogate pairs and escapes are never split or under-counted', () {
      final text = List.filled(5000, '🎙️"\\\n\u0001ą').join();
      final parts = splitTranscriptText(text, budget: 101);
      expect(parts.join(), text);
      for (final part in parts) {
        expect(_encodedBytes(part), lessThanOrEqualTo(101));
        expect(
          transcriptJsonBytes(part),
          greaterThanOrEqualTo(_encodedBytes(part)),
        );
        // A slice never starts with a low surrogate.
        final first = part.codeUnitAt(0);
        expect(first >= 0xdc00 && first <= 0xdfff, isFalse);
      }
    });

    test('short text is published as before, in one event', () {
      expect(TranscriptTextPublication.of('krótki tekst'), isNull);
      expect(TranscriptTextPublication.of(null), isNull);
      expect(splitTranscriptText(''), ['']);
    });

    test('a 45-minute transcript: preview and slices fit one event each', () {
      final text = _longTranscript();
      expect(utf8.encode(text).length, greaterThan(45000));
      final publication = TranscriptTextPublication.of(text)!;
      expect(publication.meta.count, publication.parts.length);
      expect(publication.meta.length, text.length);
      expect(publication.meta.matches(text), isTrue);
      expect(publication.preview, endsWith(transcriptPreviewSuffix));
      expect(
        _encodedBytes(publication.preview),
        lessThanOrEqualTo(transcriptTextEventBudget),
      );
      expect(text.startsWith(publication.preview.substring(0, 1000)), isTrue);
      for (var i = 0; i < publication.parts.length; i++) {
        final payload = publication.partPayload(_entity, 3, i);
        final part = TranscriptTextPart.tryParse(payload)!;
        expect(part.index, i);
        expect(part.count, publication.parts.length);
        // Whole operation, as the SDK would encode it before encryption.
        final event = utf8.encode(
          jsonEncode(_op('p$i', transcriptTextPartKind, payload).toJson()),
        );
        expect(event.length, lessThan(30000));
      }
      expect(
        assembleTranscriptText(publication.meta, {
          for (var i = 0; i < publication.parts.length; i++)
            i: publication.parts[i],
        }),
        text,
      );
    });

    test('missing, extra or altered slices never assemble', () {
      final publication = TranscriptTextPublication.of(_longTranscript())!;
      final slices = {
        for (var i = 0; i < publication.parts.length; i++)
          i: publication.parts[i],
      };
      expect(
        assembleTranscriptText(publication.meta, {...slices}..remove(1)),
        isNull,
      );
      expect(
        assembleTranscriptText(publication.meta, {...slices, 0: 'forged'}),
        isNull,
      );
      expect(TranscriptTextParts.tryParse({'count': 2}), isNull);
      expect(
        TranscriptTextPart.tryParse({
          ...publication.partPayload(_entity, 3, 0),
          'text': null,
        }),
        isNull,
        reason: 'An erased slice carries nothing',
      );
    });
  });

  group('replica', () {
    test(
      'shows the preview, then the whole text once every slice arrived',
      () async {
        final text = _longTranscript();
        final store = _Store();
        final r = _replica(store);
        final (done, parts) = _published(text);
        await r.acceptResult(done);
        expect(r.transcripts[_entity]!.state, JobState.done);
        expect(r.transcripts[_entity]!.text, endsWith(transcriptPreviewSuffix));
        for (final part in parts.take(parts.length - 1)) {
          await r.acceptResult(part);
        }
        expect(r.transcripts[_entity]!.text, endsWith(transcriptPreviewSuffix));
        await r.acceptResult(parts.last);
        expect(r.transcripts[_entity]!.text, text);
        expect(r.revisions[_entity], 3);
        // Slices are dropped once assembled; the whole text survives restarts.
        expect(
          store.data['replica:$_entity']!.containsKey('transcriptText'),
          isFalse,
        );
        expect(_replica(store).transcripts[_entity]!.text, text);
      },
    );

    test(
      'slices that arrive before the result are kept until it does',
      () async {
        final text = _longTranscript(minutes: 120);
        final r = _replica(_Store());
        final (done, parts) = _published(text);
        for (final part in parts.reversed) {
          await r.acceptResult(part);
        }
        expect(r.transcripts[_entity], isNull);
        await r.acceptResult(done);
        expect(r.transcripts[_entity]!.text, text);
      },
    );

    test('applying the result again keeps the assembled text', () async {
      final text = _longTranscript();
      final store = _Store();
      final r = _replica(store);
      final (done, parts) = _published(text);
      await r.acceptResult(done);
      for (final part in parts) {
        await r.acceptResult(part);
      }
      // The same result under another id (a replay after its seen marker
      // aged out) must not fall back to the preview.
      await r.acceptResult(
        _op('r-done-again', 'transcript.result', done.payload),
      );
      expect(r.transcripts[_entity]!.text, text);
    });

    test('an erased transcript never comes back from stray slices', () async {
      final text = _longTranscript();
      final r = _replica(_Store());
      final (done, parts) = _published(text);
      await r.acceptResult(done);
      await r.acceptResult(parts.first);
      await r.acceptResult(
        _op('tombstone', 'transcript.result', {
          ..._job(4, 'cancelled', text: null),
          'errorCode': 'source_redacted',
        }),
      );
      for (final part in parts) {
        await r.acceptResult(part);
      }
      expect(r.transcripts[_entity]!.text, isNull);
      expect(r.transcripts[_entity]!.state, JobState.cancelled);
    });

    test('a new run replaces an older text and ignores its slices', () async {
      final r = _replica(_Store());
      final (oldDone, oldParts) = _published(_longTranscript(), prefix: 'old');
      await r.acceptResult(oldDone);
      final newer = '${_longTranscript(minutes: 50)} nowy';
      final (newDone, newParts) = _published(newer, revision: 6, prefix: 'new');
      await r.acceptResult(newDone);
      for (final part in [...oldParts, ...newParts]) {
        await r.acceptResult(part);
      }
      expect(r.transcripts[_entity]!.text, newer);
      // A short whole text later needs no slices.
      await r.acceptResult(
        _op('short', 'transcript.result', _job(8, 'done', text: 'krótko')),
      );
      expect(r.transcripts[_entity]!.text, 'krótko');
    });
  });

  group('seen markers', () {
    test('stay bounded and still deduplicate recent results', () async {
      final store = _Store();
      final r = _replica(store);
      for (var i = 0; i < 600; i++) {
        await r.acceptResult(
          PersonalOperation(
            opId: 'result-$i',
            kind: 'reminder.result',
            entityId: 'reminder:$i',
            baseRevision: 1,
            createdAt: _at,
            payload: {'revision': 1, 'state': 'queued'},
          ),
        );
      }
      final markers = store.data.keys.where((k) => k.startsWith('seen:'));
      expect(markers.length, lessThanOrEqualTo(PersonalReplica.seenBuckets));
      // A restarted replica skips a recent result without touching its record.
      final restarted = _replica(store);
      store.writes.clear();
      await restarted.acceptResult(
        PersonalOperation(
          opId: 'result-599',
          kind: 'reminder.result',
          entityId: 'reminder:599',
          baseRevision: 1,
          createdAt: _at,
          payload: {'revision': 1, 'state': 'done'},
        ),
      );
      expect(store.writes, isEmpty);
      expect(restarted.reminders['reminder:599']!['state'], 'queued');
    });

    test('markers written before buckets are still honoured', () async {
      final store = _Store()..data['seen:legacy'] = {'seen': true};
      final r = _replica(store);
      await r.acceptResult(
        PersonalOperation(
          opId: 'legacy',
          kind: 'reminder.result',
          entityId: 'reminder:legacy',
          baseRevision: 1,
          createdAt: _at,
          payload: {'revision': 1, 'state': 'done'},
        ),
      );
      expect(r.reminders, isEmpty);
    });
  });
}
