// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional identifiers only.
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

const _account = '@fixture:example.invalid';
ConversationRef _ref(String room, [String network = 'whatsapp']) =>
    ConversationRef(accountId: _account, roomId: room, network: network);

PersonGroup _group(String id, List<ConversationRef> members, {int rev = 0}) =>
    PersonGroup(
      id: id,
      name: 'Fixture $id',
      members: members,
      defaultRoomId: members.first.roomId,
      revision: rev,
    );

void main() {
  final wa = _ref('!wa');
  final tg = _ref('!tg', 'telegram');
  final sig = _ref('!sig', 'signal');
  final ig = _ref('!ig', 'instagram');

  group('resolvePersonGroups', () {
    PersonGroupResolution resolve(
      List<PersonGroup> groups, {
      Set<String> inactive = const {},
      Set<String> unsafe = const {},
    }) => resolvePersonGroups(
      groups,
      (m) => unsafe.contains(m.roomId)
          ? PersonMemberState.unsafe
          : inactive.contains(m.roomId)
          ? PersonMemberState.inactive
          : PersonMemberState.active,
    );

    test('a left or deleted chat keeps the person with the others', () {
      final person = _group('p', [wa, tg]);
      final result = resolve([person], inactive: {'!tg'});
      expect(result.valid.single.id, 'p');
      expect(result.ownerOf('!wa')?.id, 'p');
      expect(result.ownerOf('!tg'), isNull);
      expect(result.statusOf(person, tg), PersonSourceStatus.inactive);
      expect(result.statusOf(person, wa), PersonSourceStatus.active);
    });

    test('no active chat: not shown; a group chat member: never merged', () {
      final gone = _group('gone', [wa, tg]);
      expect(resolve([gone], inactive: {'!wa', '!tg'}).valid, isEmpty);
      final grouped = _group('g', [wa, tg]);
      final result = resolve([grouped], unsafe: {'!tg'});
      expect(result.valid, isEmpty);
      expect(result.unsafe.single.id, 'g');
      expect(result.ownerOf('!wa'), isNull);
    });

    test('overlap: the larger person wins, deterministically', () {
      // A failed absorb: the extended person and the absorbed one.
      final extended = _group('zz', [wa, tg, sig, ig]);
      final absorbed = _group('aa', [sig, ig]);
      for (final order in [
        [extended, absorbed],
        [absorbed, extended],
      ]) {
        final result = resolve(order);
        expect(result.valid.map((g) => g.id), ['zz']);
        expect(result.covered.single.id, 'aa');
        expect(result.ownerOf('!sig')?.id, 'zz');
        expect(result.statusOf(absorbed, sig), PersonSourceStatus.elsewhere);
      }
    });

    test('overlap of equal persons: the smaller id keeps the chat', () {
      // Two devices merged the same chat into two persons.
      final pixel = _group('b-person', [wa, tg]);
      final mac = _group('a-person', [wa, sig]);
      for (final order in [
        [pixel, mac],
        [mac, pixel],
      ]) {
        final result = resolve(order);
        expect(result.ownerOf('!wa')?.id, 'a-person');
        expect(result.ownerOf('!tg')?.id, 'b-person');
        expect(result.valid.map((g) => g.id).toSet(), {
          'a-person',
          'b-person',
        });
        expect(result.overlapsOf(pixel).single.id, 'a-person');
        expect(result.overlapsOf(mac), isEmpty);
      }
    });
  });

  group('PersonGroupEdits', () {
    test('removing a chat moves the default and bumps the revision', () {
      final person = _group('p', [wa, tg, sig], rev: 4);
      final next = person.withoutSource('!wa', preferredDefault: '!sig')!;
      expect(next.members, [tg, sig]);
      expect(next.defaultRoomId, '!sig');
      expect(next.revision, 5);
      expect(person.withoutSource('!tg')!.defaultRoomId, '!wa');
      expect(_group('two', [wa, tg]).withoutSource('!tg'), isNull);
      expect(() => person.withoutSource('!other'), throwsArgumentError);
    });

    test('adding, default and name', () {
      final person = _group('p', [wa, tg]);
      expect(person.withSources([tg]), same(person));
      final added = person.withSources([sig, ig]);
      expect(added.members, [wa, tg, sig, ig]);
      expect(added.withDefaultSource('!ig').defaultRoomId, '!ig');
      expect(() => person.withDefaultSource('!ig'), throwsArgumentError);
      expect(person.withName('  New  ').name, 'New');
      expect(() => person.withName(' '), throwsArgumentError);
    });
  });

  group('MergedSendRouter with person preferences', () {
    final person = PersonGroup(
      id: 'p',
      name: 'Fixture',
      members: [wa, tg],
      defaultRoomId: '!wa',
    );
    final now = DateTime.utc(2026, 10, 21, 12);
    MergedEvent<Object?> incoming(ConversationRef ref) => MergedEvent(
      source: SourceEventRef(conversation: ref, eventId: r'$e'),
      timestamp: now.subtract(const Duration(minutes: 5)),
      isOutgoing: false,
      value: null,
    );

    test('fixed routing ignores where they last wrote', () {
      expect(
        MergedSendRouter.resolve(
          group: person,
          now: now,
          recentEvent: incoming(tg),
        ).conversation,
        tg,
      );
      expect(
        MergedSendRouter.resolve(
          group: person,
          now: now,
          recentEvent: incoming(tg),
          automatic: false,
        ).conversation,
        wa,
      );
      // A per-message choice and a reply still win.
      expect(
        MergedSendRouter.resolve(
          group: person,
          now: now,
          automatic: false,
          override: tg,
        ).conversation,
        tg,
      );
    });

    test('never routes automatically to an unavailable chat', () {
      expect(
        MergedSendRouter.resolve(
          group: person,
          now: now,
          recentEvent: incoming(tg),
          available: {wa},
        ).conversation,
        wa,
      );
      expect(
        MergedSendRouter.resolve(
          group: person,
          now: now,
          available: {tg},
        ).conversation,
        tg,
      );
    });
  });

  group('PersonPreferences', () {
    test('round trip keeps unknown fields of newer builds', () {
      final prefs = PersonPreferences.fromJson({
        'routing': 'fixed',
        'nameRoomId': '!tg',
        'future': 1,
      });
      expect(prefs.routing, PersonRouting.fixed);
      expect(prefs.nameRoomId, '!tg');
      final json = prefs
          .copyWith(routing: PersonRouting.automatic, nameRoomId: () => null)
          .toJson({'future': 1});
      expect(json, {'future': 1, 'routing': 'automatic', 'nameRoomId': null});
      expect(PersonPreferences.fromJson(null).routing, PersonRouting.automatic);
      expect(personPreferencesKey('p'), 'person-prefs:p');
      // Never parsed as a person group.
      expect(
        parsePersonGroups({
          personPreferencesKey('p'): json,
        }, accountId: _account).invalidCount,
        0,
      );
    });
  });

  group('mergeSuggestions', () {
    MergeSuggestionCandidate c(
      String id,
      String network,
      String name, {
      List<String> phones = const [],
      int minute = 0,
    }) => MergeSuggestionCandidate(
      entityId: id,
      networks: [network],
      names: [name],
      phones: phones,
      lastActivity: DateTime.utc(2026, 10, 21, 12, minute),
    );

    test('same name on different networks; same network never', () {
      final result = mergeSuggestions([
        c('!a', 'whatsapp', 'anna nowak', minute: 1),
        c('!b', 'telegram', 'anna maria nowak', minute: 2),
        c('!c', 'whatsapp', 'anna nowak'),
        c('!d', 'signal', 'jo'),
        c('!e', 'telegram', 'jo'),
      ]);
      final pairs = result
          .map((s) => ([s.first.entityId, s.second.entityId]..sort()).join())
          .toList();
      expect(pairs, contains('!a!b'));
      expect(pairs, contains('!b!c'));
      expect(pairs, isNot(contains('!a!c'))); // same network
      expect(pairs, isNot(contains('!d!e'))); // too short
      expect(result.first.reason, MergeSuggestionReason.name);
    });

    test('phone match, dismissal and order', () {
      final first = c(
        '!a',
        'whatsapp',
        'mum',
        phones: ['48600100200'],
        minute: 9,
      );
      final second = c('!b', 'signal', 'mama', phones: ['48600100200']);
      final result = mergeSuggestions([first, second]);
      expect(result.single.reason, MergeSuggestionReason.phone);
      expect(
        result.single.dismissKey,
        mergeSuggestionDismissKey('!b', '!a'),
      );
      expect(result.single.dismissKey, startsWith('merge-dismissed:'));
      expect(result.single.dismissKey, isNot(contains('!')));
      expect(
        mergeSuggestions([
          first,
          second,
        ], dismissed: {result.single.dismissKey}),
        isEmpty,
      );
    });
  });
}
