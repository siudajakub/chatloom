// SPDX-License-Identifier: AGPL-3.0-or-later
// Every replica commit names its entity before the change notification, so
// the app can refresh only what a change touched (a draft keystroke must not
// rebuild the whole inbox).
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

void main() {
  test('commits report their entity before onChanged', () async {
    final data = <String, Map<String, dynamic>>{};
    final events = <String>[];
    var ids = 0;
    final replica = PersonalReplica(
      read: (key) async => data[key],
      write: (key, value) async => data[key] = value,
      newOperationId: () => 'fixture-op-${ids++}',
      clock: () => DateTime.utc(2026, 11, 26),
      onEntityChanged: (entity) => events.add('entity:$entity'),
      onChanged: () => events.add('changed'),
    );
    await replica.queueMetadata('draft:!room:example.invalid', {'text': 'a'});
    expect(events, ['entity:draft:!room:example.invalid', 'changed']);

    events.clear();
    final op = replica.pending.values.single;
    await replica.markPublishing(op.opId);
    expect(events, ['entity:draft:!room:example.invalid', 'changed']);

    events.clear();
    await replica.stageCommand('metadata.put', 'org:!room:example.invalid', {
      'value': {'archived': true},
    });
    expect(events, ['entity:org:!room:example.invalid', 'changed']);
  });
}
