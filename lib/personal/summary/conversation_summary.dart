// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/disappearing_state.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/summary/summary_history.dart';
import 'package:chatloom/personal/summary/summary_journal.dart';
import 'package:chatloom/personal/summary/ui/conversation_summary_sheet.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Starts only from the explicitly selected group. No conversation event,
/// receipt, typing signal or provider credential is published here.
Future<void> showGroupConversationSummary(
  BuildContext context, {
  required Room room,
  required bool Function() isCurrent,
}) async {
  if (room.isDirectChatForDisplay ||
      room.membership != Membership.join ||
      room.isArchived ||
      PersonalPrivacy.isJournal(room) ||
      !PersonalPrivacy.surfaceUnlocked ||
      !isCurrent()) {
    return;
  }
  final personal = PersonalClient.of(room.client);
  final account = room.client.userID;
  final lockGeneration = PersonalPrivacy.surfaceLockGeneration;
  bool current() =>
      context.mounted &&
      isCurrent() &&
      PersonalPrivacy.surfaceUnlocked &&
      lockGeneration == PersonalPrivacy.surfaceLockGeneration &&
      account == room.client.userID &&
      identical(room.client.getRoomById(room.id), room) &&
      room.membership == Membership.join &&
      !room.isArchived;

  final journal = SummaryJournal(personal: personal, isCurrent: current);
  await showConversationSummary(
    context,
    chatName: InboxProjection(personal).displayName(room),
    isCurrent: current,
    accessChanges: Listenable.merge([personal, AppLock.of(context).controller]),
    summarize: (request, onProgress, cancellation) async {
      cancellation.throwIfCancelled();
      if (!current()) throw const SummaryCancelledException();
      onProgress(const SummaryUiProgress(stage: SummaryUiStage.syncing));
      await personal.load();
      cancellation.throwIfCancelled();
      journal.validate();
      await loadRoomState(room);
      cancellation.throwIfCancelled();
      journal.validate();
      if (roomMayDisappear(room)) {
        throw const SummaryException('disappearing_messages');
      }
      onProgress(const SummaryUiProgress(stage: SummaryUiStage.loadingHistory));
      final source = await const SummaryHistoryCollector().collectRoom(
        room: room,
        request: request,
        personal: personal,
        cancellation: cancellation,
        onProgress: (count) {
          if (!current()) {
            cancellation.cancel();
            return;
          }
          onProgress(
            SummaryUiProgress(
              stage: SummaryUiStage.loadingHistory,
              messageCount: count,
            ),
          );
        },
      );
      cancellation.throwIfCancelled();
      journal.validate();
      onProgress(
        SummaryUiProgress(
          stage: SummaryUiStage.waitingWorker,
          messageCount: source.messages.length,
        ),
      );
      return journal.generate(
        conversation: personal.ref(room),
        request: request,
        source: source,
        cancellation: cancellation,
        onState: (processing) => onProgress(
          SummaryUiProgress(
            stage: processing
                ? SummaryUiStage.summarizing
                : SummaryUiStage.waitingWorker,
            messageCount: source.messages.length,
          ),
        ),
      );
    },
  );
}
