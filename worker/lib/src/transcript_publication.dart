import 'engine.dart';
import 'store.dart';

/// Rejections can echo an existing transcript as a conflict result. Select the
/// accepted done transition for the current ledger revision, not the last event
/// which happens to contain text.
String? doneTranscriptEvent(WorkerStore store, Map<String, dynamic> job) {
  final id = job['id'] as String;
  final revision = job['revision'] as int;
  final op = stableId('state', '$id:$revision:done:transition');
  final rows = store.db.select(
    "SELECT event_id FROM transcript_publications WHERE op_id=? AND entity_id=? AND text_bearing=1 AND event_id!=''",
    [op, id],
  );
  return rows.isEmpty ? null : rows.single['event_id'] as String;
}
