// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

const _bridgeTypes = ['m.bridge', 'uk.half-shot.bridge', 'com.beeper.bridge'];

String? canonicalNetwork(Object? value) {
  if (value is! String) return null;
  return switch (value.trim().toLowerCase()) {
    'facebook' || 'facebookgo' || 'messenger' || 'meta' => 'messenger',
    'instagram' || 'instagramgo' => 'instagram',
    'telegram' || 'telegramgo' => 'telegram',
    'whatsapp' || 'whatsappgo' => 'whatsapp',
    'slack' || 'slackgo' => 'slack',
    'signal' || 'signalgo' => 'signal',
    'discord' || 'discordgo' => 'discord',
    'imessage' => 'imessage',
    'sms' => 'sms',
    'matrix' => 'matrix',
    _ => null,
  };
}

Iterable<StrippedStateEvent> _infos(Room room) sync* {
  for (final type in _bridgeTypes) {
    yield* room.states[type]?.values ?? <StrippedStateEvent>[];
  }
}

class ConversationClassification {
  final String network;
  final bool isGroup;
  final bool technical;
  const ConversationClassification(this.network, this.isGroup, this.technical);
}

/// Uses only already-loaded state. A name or a message never identifies a bot.
class ConversationClassifier {
  final Set<String> _serviceMembers = {};
  late final int _serviceSignature = Object.hashAllUnordered(_serviceMembers);

  /// Per-room memo: classification is reused while the room's relevant state
  /// is unchanged (see [_signature]); `classify` used to walk every member
  /// state up to three times per room per inbox rebuild.
  static final _memo = Expando<(int, ConversationClassification)>(
    'conversation classification',
  );

  /// Classifications computed (not served from the memo); tests only.
  static int debugComputations = 0;

  ConversationClassifier(Iterable<Room> rooms) {
    for (final room in rooms) {
      for (final info in _infos(room)) {
        final bot = info.content['bridgebot'];
        if (bot is String && bot.isValidMatrixIdStrict())
          _serviceMembers.add(bot);
      }
      final services = room
          .getState('io.element.functional_members')
          ?.content['service_members'];
      if (services is List) {
        _serviceMembers.addAll(
          services.whereType<String>().where(
            (id) => id.isValidMatrixIdStrict(),
          ),
        );
      }
    }
  }

  /// Whether this classifier already knows every service member [room]
  /// declares, i.e. a changed [room] cannot change other rooms' results.
  bool covers(Room room) {
    for (final info in _infos(room)) {
      final bot = info.content['bridgebot'];
      if (bot is String &&
          bot.isValidMatrixIdStrict() &&
          !_serviceMembers.contains(bot)) {
        return false;
      }
    }
    final services = room
        .getState('io.element.functional_members')
        ?.content['service_members'];
    if (services is List) {
      for (final id in services.whereType<String>()) {
        if (id.isValidMatrixIdStrict() && !_serviceMembers.contains(id)) {
          return false;
        }
      }
    }
    return true;
  }

  /// Cheap identity signature of everything [classify] reads. State events
  /// are replaced (never mutated) when they change, so identity hashes of the
  /// loaded member/bridge events detect every relevant update.
  int _signature(Room room) {
    var members = 0;
    final memberStates = room.states[EventTypes.RoomMember];
    if (memberStates != null) {
      for (final event in memberStates.values) {
        members = (members * 31 + identityHashCode(event)) & 0x3fffffff;
      }
    }
    return Object.hashAll([
      _serviceSignature,
      room.client.userID,
      room.membership,
      room.isSpace,
      room.summary.mJoinedMemberCount,
      room.summary.mInvitedMemberCount,
      Object.hashAll(room.summary.mHeroes ?? const []),
      room.directChatMatrixID,
      memberStates?.length,
      members,
      for (final info in _infos(room)) identityHashCode(info),
      identityHashCode(room.getState('io.element.functional_members')),
      identityHashCode(room.getState(EventTypes.RoomCreate)),
    ]);
  }

  ConversationClassification classify(Room room) {
    final signature = _signature(room);
    final cached = _memo[room];
    if (cached != null && cached.$1 == signature) return cached.$2;
    final result = _classify(room);
    _memo[room] = (signature, result);
    return result;
  }

  ConversationClassification _classify(Room room) {
    debugComputations++;
    final infos = _infos(room).toList();
    final networks = <String>{};
    for (final info in infos) {
      final protocol = info.content['protocol'];
      if (protocol is! Map) continue;
      final network =
          canonicalNetwork(protocol['id']) ??
          canonicalNetwork(protocol['displayname']);
      if (network != null) networks.add(network);
    }
    final participants = room.getParticipants([
      Membership.join,
      Membership.invite,
    ]);
    final peers = participants
        .map((user) => user.id)
        .where((id) => id != room.client.userID)
        .toSet();
    final joined = room.summary.mJoinedMemberCount;
    final invited = room.summary.mInvitedMemberCount;
    final complete =
        joined != null &&
        invited != null &&
        participants.length == joined + invited;
    final direct = room.directChatMatrixID;
    final botDirect =
        direct != null &&
        _serviceMembers.contains(direct) &&
        joined == 2 &&
        (invited ?? 0) == 0 &&
        peers.every(_serviceMembers.contains) &&
        (room.summary.mHeroes ?? []).every(
          (id) => id == room.client.userID || _serviceMembers.contains(id),
        );
    final technical =
        !room.isSpace &&
        ((complete &&
                peers.isNotEmpty &&
                peers.every(_serviceMembers.contains)) ||
            botDirect);
    return ConversationClassification(
      networks.length == 1
          ? networks.single
          : infos.isEmpty
          ? 'matrix'
          : 'other',
      !room.isDirectChatForDisplay,
      technical,
    );
  }
}
