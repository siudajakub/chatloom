// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show RoundVideoDescriptor;

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

/// Identity of one reaction intent: account, source room, target event,
/// emoji, and whether it is a removal. A record, so lookups never encode or
/// decode JSON.
typedef ConversationReactionKey = ({
  String? account,
  String room,
  String event,
  String emoji,
  bool removal,
});

/// An own reaction hidden while the reaction [by] replaces it; [emoji] is
/// the hidden one.
typedef ConversationReactionReplacement = ({
  ConversationReactionKey by,
  String emoji,
});

/// The message a set of reaction intents belongs to.
typedef ConversationReactionScope = ({
  String? account,
  String room,
  String event,
});

/// One intent survives SDK completion until sync proves its result. An unknown
/// transport result is reconciled from aggregates, never automatically retried.
/// Keys are value-comparable objects ([ConversationReactionKey] in the app).
class ConversationReactionCoordinator extends ChangeNotifier {
  final _states = <Object, ConversationReactionState>{};
  ConversationReactionState state(Object key) =>
      _states[key] ?? ConversationReactionState.idle;

  Iterable<Object> get trackedKeys => _states.keys.toList(growable: false);

  static const _unresolved = {
    ConversationReactionState.pending,
    ConversationReactionState.awaitingEcho,
    ConversationReactionState.unknown,
  };

  bool unresolved(Object key) => _unresolved.contains(state(key));

  /// Tracked intents of one message (usually none; a few right after a tap).
  Iterable<ConversationReactionKey> keysFor(ConversationReactionScope scope) =>
      _states.keys.whereType<ConversationReactionKey>().where(
        (key) =>
            key.event == scope.event &&
            key.room == scope.room &&
            key.account == scope.account,
      );

  /// States of the tracked intents of one message.
  Set<ConversationReactionState> statesFor(ConversationReactionScope scope) => {
    for (final key in keysFor(scope)) state(key),
  };

  void reconcile(Object key, {required bool present}) {
    if (present &&
        _states[key] != ConversationReactionState.pending &&
        _states.remove(key) != null) {
      notifyListeners();
    }
  }

  Future<ConversationReactionResult> perform({
    required Object key,
    required bool Function() exists,
    bool Function()? confirmed,
    required bool Function() allowed,
    required Future<void> Function() add,
    required Future<void> Function() remove,
    required bool Function(Object) definitiveFailure,
    bool removeExisting = false,

    /// Runs once the intent is pending, before the transport (the
    /// optimistic part of a replacement).
    VoidCallback? onStart,
  }) async {
    final present = exists();
    if (!removeExisting) reconcile(key, present: confirmed?.call() ?? false);
    if (state(key) == ConversationReactionState.pending ||
        state(key) == ConversationReactionState.awaitingEcho ||
        state(key) == ConversationReactionState.unknown) {
      return ConversationReactionResult.pending;
    }
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
      onStart?.call();
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

  /// The SDK gave up on an add (its echo is an error): the intent failed
  /// and may be tried again; it no longer blocks the message's reactions.
  void markFailed(Object key) {
    final current = _states[key];
    if (current == null ||
        current == ConversationReactionState.pending ||
        current == ConversationReactionState.failed) {
      return;
    }
    _states[key] = ConversationReactionState.failed;
    notifyListeners();
  }

  /// Forgets a failed intent (a retry starts from scratch).
  void forget(Object key) {
    if (_states[key] == ConversationReactionState.failed &&
        _states.remove(key) != null) {
      notifyListeners();
    }
  }

  void reconcileRemoval(Object key, {required bool present}) {
    if (!present &&
        state(key) != ConversationReactionState.pending &&
        _states.remove(key) != null) {
      notifyListeners();
    }
  }

  /// Own reactions a newer one replaces, hidden at once (BR-01): on a
  /// network that keeps `reaction_count` reactions per person (WhatsApp,
  /// Messenger, Instagram: one; Telegram: one, three with Premium) the
  /// bridge redacts the oldest ones itself about a second later. Old
  /// reaction event ID → the replacing intent and the old emoji. Bounded;
  /// an entry leaves when the bridge's redaction arrives or the replacing
  /// reaction did not stick.
  final _replaced = <String, ConversationReactionReplacement>{};
  static const _replacedCap = 256;

  /// Whether the own reaction [eventId] is hidden behind a replacement.
  bool isReplaced(String eventId) => _replaced.containsKey(eventId);

  /// Hidden own reactions of one message, by event ID.
  Map<String, ConversationReactionReplacement> replacedFor(
    ConversationReactionScope scope,
  ) => _replaced.isEmpty
      ? const {}
      : {
          for (final entry in _replaced.entries)
            if (entry.value.by.event == scope.event &&
                entry.value.by.room == scope.room &&
                entry.value.by.account == scope.account)
              entry.key: entry.value,
        };

  /// Whether [emoji] of one message is hidden behind a replacement.
  bool replacing(ConversationReactionScope scope, String emoji) =>
      replacedFor(scope).values.any((value) => value.emoji == emoji);

  /// Hides [old] (event ID → emoji) while [by] replaces them.
  void hideReplaced(Map<String, String> old, ConversationReactionKey by) {
    if (old.isEmpty) return;
    for (final entry in old.entries) {
      _replaced[entry.key] = (by: by, emoji: entry.value);
    }
    while (_replaced.length > _replacedCap) {
      _replaced.remove(_replaced.keys.first);
    }
    notifyListeners();
  }

  /// Shows the reactions [by] was replacing again (it failed or was
  /// refused), or forgets the hidden ones in [eventIds] (their redaction
  /// arrived).
  void restoreReplaced({
    ConversationReactionKey? by,
    Iterable<String>? eventIds,
  }) {
    final before = _replaced.length;
    if (by != null) _replaced.removeWhere((_, value) => value.by == by);
    if (eventIds != null) eventIds.forEach(_replaced.remove);
    if (_replaced.length != before) notifyListeners();
  }
}

/// SDK adapter shared by ordinary/merged, menu, chips and touch gestures.
abstract final class ConversationMessageActions {
  static final _coordinators = Expando<ConversationReactionCoordinator>();
  static final _removalEvidence =
      Expando<
        Map<
          ConversationReactionKey,
          ({Timeline timeline, List<Event> originals})
        >
      >();
  static ConversationReactionCoordinator coordinator(Event event) =>
      _coordinators[event.room.client] ??= ConversationReactionCoordinator();

  /// The message [event] as a reaction scope.
  static ConversationReactionScope scope(Event event) => (
    account: event.room.client.userID,
    room: event.room.id,
    event: event.eventId,
  );

  static ConversationReactionKey key(
    Event event,
    String emoji, {
    bool removal = false,
  }) => (
    account: event.room.client.userID,
    room: event.room.id,
    event: event.eventId,
    emoji: emoji,
    removal: removal,
  );

  static List<Event> ownReactions(
    Event event,
    Timeline timeline,
    String emoji,
  ) => event
      .aggregatedEvents(timeline, RelationshipTypes.reaction)
      .where(
        (e) =>
            !e.redacted &&
            // An echo the SDK gave up on was never given.
            !e.status.isError &&
            e.senderId == event.room.client.userID &&
            // Replaced by a newer reaction; the bridge is removing it.
            !coordinator(event).isReplaced(e.eventId) &&
            e.content
                    .tryGetMap<String, Object?>('m.relates_to')
                    ?.tryGet<String>('key') ==
                emoji,
      )
      .toList();

  /// Reaction keys this account gave to [event] (not redacted).
  static Set<String> ownReactionKeys(Event event, Timeline timeline) => {
    for (final e in event.aggregatedEvents(
      timeline,
      RelationshipTypes.reaction,
    ))
      if (!e.redacted &&
          !e.status.isError &&
          e.senderId == event.room.client.userID &&
          !coordinator(event).isReplaced(e.eventId))
        ?e.content
            .tryGetMap<String, Object?>('m.relates_to')
            ?.tryGet<String>('key'),
  };

  /// Cheap value of this account's reactions on [event] (ids, status,
  /// redaction): reconciling is only needed when it changes.
  static Object ownReactionSignature(Event event, Timeline timeline) =>
      Object.hashAll([
        for (final e in event.aggregatedEvents(
          timeline,
          RelationshipTypes.reaction,
        ))
          if (e.senderId == event.room.client.userID) ...[
            e.eventId,
            e.status,
            e.redacted,
          ],
      ]);

  static void reconcile(Event event, Timeline timeline) {
    final manager = coordinator(event);
    _reconcileReplaced(manager, event, timeline);
    for (final tracked in manager.keysFor(scope(event)).toList()) {
      final own = ownReactions(event, timeline, tracked.emoji);
      if (tracked.removal) {
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
        if (manager.state(tracked) == ConversationReactionState.idle) {
          _removalEvidence[manager]?.remove(tracked);
        }
      } else {
        final synced = own.any((e) => e.status == EventStatus.synced);
        manager.reconcile(tracked, present: synced);
        if (!synced && own.isEmpty) {
          final errors = _errorEchoes(event, timeline, tracked.emoji);
          if (errors.isNotEmpty) {
            // Offline too long or refused by the server: the heart is not
            // given. Drop the dead echo, keep a visible, retriable failure.
            manager.markFailed(tracked);
            for (final echo in errors) {
              unawaited(echo.cancelSend().catchError((Object _) {}));
            }
          }
        }
      }
    }
  }

  /// Forgets hidden reactions the bridge removed, and shows them again when
  /// the reaction that replaced them failed or is gone (refused by the
  /// network and reverted, or removed by the user).
  static void _reconcileReplaced(
    ConversationReactionCoordinator manager,
    Event event,
    Timeline timeline,
  ) {
    final hidden = manager.replacedFor(scope(event));
    if (hidden.isEmpty) return;
    final own = {
      for (final e in event.aggregatedEvents(
        timeline,
        RelationshipTypes.reaction,
      ))
        if (e.senderId == event.room.client.userID) e.eventId: e,
    };
    final removed = [
      for (final id in hidden.keys)
        if (own[id] == null || own[id]!.redacted) id,
    ];
    if (removed.isNotEmpty) manager.restoreReplaced(eventIds: removed);
    for (final by in {for (final value in hidden.values) value.by}) {
      final state = manager.state(by);
      final stuck =
          state == ConversationReactionState.failed ||
          (state == ConversationReactionState.idle &&
              ownReactions(event, timeline, by.emoji).isEmpty);
      if (stuck) manager.restoreReplaced(by: by);
    }
  }

  /// The own reactions a new [emoji] replaces on [event] (oldest first):
  /// where the network keeps `reaction_count` reactions per person, the
  /// ones beyond `reaction_count - 1` newer ones, exactly what bridgev2
  /// removes. Empty without a declared limit (native Matrix rooms).
  static Map<String, String> _replacedBy(
    Event event,
    Timeline timeline,
    String emoji,
  ) {
    final limit = RoomCapabilities.evidenceForFeature(
      BridgeFeature.reaction,
      event.room,
      event: event,
      reaction: emoji,
    ).limits['reaction_count'];
    if (limit == null || limit <= 0) return const {};
    final own =
        event
            .aggregatedEvents(timeline, RelationshipTypes.reaction)
            .where(
              (e) =>
                  !e.redacted &&
                  !e.status.isError &&
                  e.eventId.startsWith(r'$') &&
                  e.senderId == event.room.client.userID &&
                  !coordinator(event).isReplaced(e.eventId),
            )
            .toList()
          ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    final excess = own.length - limit + 1;
    if (excess <= 0) return const {};
    return {
      for (final e in own.take(excess))
        e.eventId:
            e.content
                .tryGetMap<String, Object?>('m.relates_to')
                ?.tryGet<String>('key') ??
            '',
    };
  }

  static List<Event> _errorEchoes(
    Event event,
    Timeline timeline,
    String emoji,
  ) => event
      .aggregatedEvents(timeline, RelationshipTypes.reaction)
      .where(
        (e) =>
            e.status.isError &&
            e.senderId == event.room.client.userID &&
            e.content
                    .tryGetMap<String, Object?>('m.relates_to')
                    ?.tryGet<String>('key') ==
                emoji,
      )
      .toList();

  /// Sends a failed reaction again (the feedback line's Retry).
  static Future<bool> retryFailed(
    BuildContext context,
    Event event,
    Timeline timeline, {
    bool strict = false,
  }) async {
    final manager = coordinator(event);
    final failed = manager
        .keysFor(scope(event))
        .where(
          (k) =>
              !k.removal &&
              manager.state(k) == ConversationReactionState.failed,
        )
        .toList();
    var added = false;
    for (final key in failed) {
      manager.forget(key);
      added |= await react(context, event, timeline, key.emoji, strict: strict);
    }
    return added;
  }

  /// Whether [event] can be replied to (swipe, menu): sent, readable, the
  /// room accepts messages and its bridge does not refuse replies. [strict]
  /// sources (merged chats) need the reply feature verified.
  static bool canReply(Event event, {bool strict = false}) {
    final room = event.room;
    if (event.redacted ||
        // Its reply fallback would quote the SDK's decryption error.
        isUndecryptable(event) ||
        !event.status.isSent ||
        room.membership != Membership.join ||
        !room.canSendDefaultMessages) {
      return false;
    }
    final capability = RoomCapabilities.forFeature(
      BridgeFeature.reply,
      room,
      event: event,
    );
    return strict
        ? capability.allowed
        : capability.status != CapabilityStatus.unavailable;
  }

  /// Whether [event]'s network accepts [feature] on it now (age and edit
  /// limits included). [strict] sources (merged chats) need it verified with
  /// the Matrix checks of [RoomCapabilities.forFeature]; ordinary chats hide
  /// only what the bridge explicitly refuses and leave Matrix ownership and
  /// power to the caller (several accounts may share a chat).
  static bool networkAllows(
    BridgeFeature feature,
    Event event, {
    Timeline? timeline,
    bool strict = false,
  }) {
    final room = event.room;
    final editCount = feature == BridgeFeature.edit && timeline != null
        ? event
              .aggregatedEvents(timeline, RelationshipTypes.edit)
              .where((e) => e.senderId == event.senderId)
              .length
        : null;
    if (strict) {
      return RoomCapabilities.forFeature(
        feature,
        room,
        event: event,
        editCount: editCount,
      ).allowed;
    }
    return RoomCapabilities.declared(room)
            .evidence(
              feature,
              messageAge: DateTime.now().difference(event.originServerTs),
              editCount: editCount,
            )
            .result
            .status !=
        CapabilityStatus.unavailable;
  }

  static const _editableTypes = {
    MessageTypes.Text,
    MessageTypes.Emote,
    MessageTypes.Notice,
  };

  /// Whether the menu offers Edit for [event] (ownership is the caller's):
  /// a sent text message the network still lets the user edit (Telegram
  /// and Messenger hide Edit once the network's window has passed).
  static bool canEditContent(
    Event event,
    Timeline? timeline, {
    bool strict = false,
  }) =>
      event.status.isSent &&
      !event.redacted &&
      RoundVideoDescriptor.fromContent(event.content) == null &&
      _editableTypes.contains(event.messageType) &&
      networkAllows(
        BridgeFeature.edit,
        event,
        timeline: timeline,
        strict: strict,
      );

  /// Whether the network takes a "delete for everyone" of [event] now (the
  /// Matrix redaction permission is the caller's).
  static bool canDeleteForEveryone(Event event, {bool strict = false}) =>
      networkAllows(BridgeFeature.delete, event, strict: strict);

  /// Whether the room's network has threads (or does not say it has none).
  static bool canThread(Room room) =>
      RoomCapabilities.declared(
        room,
      ).evidence(BridgeFeature.thread).result.status !=
      CapabilityStatus.unavailable;

  /// The reaction capability of [event] in general (not one emoji): the bar
  /// and double tap are offered only when this holds.
  static bool canReactAtAll(Event event, {bool strict = false}) {
    final room = event.room;
    if (event.redacted ||
        !event.eventId.startsWith(r'$') ||
        !event.status.isSent ||
        room.membership != Membership.join ||
        !room.canSendDefaultMessages ||
        !room.canSendEvent(EventTypes.Reaction)) {
      return false;
    }
    final result = RoomCapabilities.forFeature(
      BridgeFeature.reaction,
      room,
      event: event,
    );
    return result.allowed ||
        (!strict && result.status == CapabilityStatus.unverified);
  }

  static CapabilityResult _reactionCapability(
    Event event,
    Timeline timeline,
    String emoji,
  ) => RoomCapabilities.forFeature(
    BridgeFeature.reaction,
    event.room,
    event: event,
    reaction: emoji,
  );

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
        room.membership != Membership.join) {
      return false;
    }
    if (removing) {
      return ownReactions(event, timeline, emoji).every((e) => e.canRedact);
    }
    if (!room.canSendDefaultMessages ||
        !room.canSendEvent(EventTypes.Reaction)) {
      return false;
    }
    final result = _reactionCapability(event, timeline, emoji);
    return result.allowed ||
        (!strict && result.status == CapabilityStatus.unverified);
  }

  /// Whether a toggle of [emoji] would add a reaction now (not remove one,
  /// not wait for a pending one, not be refused): the double-tap burst plays
  /// at once only then.
  static bool wouldAdd(
    Event event,
    Timeline timeline,
    String emoji, {
    bool strict = false,
  }) {
    final manager = coordinator(event);
    if (manager.keysFor(scope(event)).any(manager.unresolved)) return false;
    if (manager.replacing(scope(event), emoji)) return false;
    return ownReactions(event, timeline, emoji).isEmpty &&
        canReact(event, timeline, emoji, strict: strict);
  }

  /// The quick reactions of [room] (the long-press bar), Messenger's order
  /// with the heart first. A network that declares `allowed_reactions` keeps
  /// only the allowed ones, in this order and in the network's spelling;
  /// when none of them is allowed, the network's own first reactions.
  static List<String> quickReactions(Room room) {
    final allowed = _allowedReactions(room);
    if (allowed == null) return NotionReactions.defaults;
    final byKey = <String, String>{
      for (final key in allowed.reversed) NotionReactions.normalize(key): key,
    };
    final kept = [
      for (final emoji in NotionReactions.defaults)
        ?byKey[NotionReactions.normalize(emoji)],
    ];
    if (kept.isNotEmpty) return kept;
    return allowed
        .where((key) => !key.startsWith('mxc://'))
        .take(NotionReactions.defaults.length)
        .toList(growable: false);
  }

  /// The double-tap reaction of [room]: the emoji the user picked in the
  /// settings when the network allows it, otherwise the first quick reaction
  /// (a heart wherever the network has one).
  static String doubleTapReaction(Room room) {
    final quick = quickReactions(room);
    final picked = AppSettings.doubleTapReaction.value;
    if (picked.isNotEmpty) {
      final allowed = _allowedReactions(room);
      if (allowed == null) return picked;
      final match = allowed.firstWhere(
        (key) =>
            NotionReactions.normalize(key) == NotionReactions.normalize(picked),
        orElse: () => '',
      );
      if (match.isNotEmpty) return match;
    }
    return quick.isEmpty ? NotionReactions.defaults.first : quick.first;
  }

  /// The `allowed_reactions` the room's bridge declares, or null when it
  /// declares none (any emoji). Picks the declaration exactly like
  /// [RoomCapabilities.declared]: the single one of the room's bridge, or the
  /// only one; several unrelated declarations count as none (the capability
  /// check, which refuses them, stays the authority when sending).
  static List<String>? _allowedReactions(Room room) {
    final states = room.states[bridgeFeaturesEventType];
    if (states == null || states.isEmpty) return null;
    final bridgeKeys = <String>{
      for (final type in const [
        'm.bridge',
        'uk.half-shot.bridge',
        'com.beeper.bridge',
      ])
        ...?room.states[type]?.keys,
    };
    final matches = states.keys.where(bridgeKeys.contains).toList();
    final content = matches.length == 1
        ? states[matches.single]?.content
        : matches.isEmpty && states.length == 1
        ? states.values.single.content
        : null;
    final allowed = content?['allowed_reactions'];
    if (allowed is! List || allowed.any((e) => e is! String)) return null;
    return allowed.cast<String>();
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
    final unresolvedSource = manager
        .keysFor(scope(event))
        .any(manager.unresolved);
    // The emoji being replaced is still on the network until the bridge's
    // redaction arrives (about a second): giving it again now would be a
    // duplicate the server refuses.
    if (unresolvedSource || manager.replacing(scope(event), emoji)) {
      _notice(
        context,
        'Waiting for the source network to confirm the reaction.',
      );
      return false;
    }
    final removing = toggle && present();
    // A network that keeps one reaction per person (or a few) replaces the
    // oldest: hide it now, like WhatsApp and Messenger; the bridge redacts
    // it once the new one is through (BR-01).
    final replacing = removing || present()
        ? const <String, String>{}
        : _replacedBy(event, timeline, emoji);
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
        if (id == null || !id.startsWith(r'$')) {
          throw StateError('Reaction acceptance unknown');
        }
      },
      remove: () async {
        for (final reaction in ownReactions(event, timeline, emoji)) {
          final id = await reaction.redactEvent();
          if (id == null || !id.startsWith(r'$')) {
            throw StateError('Reaction removal unknown');
          }
        }
      },
      definitiveFailure: (error) {
        final status = error is MatrixException
            ? error.response?.statusCode
            : null;
        return status != null && status >= 400 && status < 500;
      },
      removeExisting: removing,
      onStart: replacing.isEmpty
          ? null
          : () => manager.hideReplaced(replacing, addingKey),
    );
    if (replacing.isNotEmpty && result != ConversationReactionResult.added) {
      manager.restoreReplaced(by: addingKey);
    }
    reconcile(event, timeline);
    if (context.mounted) {
      switch (result) {
        case ConversationReactionResult.denied:
          // The network's own reason (a limit, an emoji it does not have)
          // says more than a generic refusal.
          final capability = removing
              ? null
              : _reactionCapability(event, timeline, emoji);
          _notice(
            context,
            capability != null &&
                    capability.status == CapabilityStatus.unavailable &&
                    capability.reason.isNotEmpty
                ? capability.reason
                : 'Reactions are unavailable for this source message.',
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
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(text)));
    }
  }
}

/// Reconciles [event]'s tracked reaction intents after a frame, only while
/// some are tracked and only when this account's reactions on it changed.
/// Shared by the footer feedback and the chips, so a row never schedules
/// work on ordinary rebuilds.
class ConversationReactionReconciler {
  Object? _signature;

  void didBuild(BuildContext context, Event event, Timeline timeline) {
    final manager = ConversationMessageActions.coordinator(event);
    final scope = ConversationMessageActions.scope(event);
    if (manager.keysFor(scope).isEmpty && manager.replacedFor(scope).isEmpty) {
      _signature = null;
      return;
    }
    final signature = (
      timeline,
      ConversationMessageActions.ownReactionSignature(event, timeline),
    );
    if (signature == _signature) return;
    _signature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        ConversationMessageActions.reconcile(event, timeline);
      }
    });
  }
}

/// Persistent, content-free result state, including when no chip has echoed yet.
/// Rebuilds only when the state of this message's intents changes, not on
/// every reaction elsewhere in the account.
class ConversationReactionFeedback extends StatefulWidget {
  final Event event;
  final Timeline timeline;
  const ConversationReactionFeedback(this.event, this.timeline, {super.key});

  @override
  State<ConversationReactionFeedback> createState() =>
      _ConversationReactionFeedbackState();
}

class _ConversationReactionFeedbackState
    extends State<ConversationReactionFeedback> {
  final _reconciler = ConversationReactionReconciler();
  ConversationReactionCoordinator? _manager;
  String? _text;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(ConversationReactionFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.event.room.client, widget.event.room.client)) {
      _listen();
    }
    _text = _compute();
  }

  void _listen() {
    _manager?.removeListener(_changed);
    _manager = ConversationMessageActions.coordinator(widget.event)
      ..addListener(_changed);
    _text = _compute();
  }

  String? _compute() {
    final states = _manager!.statesFor(
      ConversationMessageActions.scope(widget.event),
    );
    if (states.isEmpty) return null;
    return states.contains(ConversationReactionState.unknown)
        ? 'Reaction confirmation unknown · waiting for source sync'
        : states.contains(ConversationReactionState.pending) ||
              states.contains(ConversationReactionState.awaitingEcho)
        ? 'Reaction pending source confirmation'
        : states.contains(ConversationReactionState.failed)
        ? 'Reaction not sent · Tap to retry'
        : null;
  }

  void _changed() {
    if (!mounted) return;
    final text = _compute();
    if (text != _text) setState(() => _text = text);
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _reconciler.didBuild(context, widget.event, widget.timeline);
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    final failed = _manager!
        .statesFor(ConversationMessageActions.scope(widget.event))
        .contains(ConversationReactionState.failed);
    final colors = context.notion.colors;
    final label = Text(
      text,
      style: NotionType.micro.copyWith(
        color: failed ? colors.danger : colors.textSecondary,
        fontWeight: failed ? FontWeight.w600 : null,
      ),
    );
    if (!failed) return Semantics(liveRegion: true, child: label);
    return Semantics(
      liveRegion: true,
      button: true,
      child: InkWell(
        key: const ValueKey('reaction-retry'),
        borderRadius: NotionRadius.pillAll,
        onTap: () => unawaited(
          ConversationMessageActions.retryFailed(
            context,
            widget.event,
            widget.timeline,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NotionSpace.xs,
            vertical: NotionSpace.xxs,
          ),
          child: label,
        ),
      ),
    );
  }
}
