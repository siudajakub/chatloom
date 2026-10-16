// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

enum ConversationReactionState { idle, pending, awaitingEcho, unknown, failed }

enum ConversationReactionResult {
  added,
  removed,
  existing,
  pending,
  denied,
  unknown,
  failed,
}

/// One intent survives SDK completion until sync proves its result. An unknown
/// transport result is reconciled from aggregates, never automatically retried.
class ConversationReactionCoordinator extends ChangeNotifier {
  final _states = <String, ConversationReactionState>{};
  ConversationReactionState state(String key) =>
      _states[key] ?? ConversationReactionState.idle;

  Iterable<String> get trackedKeys => _states.keys.toList(growable: false);

  bool unresolved(String key) => {
    ConversationReactionState.pending,
    ConversationReactionState.awaitingEcho,
    ConversationReactionState.unknown,
  }.contains(state(key));

  void reconcile(String key, {required bool present}) {
    if (present &&
        _states[key] != ConversationReactionState.pending &&
        _states.remove(key) != null)
      notifyListeners();
  }

  Future<ConversationReactionResult> perform({
    required String key,
    required bool Function() exists,
    bool Function()? confirmed,
    required bool Function() allowed,
    required Future<void> Function() add,
    required Future<void> Function() remove,
    required bool Function(Object) definitiveFailure,
    bool removeExisting = false,
  }) async {
    final present = exists();
    if (!removeExisting) reconcile(key, present: confirmed?.call() ?? false);
    if (state(key) == ConversationReactionState.pending ||
        state(key) == ConversationReactionState.awaitingEcho ||
        state(key) == ConversationReactionState.unknown)
      return ConversationReactionResult.pending;
    if (!removeExisting && present) return ConversationReactionResult.existing;
    if (!allowed()) return ConversationReactionResult.denied;
    _states[key] = ConversationReactionState.pending;
    notifyListeners();
    try {
      // Revalidate after any synchronous listener changed account/capabilities.
      if (!allowed()) {
        _states.remove(key);
        notifyListeners();
        return ConversationReactionResult.denied;
      }
      if (removeExisting && present) {
        await remove();
        // A stale aggregate may still contain the removed reaction. Keep a
        // separate removal barrier until its absence is observed by the adapter.
        _states[key] = ConversationReactionState.awaitingEcho;
        notifyListeners();
        return ConversationReactionResult.removed;
      }
      await add();
      _states[key] = ConversationReactionState.awaitingEcho;
      reconcile(key, present: confirmed?.call() ?? false);
      notifyListeners();
      return ConversationReactionResult.added;
    } catch (error) {
      final definite = definitiveFailure(error);
      _states[key] = definite
          ? ConversationReactionState.failed
          : ConversationReactionState.unknown;
      notifyListeners();
      return definite
          ? ConversationReactionResult.failed
          : ConversationReactionResult.unknown;
    }
  }

  void reconcileRemoval(String key, {required bool present}) {
    if (!present &&
        state(key) != ConversationReactionState.pending &&
        _states.remove(key) != null)
      notifyListeners();
  }
}

/// SDK adapter shared by ordinary/merged, menu, chips and touch gestures.
abstract final class ConversationMessageActions {
  static final _coordinators = Expando<ConversationReactionCoordinator>();
  static final _removalEvidence =
      Expando<Map<String, ({Timeline timeline, List<Event> originals})>>();
  static ConversationReactionCoordinator coordinator(Event event) =>
      _coordinators[event.room.client] ??= ConversationReactionCoordinator();
  static String key(Event event, String emoji, {bool removal = false}) =>
      jsonEncode([
        event.room.client.userID,
        event.room.id,
        event.eventId,
        emoji,
        if (removal) 'remove',
      ]);
  static List<Event> ownReactions(
    Event event,
    Timeline timeline,
    String emoji,
  ) => event
      .aggregatedEvents(timeline, RelationshipTypes.reaction)
      .where(
        (e) =>
            !e.redacted &&
            e.senderId == event.room.client.userID &&
            e.content
                    .tryGetMap<String, Object?>('m.relates_to')
                    ?.tryGet<String>('key') ==
                emoji,
      )
      .toList();

  static void reconcile(Event event, Timeline timeline) {
    final manager = coordinator(event);
    for (final tracked in manager.trackedKeys) {
      final parts = jsonDecode(tracked) as List;
      if (parts[0] != event.room.client.userID ||
          parts[1] != event.room.id ||
          parts[2] != event.eventId)
        continue;
      final own = ownReactions(event, timeline, parts[3] as String);
      if (parts.length > 4) {
        final evidence = _removalEvidence[manager]?[tracked];
        final redactionProven =
            evidence != null &&
            (evidence.originals.any((e) => e.redacted) ||
                timeline.events.any(
                  (e) =>
                      e.type == EventTypes.Redaction &&
                      e.status == EventStatus.synced &&
                      evidence.originals.any(
                        (original) => e.redacts == original.eventId,
                      ),
                ));
        final acceptedAbsence =
            manager.state(tracked) == ConversationReactionState.awaitingEcho &&
            identical(evidence?.timeline, timeline) &&
            own.isEmpty;
        manager.reconcileRemoval(
          tracked,
          present: !(redactionProven || acceptedAbsence),
        );
        if (manager.state(tracked) == ConversationReactionState.idle)
          _removalEvidence[manager]?.remove(tracked);
      } else {
        manager.reconcile(
          tracked,
          present: own.any((e) => e.status == EventStatus.synced),
        );
      }
    }
  }

  static bool canReact(
    Event event,
    Timeline timeline,
    String emoji, {
    bool strict = false,
    bool removing = false,
  }) {
    final room = event.room;
    if (event.redacted ||
        !event.eventId.startsWith(r'$') ||
        !event.status.isSent ||
        room.membership != Membership.join)
      return false;
    if (removing)
      return ownReactions(event, timeline, emoji).every((e) => e.canRedact);
    if (!room.canSendDefaultMessages || !room.canSendEvent(EventTypes.Reaction))
      return false;
    final result = RoomCapabilities.forFeature(
      BridgeFeature.reaction,
      room,
      event: event,
      reaction: emoji,
      reactionCount: event
          .aggregatedEvents(timeline, RelationshipTypes.reaction)
          .where((e) => !e.redacted && e.senderId == room.client.userID)
          .length,
    );
    return result.allowed ||
        (!strict && result.status == CapabilityStatus.unverified);
  }

  static Future<bool> react(
    BuildContext context,
    Event event,
    Timeline timeline,
    String emoji, {
    bool toggle = false,
    bool strict = false,
    bool Function()? isCurrent,
  }) async {
    final manager = coordinator(event);
    final addingKey = key(event, emoji);
    final removingKey = key(event, emoji, removal: true);
    bool present() => ownReactions(event, timeline, emoji).isNotEmpty;
    reconcile(event, timeline);
    // Local echo counts for dedup, but only synced aggregate releases a barrier.
    final unresolvedSource = manager.trackedKeys.any((tracked) {
      final parts = jsonDecode(tracked) as List;
      return parts[0] == event.room.client.userID &&
          parts[1] == event.room.id &&
          parts[2] == event.eventId &&
          manager.unresolved(tracked);
    });
    if (unresolvedSource) {
      _notice(
        context,
        'Waiting for the source network to confirm the reaction.',
      );
      return false;
    }
    final removing = toggle && present();
    if (removing) {
      (_removalEvidence[manager] ??= {})[removingKey] = (
        timeline: timeline,
        originals: ownReactions(event, timeline, emoji),
      );
    }
    final result = await manager.perform(
      key: removing ? removingKey : addingKey,
      exists: present,
      confirmed: () => ownReactions(
        event,
        timeline,
        emoji,
      ).any((e) => e.status == EventStatus.synced),
      allowed: () =>
          context.mounted &&
          (isCurrent?.call() ??
              identical(Matrix.of(context).client, event.room.client)) &&
          canReact(
            event,
            timeline,
            emoji,
            strict: strict,
            removing: removing,
          ) &&
          (!removing ||
              ownReactions(event, timeline, emoji).every((e) => e.canRedact)),
      add: () async {
        final id = await event.room.sendReaction(event.eventId, emoji);
        if (id == null || !id.startsWith(r'$'))
          throw StateError('Reaction acceptance unknown');
      },
      remove: () async {
        for (final reaction in ownReactions(event, timeline, emoji)) {
          final id = await reaction.redactEvent();
          if (id == null || !id.startsWith(r'$'))
            throw StateError('Reaction removal unknown');
        }
      },
      definitiveFailure: (error) {
        final status = error is MatrixException
            ? error.response?.statusCode
            : null;
        return status != null && status >= 400 && status < 500;
      },
      removeExisting: removing,
    );
    reconcile(event, timeline);
    if (context.mounted) {
      switch (result) {
        case ConversationReactionResult.denied:
          _notice(
            context,
            'Reactions are unavailable for this source message.',
          );
        case ConversationReactionResult.pending:
        case ConversationReactionResult.unknown:
          _notice(
            context,
            'Waiting for the source network to confirm the reaction.',
          );
        case ConversationReactionResult.failed:
          _notice(
            context,
            'The source rejected the reaction. Use the reaction menu to try again.',
          );
        default:
          break;
      }
    }
    return result == ConversationReactionResult.added;
  }

  static void _notice(BuildContext context, String text) {
    if (context.mounted)
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(text)));
  }
}

/// Persistent, content-free result state, including when no chip has echoed yet.
class ConversationReactionFeedback extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  const ConversationReactionFeedback(this.event, this.timeline, {super.key});
  @override
  Widget build(BuildContext context) {
    final manager = ConversationMessageActions.coordinator(event);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted)
        ConversationMessageActions.reconcile(event, timeline);
    });
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final states = manager.trackedKeys
            .where((key) {
              final parts = jsonDecode(key) as List;
              return parts[0] == event.room.client.userID &&
                  parts[1] == event.room.id &&
                  parts[2] == event.eventId;
            })
            .map(manager.state)
            .toSet();
        final text = states.contains(ConversationReactionState.unknown)
            ? 'Reaction confirmation unknown · waiting for source sync'
            : states.contains(ConversationReactionState.pending) ||
                  states.contains(ConversationReactionState.awaitingEcho)
            ? 'Reaction pending source confirmation'
            : states.contains(ConversationReactionState.failed)
            ? 'Reaction rejected · use menu to retry'
            : null;
        return text == null
            ? const SizedBox.shrink()
            : Semantics(
                liveRegion: true,
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
      },
    );
  }
}
