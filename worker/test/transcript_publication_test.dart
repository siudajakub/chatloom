// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/store.dart';
import 'package:personal_worker/src/transcript_publication.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('a newer conflict echo cannot replace the current done publication', () {
    final store = WorkerStore(sqlite3.openInMemory());
    addTearDown(store.close);
    final job = {'id': 'fixture', 'revision': 4};
    store.recordTranscriptPublication({
      'opId': stableId('state', 'fixture:4:done:transition'),
      'kind': 'transcript.result',
      'entityId': 'fixture',
      'payload': {'state': 'done', 'text': 'fixture'},
    }, r'$done');
    store.recordTranscriptPublication({
      'opId': 'rejection',
      'kind': 'transcript.result',
      'entityId': 'fixture',
      'payload': {'state': 'conflict', 'text': 'fixture'},
    }, r'$rejection');
    expect(doneTranscriptEvent(store, job), r'$done');
    expect(
      doneTranscriptEvent(store, {'id': 'fixture', 'revision': 5}),
      isNull,
    );
  });
}
