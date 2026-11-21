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

bool canUseConversationAssistant(Room room) =>
    room.membership == Membership.join &&
    !room.isArchived &&
    !room.isSpace &&
    !PersonalPrivacy.isJournal(room);

/// Starts from a single explicit Matrix conversation.
Future<void> showConversationAssistant(
  BuildContext context, {
  required Room room,
  required bool Function() isCurrent,
  bool asking = false,
}) {
  if (!asking && room.isDirectChatForDisplay) return Future.value();
  return _showConversationAssistant(
    context,
    rooms: [room],
    chatName: InboxProjection(PersonalClient.of(room.client)).displayName(room),
    isCurrent: isCurrent,
    asking: asking,
  );
}

/// One read-only request over the active sources shown for a merged person.
Future<void> showMergedConversationAssistant(
  BuildContext context, {
  required List<Room> rooms,
  required int linkedRoomCount,
  required String chatName,
  required bool Function() isCurrent,
  required bool asking,
}) => _showConversationAssistant(
  context,
  rooms: List.unmodifiable(rooms),
  linkedRoomCount: linkedRoomCount,
  chatName: chatName,
  isCurrent: isCurrent,
  asking: asking,
);

Future<void> _showConversationAssistant(
  BuildContext context, {
  required List<Room> rooms,
  required String chatName,
  required bool Function() isCurrent,
  required bool asking,
  int? linkedRoomCount,
}) async {
  if (rooms.isEmpty) return;
  final room = rooms.first;
  final personal = PersonalClient.of(room.client);
  final account = room.client.userID;
  final lockGeneration = PersonalPrivacy.surfaceLockGeneration;
  final sourceDescription = linkedRoomCount == null
      ? null
      : linkedRoomCount == rooms.length
      ? 'Includes all ${rooms.length} linked chats.'
      : 'Includes ${rooms.length} of $linkedRoomCount linked chats currently available.';
  bool current() =>
      context.mounted &&
      isCurrent() &&
      PersonalPrivacy.surfaceUnlocked &&
      lockGeneration == PersonalPrivacy.surfaceLockGeneration &&
      account == room.client.userID &&
      rooms.every(
        (source) =>
            identical(source.client, personal.client) &&
            identical(source.client.getRoomById(source.id), source) &&
            canUseConversationAssistant(source),
      );
  if (account == null || !current()) return;

  bool hasDisappearingMessages() => rooms.any(roomMayDisappear);
  final journal = SummaryJournal(
    personal: personal,
    isCurrent: () => current() && !hasDisappearingMessages(),
  );
  await showConversationSummary(
    context,
    chatName: chatName,
    sourceDescription: sourceDescription,
    asking: asking,
    isCurrent: current,
    accessChanges: Listenable.merge([personal, AppLock.of(context).controller]),
    summarize: (request, onProgress, cancellation) async {
      cancellation.throwIfCancelled();
      if (!current()) throw const SummaryCancelledException();
      onProgress(const SummaryUiProgress(stage: SummaryUiStage.checkingAccess));
      await personal.load();
      cancellation.throwIfCancelled();
      await Future.wait(rooms.map(loadRoomState));
      cancellation.throwIfCancelled();
      if (hasDisappearingMessages()) {
        throw const SummaryException('disappearing_messages');
      }
      journal.validate(asking: asking);
      onProgress(const SummaryUiProgress(stage: SummaryUiStage.loadingHistory));
      final history = await const SummaryHistoryCollector().collect(
        source: rooms.length == 1
            ? MatrixSummaryHistorySource(room: room, personal: personal)
            : MergedSummaryHistorySource({
                for (final source in rooms)
                  personal.ref(source): MatrixSummaryHistorySource(
                    room: source,
                    personal: personal,
                  ),
              }),
        request: request,
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
      final source = sourceDescription == null
          ? history
          : SummarySource(
              messages: history.messages,
              complete: history.complete && linkedRoomCount == rooms.length,
              omittedMessages: history.omittedMessages,
              coverageNote: [
                sourceDescription,
                ?history.coverageNote,
              ].join(' '),
            );
      onProgress(
        SummaryUiProgress(
          stage: SummaryUiStage.syncing,
          messageCount: source.messages.length,
        ),
      );
      return journal.generate(
        // Only an account-bound anchor for the journal's existing manifest.
        // The context already contains the validated source projection.
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
