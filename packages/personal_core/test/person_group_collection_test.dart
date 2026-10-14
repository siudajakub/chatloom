// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> group(String id, {String account = 'fixture'}) => {
  'id': id,
  'name': 'Fixture',
  'revision': 0,
  'defaultRoomId': '$id-a',
  'members': [
    {'accountId': account, 'roomId': '$id-a', 'network': 'telegram'},
    {'accountId': account, 'roomId': '$id-b', 'network': 'whatsapp'},
  ],
};

void main() {
  test(
    'malformed saved group does not hide valid groups or mutate metadata',
    () {
      final values = {
        'person:one': group('one'),
        'person:bad': <String, dynamic>{'members': 'invalid'},
        'org:room': <String, dynamic>{'private': true},
      };
      final before = jsonEncode(values);
      final result = parsePersonGroups(values, accountId: 'fixture');
      expect(result.groups.map((group) => group.id), ['one']);
      expect(result.invalidCount, 1);
      expect(jsonEncode(values), before);
    },
  );
  test('wrong account or entity key cannot become a routing group', () {
    final values = {
      'person:other': group('other', account: 'foreign'),
      'person:mismatch': group('one'),
    };
    final result = parsePersonGroups(values, accountId: 'fixture');
    expect(result.groups, isEmpty);
    expect(result.invalidCount, 2);
  });
  test('duplicate and cross-account members are preserved but excluded', () {
    final duplicate = group('duplicate');
    (duplicate['members'] as List)[1] = (duplicate['members'] as List)[0];
    final cross = group('cross');
    ((cross['members'] as List)[1] as Map)['accountId'] = 'foreign';
    final values = {'person:duplicate': duplicate, 'person:cross': cross};
    final before = jsonEncode(values);
    final result = parsePersonGroups(values, accountId: 'fixture');
    expect(result.invalidCount, 2);
    expect(jsonEncode(values), before);
  });
  test('missing current account cannot expose groups', () {
    final result = parsePersonGroups({
      'person:one': group('one'),
    }, accountId: null);
    expect(result.groups, isEmpty);
    expect(result.invalidCount, 1);
  });
}
