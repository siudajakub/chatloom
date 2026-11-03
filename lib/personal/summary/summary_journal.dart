// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/personal_client.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

/// The only summary transport is the existing verified, encrypted journal.
/// Provider keys never enter the application or the selected conversation.
class SummaryJournal {
  final PersonalClient personal;
  final bool Function() isCurrent;
  final Duration timeout;

  const SummaryJournal({
    required this.personal,
    required this.isCurrent,
    this.timeout = const Duration(minutes: 3),
  });

  void validate() {
    if (!isCurrent()) throw const SummaryCancelledException();
    if (!personal.ready) throw const SummaryException('private_sync_required');
    final heartbeat = personal.workerReadiness;
    if (heartbeat == null || !heartbeat.freshAt(DateTime.now())) {
      throw const SummaryException('worker_offline');
    }
    if (heartbeat.healthy != true || heartbeat.verified != true) {
      throw const SummaryException('worker_unavailable');
    }
    if (heartbeat.summary != 'ready' || heartbeat.summaryVersion != 1) {
      throw const SummaryException('summary_not_configured');
    }
  }

  Future<SummaryResult> generate({
    required ConversationRef conversation,
    required SummaryRequest request,
    required SummarySource source,
    required SummaryCancellation cancellation,
    void Function(bool processing)? onState,
  }) async {
    cancellation.throwIfCancelled();
    validate();
    final id = 'summary:${const Uuid().v4()}';
    final upload = SummaryUpload.create(
      id: id,
      conversation: conversation,
      request: request,
      source: source,
    );
    var requested = false;
    final stagedParts = <String>[];
    try {
      for (var i = 0; i < upload.parts.length; i++) {
        cancellation.throwIfCancelled();
        validate();
        final entity = upload.partEntity(i);
        await personal.put(entity, upload.parts[i]);
        stagedParts.add(entity);
      }
      cancellation.throwIfCancelled();
      validate();
      // Freeze the commitment before awaiting storage: cancellation that
      // races publication must be recorded durably, not drop a local future.
      requested = true;
      await personal.command(
        'summary.request',
        id,
        upload.manifest,
        optimisticJob: {...upload.manifest, 'state': 'waitingSync'},
      );
      cancellation.throwIfCancelled();
      validate();
      return await _wait(id, cancellation, onState);
    } catch (_) {
      if (requested) {
        // A timed-out provider call is never silently repeated. The worker's
        // durable cancellation survives leaving the sheet and reconnecting.
        try {
          await personal.cancelSummary(id);
        } catch (_) {
          // Preserve the original failure if the encrypted store itself
          // became unavailable. Never retry the paid request here.
        }
      }
      for (final entity in stagedParts) {
        try {
          await personal.delete(entity);
        } catch (_) {
          // Existing durable journal metadata remains encrypted. Nothing
          // is sent to the provider without a committed request manifest.
        }
      }
      rethrow;
    }
  }

  Future<SummaryResult> _wait(
    String id,
    SummaryCancellation cancellation,
    void Function(bool processing)? onState,
  ) async {
    final done = Completer<SummaryResult>();
    void inspect() {
      if (done.isCompleted) return;
      try {
        cancellation.throwIfCancelled();
        validate();
        final job = personal.summaries[id];
        if (job == null) return;
        switch (job['state']) {
          case 'done':
            done.complete(SummaryResult.fromJson(job));
          case 'cancelled':
            throw const SummaryCancelledException();
          case 'failed' || 'unknown' || 'conflict':
            throw SummaryException(
              job['errorCode'] is String
                  ? job['errorCode'] as String
                  : 'summary_failed',
            );
          default:
            onState?.call(job['state'] == 'processing');
        }
      } catch (error, trace) {
        done.completeError(error, trace);
      }
    }

    final subscription = personal.changes.listen((_) => inspect());
    final timer = Timer(timeout, () {
      if (!done.isCompleted) {
        done.completeError(const SummaryException('summary_timeout'));
      }
    });
    unawaited(cancellation.whenCancelled.then((_) => inspect()));
    inspect();
    try {
      return await done.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }
}
