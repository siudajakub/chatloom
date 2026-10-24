// SPDX-License-Identifier: AGPL-3.0-or-later

/// Server push rules for chats ChatLoom keeps silent for good (wave 7,
/// BP-07 / wave-4 R1 / wave-5 ASK #18).
///
/// ChatLoom's mute, notification mode and "ignored" placement are private
/// journal metadata. The homeserver never saw them, so every message in a
/// muted busy group still sent a high-priority push that woke the phone
/// (often from a killed process) only for `push_helper.dart` to drop it.
///
/// For chats that are silent with no end, ChatLoom now also writes one
/// account push rule per room, so the homeserver stops pushing them:
///
/// * ignored chats (also ignored by a network's group placement);
/// * a chat (or the merged person it belongs to) whose notification mode is
///   "Muted";
/// * a chat or person muted "until I unmute" (no end time).
///
/// Timed mutes, mentions-only, low priority, message requests and network
/// notification defaults stay local: a server rule cannot expire, and
/// "mentions only" cannot be judged by the server in encrypted chats.
/// A merged person applies to each of its source rooms.
///
/// Ownership: the rule is an `override` rule whose id is
/// [chatLoomMuteRulePrefix] followed by the room id, with exactly one
/// `event_match room_id` condition and no notify action. The prefix makes
/// ownership visible on the server itself, so every ChatLoom device agrees
/// on which rules it may change without a local record, and the rule never
/// collides with the room's own Beeper/Element mute (whose id is the bare
/// room id). ChatLoom only ever creates, enables or deletes rules with that
/// prefix; every other rule of the account is left alone.
///
/// Reconcile: after private sync is ready, after every private-state
/// change (mute, unmute, ignore, restore, from this or another device, Undo
/// included) and after the account's rules change, debounced. Writes go one
/// at a time, a bounded number per pass, and back off exponentially (or as
/// the server asks) after an error. A just-written rule is remembered until
/// sync shows it, so nothing is sent twice.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Rule id prefix of the push rules ChatLoom owns (reverse DNS of the app).
const chatLoomMuteRulePrefix = 'pl.personal.chat.mute.';

String chatLoomMuteRuleId(String roomId) => '$chatLoomMuteRulePrefix$roomId';

bool isChatLoomMuteRuleId(String ruleId) =>
    ruleId.startsWith(chatLoomMuteRulePrefix) &&
    ruleId.length > chatLoomMuteRulePrefix.length;

/// The room a ChatLoom rule silences, or null for any other rule.
String? chatLoomMuteRuleRoom(String ruleId) => isChatLoomMuteRuleId(ruleId)
    ? ruleId.substring(chatLoomMuteRulePrefix.length)
    : null;

/// [rules] without the rules ChatLoom owns: the account's own settings, for
/// the client-side push check, diagnostics and the rules editor. ChatLoom's
/// local mute state already decides those chats.
PushRuleSet withoutChatLoomRules(PushRuleSet rules) {
  final override = rules.override;
  if (override == null ||
      !override.any((r) => isChatLoomMuteRuleId(r.ruleId))) {
    return rules;
  }
  return PushRuleSet(
    content: rules.content,
    override: [
      for (final rule in override)
        if (!isChatLoomMuteRuleId(rule.ruleId)) rule,
    ],
    room: rules.room,
    sender: rules.sender,
    underride: rules.underride,
  );
}

/// Whether [rule] is exactly the rule ChatLoom writes for [roomId].
bool _hasMuteShape(PushRule rule, String roomId) {
  final conditions = rule.conditions;
  if (conditions == null || conditions.length != 1) return false;
  final condition = conditions.single;
  return condition.kind == 'event_match' &&
      condition.key == 'room_id' &&
      condition.pattern == roomId &&
      !EvaluatedPushRuleAction.fromActions(rule.actions).notify;
}

// Room ids silenced by an enabled ChatLoom rule, cached per push rules
// content (the SDK parses the account data on every `globalPushRules`).
final _silencedCache = Expando<Set<String>>('chatloom mute rules');

/// Room ids an enabled ChatLoom rule silences on the server.
Set<String> chatLoomSilencedRooms(Client client) {
  final Map<String, Object?>? content;
  try {
    content = client.accountData['m.push_rules']?.content;
  } catch (_) {
    return const {};
  }
  if (content == null) return const {};
  return _silencedCache[content] ??= () {
    final PushRuleSet? rules;
    try {
      rules = client.globalPushRules;
    } catch (_) {
      return const <String>{};
    }
    return {
      for (final rule in rules?.override ?? const <PushRule>[])
        if (rule.enabled)
          if (chatLoomMuteRuleRoom(rule.ruleId) case final room?)
            if (_hasMuteShape(rule, room)) room,
    };
  }();
}

/// Unread for the inbox: the server keeps no notification count for a
/// chat a ChatLoom rule silences, so such a chat counts as unread when it
/// has messages after the read marker (Telegram keeps muted chats' unread
/// state, just quieter). Other chats keep the SDK's [Room.isUnread].
bool personalRoomUnread(Room room) =>
    room.isUnread || chatLoomSilencedUnread(room);

/// A joined chat a ChatLoom rule silences, with messages after the read
/// marker (its server count stays zero).
bool chatLoomSilencedUnread(Room room) {
  if (room.membership != Membership.join) return false;
  try {
    return chatLoomSilencedRooms(room.client).contains(room.id) &&
        room.hasNewMessages;
  } catch (_) {
    return false;
  }
}

/// Whether a chat should be silent on the server: ignored, notification
/// mode "Muted", or muted with no end. [entity] is the metadata of the chat
/// or of the merged person it belongs to, [source] the chat's own.
bool chatLoomSilenceWanted({
  required bool ignored,
  required ConversationMetadata entity,
  required ConversationMetadata source,
  DateTime? now,
}) {
  if (ignored) return true;
  if ((source.notificationMode ?? entity.notificationMode) ==
      PersonalNotificationMode.muted) {
    return true;
  }
  final at = now ?? DateTime.now();
  bool forever(ConversationMetadata m) => m.mutedAt(at) && m.mutedUntil == null;
  return forever(entity) || forever(source);
}

/// What the account's rules should be: the rooms to silence and the rooms
/// ChatLoom knows (a rule for an unknown room is never removed, so a room
/// list that is still loading cannot lift a mute).
typedef PushRuleMirrorTarget = ({Set<String> silence, Set<String> known});

/// The target from ChatLoom's private state. Spaces and the private journal
/// are never touched (the journal keeps its own muted rule).
PushRuleMirrorTarget chatLoomPushRuleTarget(PersonalClient personal) {
  final projection = InboxProjection(personal);
  final silence = <String>{};
  final known = <String>{};
  final now = DateTime.now();
  for (final room in personal.client.rooms) {
    if (room.isSpace || PersonalPrivacy.isJournal(room)) continue;
    known.add(room.id);
    if (room.membership != Membership.join) continue;
    try {
      if (chatLoomSilenceWanted(
        ignored: projection.placementFor(room) == ChatPlacement.ignored,
        entity: projection.metadataFor(room),
        source: projection.metadataForEntity(room.id),
        now: now,
      )) {
        silence.add(room.id);
      }
    } catch (_) {
      // Unreadable metadata changes nothing on the server.
      known.remove(room.id);
    }
  }
  return (silence: silence, known: known);
}

/// One change to the account's rules. [roomId] names the room; the rule id
/// is always [chatLoomMuteRuleId].
enum PushRuleMirrorOp { put, enable, delete }

typedef PushRuleMirrorStep = ({PushRuleMirrorOp op, String roomId});

/// The steps that bring [rules] to [target]. [expected] holds rules this
/// device just wrote (room → present) that sync has not shown yet.
List<PushRuleMirrorStep> planPushRuleMirror(
  PushRuleSet rules,
  PushRuleMirrorTarget target, {
  Map<String, bool> expected = const {},
}) {
  final owned = <String, PushRule>{};
  for (final rule in rules.override ?? const <PushRule>[]) {
    final room = chatLoomMuteRuleRoom(rule.ruleId);
    if (room != null) owned[room] = rule;
  }
  final steps = <PushRuleMirrorStep>[];
  for (final room in target.silence) {
    final rule = owned[room];
    if (expected[room] == true) continue;
    if (rule == null || !_hasMuteShape(rule, room)) {
      steps.add((op: PushRuleMirrorOp.put, roomId: room));
    } else if (!rule.enabled) {
      steps.add((op: PushRuleMirrorOp.enable, roomId: room));
    }
  }
  for (final room in owned.keys) {
    if (target.silence.contains(room) || !target.known.contains(room)) {
      continue;
    }
    if (expected[room] == false) continue;
    steps.add((op: PushRuleMirrorOp.delete, roomId: room));
  }
  return steps;
}

/// The homeserver calls of the mirror. Only ChatLoom rule ids reach it.
abstract interface class PushRuleMirrorBackend {
  /// The account's rules, or null before they are known.
  PushRuleSet? get rules;
  Future<void> put(String ruleId, String roomId);
  Future<void> enable(String ruleId);
  Future<void> delete(String ruleId);
}

class ClientPushRuleMirrorBackend implements PushRuleMirrorBackend {
  final Client client;
  ClientPushRuleMirrorBackend(this.client);

  @override
  PushRuleSet? get rules => client.globalPushRules;

  @override
  Future<void> put(String ruleId, String roomId) => client.setPushRule(
    PushRuleKind.override,
    ruleId,
    const [],
    conditions: [
      PushCondition(kind: 'event_match', key: 'room_id', pattern: roomId),
    ],
  );

  @override
  Future<void> enable(String ruleId) =>
      client.setPushRuleEnabled(PushRuleKind.override, ruleId, true);

  @override
  Future<void> delete(String ruleId) =>
      client.deletePushRule(PushRuleKind.override, ruleId);
}

/// Keeps the account's ChatLoom rules in line with the private state.
class PushRuleMirror {
  final PushRuleMirrorBackend backend;

  /// The target, or null while private state is not ready (nothing runs).
  final PushRuleMirrorTarget? Function() target;
  final Duration debounce;
  final Duration spacing;
  final int maxStepsPerPass;
  final Duration passGap;
  final Duration backoffBase;
  final Duration backoffMax;

  /// How long a write this device made shadows the synced rules.
  final Duration expectTimeout;
  final DateTime Function() _now;

  PushRuleMirror({
    required this.backend,
    required this.target,
    this.debounce = const Duration(seconds: 3),
    this.spacing = const Duration(milliseconds: 250),
    this.maxStepsPerPass = 25,
    this.passGap = const Duration(seconds: 10),
    this.backoffBase = const Duration(seconds: 30),
    this.backoffMax = const Duration(minutes: 30),
    this.expectTimeout = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final _expected = <String, ({bool present, DateTime at})>{};
  Timer? _timer;
  bool _running = false;
  bool _dirty = false;
  bool _disposed = false;
  int _failures = 0;
  DateTime? _backoffUntil;

  @visibleForTesting
  int get failures => _failures;
  @visibleForTesting
  DateTime? get backoffUntil => _backoffUntil;

  /// Asks for a reconcile after the debounce (or the running backoff).
  void schedule([Duration? delay]) {
    if (_disposed) return;
    if (_running) {
      _dirty = true;
      return;
    }
    var wait = delay ?? debounce;
    final until = _backoffUntil;
    if (until != null) {
      final left = until.difference(_now());
      if (left > wait) wait = left;
    }
    _timer?.cancel();
    _timer = Timer(wait, () => unawaited(reconcile()));
  }

  /// One reconcile pass. Returns the number of requests sent.
  Future<int> reconcile() async {
    if (_disposed) return 0;
    if (_running) {
      _dirty = true;
      return 0;
    }
    final until = _backoffUntil;
    if (until != null && _now().isBefore(until)) {
      schedule(until.difference(_now()));
      return 0;
    }
    final PushRuleSet? rules;
    final PushRuleMirrorTarget? wanted;
    try {
      rules = backend.rules;
      wanted = target();
    } catch (e, s) {
      Logs().w('Push rule mirror: state unavailable', e, s);
      return 0;
    }
    // Rules not synced yet or private state not ready: a later change
    // schedules again.
    if (rules == null || wanted == null) return 0;
    final steps = planPushRuleMirror(
      rules,
      wanted,
      expected: _expectations(rules),
    );
    if (steps.isEmpty) return 0;
    _running = true;
    var sent = 0;
    try {
      for (final step in steps.take(maxStepsPerPass)) {
        if (_disposed) break;
        if (sent > 0) await Future<void>.delayed(spacing);
        final id = chatLoomMuteRuleId(step.roomId);
        assert(isChatLoomMuteRuleId(id));
        sent++;
        switch (step.op) {
          case PushRuleMirrorOp.put:
            await backend.put(id, step.roomId);
          case PushRuleMirrorOp.enable:
            await backend.enable(id);
          case PushRuleMirrorOp.delete:
            try {
              await backend.delete(id);
            } on MatrixException catch (e) {
              // Already gone (another device or client): done.
              if (e.error != MatrixError.M_NOT_FOUND) rethrow;
            }
        }
        _expected[step.roomId] = (
          present: step.op != PushRuleMirrorOp.delete,
          at: _now(),
        );
      }
      _failures = 0;
      _backoffUntil = null;
      if (steps.length > maxStepsPerPass) _dirty = true;
    } catch (e, s) {
      _failures++;
      var wait = backoffBase * math.pow(2, math.min(_failures - 1, 10));
      if (wait > backoffMax) wait = backoffMax;
      if (e is MatrixException) {
        final retry = e.retryAfterMs;
        if (retry != null && Duration(milliseconds: retry) > wait) {
          wait = Duration(milliseconds: retry);
        }
      }
      _backoffUntil = _now().add(wait);
      Logs().w(
        'Push rule mirror: write failed, retry in ${wait.inSeconds} s',
        e is MatrixException ? e.errcode : e.runtimeType,
        s,
      );
      _dirty = true;
    } finally {
      _running = false;
    }
    if (_dirty && !_disposed) {
      _dirty = false;
      schedule(_backoffUntil == null ? passGap : null);
    }
    return sent;
  }

  /// This device's recent writes that sync has not confirmed yet.
  Map<String, bool> _expectations(PushRuleSet rules) {
    if (_expected.isEmpty) return const {};
    final present = {
      for (final rule in rules.override ?? const <PushRule>[])
        ?chatLoomMuteRuleRoom(rule.ruleId),
    };
    final now = _now();
    _expected.removeWhere(
      (room, e) =>
          now.difference(e.at) > expectTimeout ||
          present.contains(room) == e.present,
    );
    return {for (final e in _expected.entries) e.key: e.value.present};
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  // One mirror per logged-in account of the UI isolate.
  static final _mirrors = <Client, _Attached>{};

  /// Starts mirroring for [client] (idempotent): the first pass runs once
  /// private sync is ready and the account's rules are known.
  static void startFor(Client client, PersonalClient personal) {
    if (kIsWeb || _mirrors.containsKey(client)) return;
    final mirror = PushRuleMirror(
      backend: ClientPushRuleMirrorBackend(client),
      target: () => personal.ready && client.isLogged()
          ? chatLoomPushRuleTarget(personal)
          : null,
    );
    var revision = -1;
    final attached = _Attached(mirror)
      ..changes = personal.changes.listen((_) {
        // Pure status updates (worker heartbeat) change no mute.
        if (personal.contentRevision == revision) return;
        revision = personal.contentRevision;
        mirror.schedule();
      })
      ..rules = client.onSync.stream
          .where(
            (update) =>
                update.accountData?.any(
                  (data) => data.type == 'm.push_rules',
                ) ??
                false,
          )
          .listen((_) => mirror.schedule());
    _mirrors[client] = attached;
    mirror.schedule();
  }

  /// Stops mirroring for [client] (logout). Rules stay on the server.
  static void stopFor(Client client) => _mirrors.remove(client)?.dispose();
}

class _Attached {
  final PushRuleMirror mirror;
  StreamSubscription<int>? changes;
  StreamSubscription<SyncUpdate>? rules;
  _Attached(this.mirror);
  void dispose() {
    mirror.dispose();
    unawaited(changes?.cancel());
    unawaited(rules?.cancel());
  }
}
