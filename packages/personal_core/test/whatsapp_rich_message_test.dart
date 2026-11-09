// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> interactive([Map<String, dynamic> overrides = const {}]) =>
    {
      WhatsAppInteractiveContent.contentKey: {
        'schema_version': 1,
        'body': 'An article',
        'formatted_body': '<b>An article</b>',
        'actions': [
          {
            'kind': 'url',
            'label': 'View post',
            'url': 'https://example.invalid/post',
          },
        ],
        ...overrides,
      },
    };

Map<String, dynamic> poll([Map<String, dynamic> overrides = const {}]) => {
  'msgtype': 'm.text',
  'body': 'A text fallback',
  WhatsAppPollSnapshot.startKey: {
    'kind': 'org.matrix.msc3381.poll.disclosed',
    'max_selections': 1,
    'question': {WhatsAppPollSnapshot.textKey: 'Which day?'},
    'answers': [
      {'id': 'one', WhatsAppPollSnapshot.textKey: 'Monday'},
      {'id': 'two', WhatsAppPollSnapshot.textKey: 'Tuesday'},
    ],
    ...overrides,
  },
};

Map<String, dynamic> relation({
  String sender = '@voter:example.invalid',
  String id = r'$vote',
  int time = 1,
  List<String> answers = const ['one'],
}) => {
  'type': WhatsAppPollSnapshot.responseKey,
  'sender': sender,
  'event_id': id,
  'origin_server_ts': time,
  'content': {
    'm.relates_to': {'rel_type': 'm.reference', 'event_id': r'$poll'},
    WhatsAppPollSnapshot.responseKey: {'answers': answers},
  },
};

void main() {
  group('WhatsApp interactive v1', () {
    test('reads the bridge contract without changing the text fallback', () {
      final content = interactive();
      final parsed = WhatsAppInteractiveContent.fromContent(content)!;
      expect(parsed.body, 'An article');
      expect(parsed.formattedBody, '<b>An article</b>');
      expect(parsed.actions.single.label, 'View post');
      expect(parsed.actions.single.url, 'https://example.invalid/post');
      expect(content, interactive());
      expect(() => parsed.actions.clear(), throwsUnsupportedError);
    });

    for (final url in [
      'javascript:alert(1)',
      'data:text/html,hello',
      'file:///tmp/example',
      'https:///missing',
      'https://',
      'https://user:password@example.invalid',
      'https://@example.invalid',
      'https://example.invalid/\npath',
      'https://example.invalid/%0Apath',
      'https://example.invalid/%00path',
      'https://example.invalid/%7Fpath',
      ' https://example.invalid',
      'https://example.invalid/with space',
      'https://example.invalid/%zz',
      r'https://example.invalid\path',
    ]) {
      test('refuses an unsafe or malformed URL: ${jsonEncode(url)}', () {
        expect(WhatsAppUrlAction.isValidUrl(url), isFalse);
      });
    }

    test('keeps a valid URL exact, including signed trailing punctuation', () {
      const url = 'https://example.invalid/path_(one)?signature=A%2FB#part';
      final parsed = WhatsAppInteractiveContent.fromContent(
        interactive({
          'actions': [
            {'kind': 'url', 'label': 'Open', 'url': url},
          ],
        }),
      )!;
      expect(parsed.actions.single.url, url);
      expect(WhatsAppUrlAction.isValidUrl('http://example.invalid'), isTrue);
      expect(
        WhatsAppUrlAction.isValidUrl(
          'https://example.org/a%20b?q=hello%20world',
        ),
        isTrue,
      );
    });

    for (final overrides in <Map<String, dynamic>>[
      {'schema_version': 2},
      {'schema_version': 1.0},
      {'body': 1},
      {'formatted_body': []},
      {'actions': []},
      {'actions': 'not an array'},
      {
        'actions': [
          {'kind': 'reply', 'label': 'Yes', 'id': 'opaque'},
        ],
      },
      {
        'actions': [
          {'kind': 'url', 'label': '', 'url': 'https://example.invalid'},
        ],
      },
      {
        'actions': [
          {
            'kind': 'url',
            'label': 'x' * 1025,
            'url': 'https://example.invalid',
          },
        ],
      },
      {
        'actions': [
          {
            'kind': 'url',
            'label': 'Open',
            'url': 'https://example.invalid/${'x' * 8192}',
          },
        ],
      },
      {
        'unexpected': {'deep': <dynamic>[]},
      },
    ]) {
      test('fails closed for malformed contract ${overrides.keys}', () {
        expect(
          WhatsAppInteractiveContent.fromContent(interactive(overrides)),
          isNull,
        );
      });
    }

    test('enforces action count before serialization', () {
      final actions = [
        for (var i = 0; i < 21; i++)
          {
            'kind': 'url',
            'label': 'Open $i',
            'url': 'https://example.invalid/$i',
          },
      ];
      expect(
        WhatsAppInteractiveContent.fromContent(
          interactive({'actions': actions}),
        ),
        isNull,
      );
      actions.removeLast();
      expect(
        WhatsAppInteractiveContent.fromContent(
          interactive({'actions': actions}),
        )!.actions,
        hasLength(20),
      );
    });

    test('uses the full extension UTF-8 size, not character count', () {
      final empty = interactive({'body': ''});
      final raw = empty[WhatsAppInteractiveContent.contentKey] as Map;
      final overhead = utf8.encode(jsonEncode(raw)).length;
      expect(
        WhatsAppInteractiveContent.fromContent(
          interactive({
            'body': 'x' * (WhatsAppInteractiveContent.maxBytes - overhead),
          }),
        ),
        isNotNull,
      );
      expect(
        WhatsAppInteractiveContent.fromContent(
          interactive({
            'body': 'x' * (WhatsAppInteractiveContent.maxBytes - overhead + 1),
          }),
        ),
        isNull,
      );
      expect(
        WhatsAppInteractiveContent.fromContent(
          interactive({'body': 'ą' * 40000}),
        ),
        isNull,
      );
    });
  });

  group('WhatsApp nested poll', () {
    test('needs neither an extensible event type nor top-level text', () {
      final snapshot = WhatsAppPollSnapshot.fromContent(poll())!;
      expect(snapshot.question, 'Which day?');
      expect(snapshot.maxSelections, 1);
      expect(snapshot.options.map((option) => option.label), [
        'Monday',
        'Tuesday',
      ]);
      expect(snapshot.options.map((option) => option.id), ['one', 'two']);
    });

    for (final overrides in <Map<String, dynamic>>[
      {'kind': 'org.matrix.msc3381.poll.undisclosed'},
      {'kind': 'unknown'},
      {'kind': null},
      {'max_selections': 0},
      {'max_selections': 3},
      {'max_selections': 1.0},
      {'question': {}},
      {
        'question': {WhatsAppPollSnapshot.textKey: 'x' * 1025},
      },
      {'answers': []},
      {
        'answers': [
          {'id': 'one', WhatsAppPollSnapshot.textKey: 'Only'},
        ],
      },
      {
        'answers': [
          {'id': 'one', WhatsAppPollSnapshot.textKey: 'Monday'},
          {'id': 'one', WhatsAppPollSnapshot.textKey: 'Tuesday'},
        ],
      },
      {
        'answers': [
          {'id': 'one', WhatsAppPollSnapshot.textKey: 'Monday'},
          {'id': 'two', WhatsAppPollSnapshot.textKey: ' monday '},
        ],
      },
      {
        'answers': [
          {'id': 'one', WhatsAppPollSnapshot.textKey: 'x' * 101},
          {'id': 'two', WhatsAppPollSnapshot.textKey: 'Tuesday'},
        ],
      },
    ]) {
      test('refuses invalid or hidden poll ${overrides.keys}', () {
        expect(WhatsAppPollSnapshot.fromContent(poll(overrides)), isNull);
      });
    }

    test('accepts twelve options of one hundred Unicode characters', () {
      final answers = [
        for (var i = 0; i < 12; i++)
          {
            'id': 'option-$i',
            WhatsAppPollSnapshot.textKey:
                '${'😀' * 98}${i.toString().padLeft(2, '0')}',
          },
      ];
      expect(
        WhatsAppPollSnapshot.fromContent(
          poll({'answers': answers, 'max_selections': 12}),
        )!.options,
        hasLength(12),
      );
      answers.add({'id': 'thirteen', WhatsAppPollSnapshot.textKey: 'Extra'});
      expect(
        WhatsAppPollSnapshot.fromContent(poll({'answers': answers})),
        isNull,
      );
    });
  });

  group('available poll responses', () {
    final snapshot = WhatsAppPollSnapshot.fromContent(poll())!;
    WhatsAppPollVote vote(Map<String, dynamic> event) =>
        WhatsAppPollVote.fromRelation(event, expectedPollEventId: r'$poll')!;

    test('latest response wins regardless of relation ordering', () {
      final first = vote(relation());
      final second = vote(relation(id: r'$second', time: 2, answers: ['two']));
      final other = vote(relation(sender: '@other:example.invalid'));
      for (final votes in [
        [first, second, other],
        [other, second, first],
      ]) {
        expect(snapshot.votesBySender(votes), {
          '@voter:example.invalid': {'two'},
          '@other:example.invalid': {'one'},
        });
      }
    });

    test(
      'empty, unknown and excessive latest answers never resurrect a vote',
      () {
        for (final answers in <List<String>>[
          [],
          ['unknown'],
          ['one', 'two'],
          ['one', 'one'],
        ]) {
          expect(
            snapshot.votesBySender([
              vote(relation()),
              vote(relation(id: r'$latest', time: 2, answers: answers)),
            ])['@voter:example.invalid'],
            isEmpty,
          );
        }
      },
    );

    test('redacted latest event remains a tombstone even without answers', () {
      final latest = relation(id: r'$latest', time: 2);
      latest['unsigned'] = {
        'redacted_because': {'type': 'm.room.redaction'},
      };
      (latest['content'] as Map).remove(WhatsAppPollSnapshot.responseKey);
      final tombstone = vote(latest);
      expect(tombstone.redacted, isTrue);
      expect(
        snapshot.votesBySender([
          vote(relation()),
          tombstone,
        ])['@voter:example.invalid'],
        isEmpty,
      );
      final original = vote(relation(id: r'$latest', time: 2));
      for (final pair in [
        [tombstone, original],
        [original, tombstone],
      ]) {
        expect(snapshot.votesBySender(pair)['@voter:example.invalid'], isEmpty);
      }
    });

    test('uses event ID as a deterministic equal-timestamp tie breaker', () {
      final a = vote(relation(id: r'$a', answers: ['one']));
      final z = vote(relation(id: r'$z', answers: ['two']));
      expect(snapshot.votesBySender([a, z]), snapshot.votesBySender([z, a]));
      expect(snapshot.votesBySender([a, z])['@voter:example.invalid'], {'two'});
    });

    test('rejects unrelated, malformed and wrong-type events', () {
      for (final event in [
        {...relation(), 'type': 'm.room.message'},
        {...relation(), 'origin_server_ts': -1},
        {...relation(), 'sender': ''},
        {...relation(), 'content': {}},
      ]) {
        expect(
          WhatsAppPollVote.fromRelation(event, expectedPollEventId: r'$poll'),
          isNull,
        );
      }
      expect(
        WhatsAppPollVote.fromRelation(
          relation(),
          expectedPollEventId: r'$other',
        ),
        isNull,
      );
    });
  });
}
