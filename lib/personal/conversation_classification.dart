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

  ConversationClassification classify(Room room) {
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
    final peers = room
        .getParticipants([Membership.join, Membership.invite])
        .map((user) => user.id)
        .where((id) => id != room.client.userID)
        .toSet();
    final joined = room.summary.mJoinedMemberCount;
    final invited = room.summary.mInvitedMemberCount;
    final complete =
        joined != null &&
        invited != null &&
        room.getParticipants([Membership.join, Membership.invite]).length ==
            joined + invited;
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
