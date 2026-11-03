// SPDX-License-Identifier: AGPL-3.0-or-later
// Pure Dart (no Flutter): the network-specific half of a round send.
import 'package:matrix/matrix.dart';
import 'package:personal_core/bridge_capabilities.dart';
import 'package:personal_core/personal_core.dart';

import 'messenger_round_gate.dart';
import 'telegram_room_binding.dart';

export 'messenger_round_gate.dart' show RoundRouteCapabilities;

/// Where a round goes and what that network needs. The capture, staging,
/// encrypted outbox and upload are shared; Telegram adds the bridge trust
/// prompt, silent sends and its media controls (played, state, forward),
/// which stay in [TelegramRoomBinding] and never apply to Meta routes.
sealed class RoundSendRoute {
  const RoundSendRoute();

  /// [RoundSendTarget.network] of this route.
  String get network;

  /// Network name for the recorder and failure copy.
  String get label;

  /// Whether the user must confirm the bridge before the first send.
  bool get needsTrust;

  /// The identity of the bound bridge, or null when nothing may be sent.
  RoundBridgeIdentity? bound(Room room);

  /// The bridge a send would freeze, before any trust decision.
  RoundBridgeIdentity? candidate(Room room);

  /// Current capabilities from room state (no network request).
  RoundRouteCapabilities? capabilities(Room room);

  /// Measures the upload limit, then returns the current capabilities.
  Future<RoundRouteCapabilities?> preflight(Room room);

  bool uploadLimitUnreachable(Client client);

  RoundGateReport diagnose(
    Room room, {
    bool silent = false,
    bool requireUploadLimit = false,
  });

  static const telegram = TelegramRoundRoute._();
  static const messenger = MetaRoundRoute._('facebook', 'Messenger');
  static const instagram = MetaRoundRoute._('instagram', 'Instagram');

  static RoundSendRoute? forNetwork(String network) => switch (network) {
    'telegram' => telegram,
    'facebook' => messenger,
    'instagram' => instagram,
    _ => null,
  };

  /// Telegram first (a valid but untrusted bridge still counts), then
  /// Messenger or Instagram. Null in every other chat.
  static RoundSendRoute? forRoom(Room room) {
    if (TelegramRoomBinding.unverifiedCandidate(room) != null) return telegram;
    final meta = MessengerRoundGate.of(room);
    if (meta != null) return forNetwork(meta.network);
    return null;
  }

  /// The route an outgoing round [content] was prepared for.
  static RoundSendRoute forContent(Map<String, dynamic> content) {
    if (RoundVideoDescriptor.isTelegramRound(content)) return telegram;
    final info = content['info'];
    return info is Map && info[roundVideoNetworkMarker] == 'instagram'
        ? instagram
        : messenger; // Existing Messenger rounds predate the network marker.
  }

  /// Why a round can or cannot be recorded in [room]: the Telegram gate,
  /// and the Meta gate when the chat is not a Telegram chat.
  static RoundGateReport diagnoseRoom(
    Room room, {
    bool silent = false,
    bool requireUploadLimit = false,
  }) {
    final report = TelegramRoomBinding.diagnose(
      room,
      silent: silent,
      requireUploadLimit: requireUploadLimit,
    );
    if (report.code != RoundGateCode.notTelegram) return report;
    return MessengerRoundGate.diagnose(
      room,
      silent: silent,
      requireUploadLimit: requireUploadLimit,
    );
  }
}

final class TelegramRoundRoute extends RoundSendRoute {
  const TelegramRoundRoute._();
  @override
  String get network => 'telegram';
  @override
  String get label => 'Telegram';
  @override
  bool get needsTrust => true;
  @override
  RoundBridgeIdentity? bound(Room room) =>
      TelegramRoomBinding.of(room)?.identity;
  @override
  RoundBridgeIdentity? candidate(Room room) =>
      TelegramRoomBinding.unverifiedCandidate(room)?.identity;
  @override
  RoundRouteCapabilities? capabilities(Room room) {
    final binding = TelegramRoomBinding.of(room);
    return binding == null ? null : _wrap(binding.capabilities(room));
  }

  @override
  Future<RoundRouteCapabilities?> preflight(Room room) async {
    final caps = await TelegramRoomBinding.preflight(room);
    return caps == null ? null : _wrap(caps);
  }

  static RoundRouteCapabilities _wrap(RoundBridgeCapabilities caps) =>
      RoundRouteCapabilities(
        allowed: caps.result.allowed,
        profile: caps.profile,
        silentAllowed: caps.extension.operation('silent_send').allowed,
      );

  @override
  bool uploadLimitUnreachable(Client client) =>
      TelegramRoomBinding.uploadLimitUnreachable(client);
  @override
  RoundGateReport diagnose(
    Room room, {
    bool silent = false,
    bool requireUploadLimit = false,
  }) => TelegramRoomBinding.diagnose(
    room,
    silent: silent,
    requireUploadLimit: requireUploadLimit,
  );
}

final class MetaRoundRoute extends RoundSendRoute {
  const MetaRoundRoute._(this.network, this.label);
  @override
  final String network;
  @override
  final String label;
  @override
  bool get needsTrust => false;
  @override
  RoundBridgeIdentity? bound(Room room) =>
      MessengerRoundGate.of(room, network: network)?.identity;
  @override
  RoundBridgeIdentity? candidate(Room room) => bound(room);
  @override
  RoundRouteCapabilities? capabilities(Room room) =>
      MessengerRoundGate.of(room, network: network)?.capabilities(room);
  @override
  Future<RoundRouteCapabilities?> preflight(Room room) =>
      MessengerRoundGate.preflight(room, network: network);
  @override
  bool uploadLimitUnreachable(Client client) =>
      MessengerRoundGate.uploadLimitUnreachable(client);
  @override
  RoundGateReport diagnose(
    Room room, {
    bool silent = false,
    bool requireUploadLimit = false,
  }) => MessengerRoundGate.diagnose(
    room,
    network: network,
    silent: silent,
    requireUploadLimit: requireUploadLimit,
  );
}
