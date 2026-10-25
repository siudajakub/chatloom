// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/network_login/beeper_account_bridges.dart';
import 'package:chatloom/personal/network_login/network_login_api.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

// Which bridges "Add network" offers.
//
// bridgev2 has no endpoint that lists bridges (provisioning `whoami` answers
// for one bridge). The list is built from these sources, and every entry is
// confirmed with a read-only `GET /v3/whoami` before it can sign in:
//
// 1. on Beeper, the account's bridges from Beeper's account API
//    (`api.beeper.com/whoami`, BR-03 approved by J on 2026-10-25;
//    `beeper_account_bridges.dart`);
// 2. bridges the account's rooms declare (`m.bridge` & co., as search does);
// 3. `--dart-define=CHATLOOM_BRIDGE_BOTS=@a:x,@b:y` for other names;
// 4. only when (1) is unavailable (it failed, or not a Beeper account): the
//    usual bridge names. bbctl registers self-hosted bridges as `sh-<name>`
//    with the bot `@sh-<name>bot:beeper.local`; a standard appservice bridge
//    on an own homeserver uses `@<name>bot:<server>`.
//
// A guessed name that does not answer is not shown. Bridges the account
// lists or its rooms declare stay listed when the app can't reach them, with
// the bridge chat as the way to sign in.

/// Bridge names tried when no room names them yet (bbctl / mautrix types).
const addNetworkBridgeNames = [
  'whatsapp',
  'telegram',
  'signal',
  'meta',
  'instagram',
  'messenger',
  'slack',
  'discord',
  'gmessages',
  'linkedin',
  'twitter',
  'bluesky',
  'googlechat',
];

/// Where provisioning requests go for this account, with a longer timeout
/// for sign-in steps (the bridge may connect to the network first, and QR
/// steps are long polls).
@immutable
class NetworkLoginBackend {
  const NetworkLoginBackend({
    required this.transport,
    required this.loginTransport,
    required this.userId,
    this.reaches,
    this.hungryserv = false,
    this.disabledReason,
    this.accountBridges,
  });

  const NetworkLoginBackend.disabled(String reason, {this.userId = ''})
    : transport = null,
      loginTransport = null,
      reaches = null,
      hungryserv = false,
      disabledReason = reason,
      accountBridges = null;

  /// Short requests (whoami, flows, cancel, logout).
  final BridgeProvisioningTransport? transport;

  /// Start, submit and long-poll requests.
  final BridgeProvisioningTransport? loginTransport;
  final String userId;

  /// Bridges the transport can reach (null: all).
  final bool Function(BridgeEndpoint bridge)? reaches;

  /// Beeper's hungryserv route (bbctl bridge names).
  final bool hungryserv;
  final String? disabledReason;

  /// The account's bridges from its provider (Beeper's account API), or
  /// null when there is no such list.
  final Future<List<BridgeEndpoint>> Function()? accountBridges;

  bool get enabled => transport != null;

  bool canReach(BridgeEndpoint bridge) =>
      enabled && (reaches?.call(bridge) ?? true);

  NetworkLoginApi? get api {
    final transport = this.transport;
    if (transport == null) return null;
    return NetworkLoginApi(transport, waitTransport: loginTransport);
  }

  /// Long enough for a bridge to connect and for one long poll; a poll cut
  /// short is repeated and joins the same wait.
  static const loginTimeout = Duration(minutes: 2);

  /// The same route contact search uses ([BridgeDirectory]).
  factory NetworkLoginBackend.of(Client client) {
    final directory = BridgeDirectory.of(client);
    final base = directory.api?.transport;
    final userId = client.userID ?? '';
    final beeper =
        base is BeeperProvisioningTransport && base.overrideUrl.isEmpty
        ? base
        : null;
    final hungryserv = beeper != null;
    if (base == null) {
      return NetworkLoginBackend.disabled(
        directory.disabledReason ?? 'Bridges can’t be reached from the app.',
        userId: userId,
      );
    }
    return NetworkLoginBackend(
      transport: base,
      loginTransport: base is BeeperProvisioningTransport
          ? BeeperProvisioningTransport(
              httpClient: base.httpClient,
              homeserver: base.homeserver,
              userId: base.userId,
              accessToken: base.accessToken,
              overrideUrl: base.overrideUrl,
              timeout: loginTimeout,
            )
          : base,
      userId: userId,
      reaches: directory.reaches,
      hungryserv: hungryserv,
      accountBridges:
          beeper != null && beeperAccountWhoamiUri(beeper.homeserver) != null
          ? () => fetchBeeperAccountBridges(
              httpClient: beeper.httpClient,
              homeserver: beeper.homeserver,
              accessToken: beeper.accessToken,
            )
          : null,
    );
  }
}

/// Bridges worth asking for [userId]: the account's [listed] bridges and the
/// [discovered] ones, then [extraBots]; the usual names on the route's
/// domain only when there is no account list. One per bot.
List<BridgeEndpoint> addNetworkCandidates({
  required List<BridgeEndpoint> discovered,
  required String userId,
  required bool hungryserv,
  List<BridgeEndpoint>? listed,
  String extraBots = const String.fromEnvironment('CHATLOOM_BRIDGE_BOTS'),
}) {
  final colon = userId.indexOf(':');
  final domain = hungryserv
      ? 'beeper.local'
      : colon < 0
      ? ''
      : userId.substring(colon + 1);
  final found = <String, BridgeEndpoint>{
    for (final bridge in discovered) bridge.botId: bridge,
  };
  for (final bridge in listed ?? const <BridgeEndpoint>[]) {
    found.putIfAbsent(bridge.botId, () => bridge);
  }
  BridgeEndpoint guess(String bot, String name) {
    final network = canonicalNetwork(name) ?? name;
    return BridgeEndpoint(
      botId: bot,
      network: network,
      label: notionNetworkLabel(network),
    );
  }

  if (listed == null && domain.isNotEmpty) {
    for (final name in addNetworkBridgeNames) {
      final bot = hungryserv ? '@sh-${name}bot:$domain' : '@${name}bot:$domain';
      found.putIfAbsent(bot, () => guess(bot, name));
    }
  }
  for (final raw in extraBots.split(',')) {
    final bot = raw.trim();
    if (!bot.isValidMatrixIdStrict()) continue;
    var local = bot.substring(1, bot.indexOf(':'));
    if (local.startsWith('sh-')) local = local.substring(3);
    if (local.endsWith('bot')) local = local.substring(0, local.length - 3);
    found.putIfAbsent(bot, () => guess(bot, local));
  }
  return found.values.toList(growable: false);
}

enum AddableBridgeStatus {
  /// The bridge answered: it can sign in from the app.
  ready,

  /// Known from rooms, but the app can't reach it (bridge chat only).
  unreachable,
}

/// One bridge the wizard offers.
@immutable
class AddableBridge {
  const AddableBridge({
    required this.bridge,
    required this.status,
    this.whoami,
    this.flows = const [],
  });

  final BridgeEndpoint bridge;
  final AddableBridgeStatus status;
  final BridgeWhoami? whoami;

  /// `login_flows` from whoami (saves a request when present).
  final List<NetworkLoginFlow> flows;

  /// Network key from the bridge's own answer when it has one.
  String get network {
    final whoami = this.whoami;
    if (whoami == null) return bridge.network;
    return canonicalNetwork(whoami.networkId) ??
        canonicalNetwork(whoami.networkName) ??
        bridge.network;
  }

  String get label {
    final known = notionNetworkLabel(network);
    if (known != network) return known;
    final name = whoami?.networkName ?? '';
    return name.isNotEmpty ? name : bridge.label;
  }

  /// Signed-in accounts the bridge reported.
  List<String> get accounts => [
    for (final login in whoami?.usableLogins ?? const <BridgeLogin>[])
      login.name.isNotEmpty ? login.name : 'Account',
  ];
}

/// Asks each candidate's whoami (in parallel, read-only) and returns the
/// bridges to offer, sorted by label. Guesses that don't answer are
/// dropped; listed and discovered bridges stay as
/// [AddableBridgeStatus.unreachable].
Future<List<AddableBridge>> loadAddableBridges({
  required NetworkLoginBackend backend,
  required List<BridgeEndpoint> discovered,
  List<BridgeEndpoint>? candidates,
  String extraBots = const String.fromEnvironment('CHATLOOM_BRIDGE_BOTS'),
}) async {
  List<BridgeEndpoint>? listed;
  final account = backend.accountBridges;
  if (candidates == null && account != null) {
    try {
      listed = await account();
    } on BeeperAccountException catch (error) {
      // Status only: the answer carries account data.
      Logs().w('background_failed beeper_account_bridges HTTP ${error.status}');
    } catch (error) {
      Logs().w('background_failed beeper_account_bridges ${error.runtimeType}');
    }
  }
  final all =
      candidates ??
      addNetworkCandidates(
        discovered: discovered,
        userId: backend.userId,
        hungryserv: backend.hungryserv,
        listed: listed,
        extraBots: extraBots,
      );
  final known = {
    for (final bridge in discovered) bridge.botId,
    for (final bridge in listed ?? const <BridgeEndpoint>[]) bridge.botId,
  };
  final transport = backend.transport;
  Future<AddableBridge?> probe(BridgeEndpoint bridge) async {
    final listed = known.contains(bridge.botId);
    if (transport == null || !backend.canReach(bridge)) {
      return listed
          ? AddableBridge(
              bridge: bridge,
              status: AddableBridgeStatus.unreachable,
            )
          : null;
    }
    try {
      final json = await transport.send(
        bridge,
        const BridgeProvisioningRequest('GET', '/v3/whoami'),
      );
      final whoami = BridgeWhoami.fromJson(json);
      if (whoami == null || whoami.bridgeBot != bridge.botId) {
        throw const BridgeProvisioningException(
          200,
          errcode: 'CHATLOOM_NOT_A_BRIDGE',
        );
      }
      return AddableBridge(
        bridge: bridge,
        status: AddableBridgeStatus.ready,
        whoami: whoami,
        flows: NetworkLoginFlow.listFromJson(
          json is Map ? json['login_flows'] : null,
        ),
      );
    } catch (error) {
      if (!listed) return null;
      logBackgroundError('add_network_probe', error);
      return AddableBridge(
        bridge: bridge,
        status: AddableBridgeStatus.unreachable,
      );
    }
  }

  final results = await Future.wait([for (final bridge in all) probe(bridge)]);
  final list = [for (final result in results) ?result];
  // One entry per network: a bridge that answers beats one that doesn't.
  final byNetwork = <String, AddableBridge>{};
  final extra = <AddableBridge>[];
  for (final entry in list) {
    final current = byNetwork[entry.network];
    if (current == null) {
      byNetwork[entry.network] = entry;
    } else if (current.status == AddableBridgeStatus.unreachable &&
        entry.status == AddableBridgeStatus.ready) {
      byNetwork[entry.network] = entry;
    } else if (entry.status == AddableBridgeStatus.ready &&
        current.status == AddableBridgeStatus.ready) {
      extra.add(entry); // Two working bridges for one network: show both.
    }
  }
  return [...byNetwork.values, ...extra]..sort((a, b) {
    final byLabel = a.label.compareTo(b.label);
    return byLabel != 0 ? byLabel : a.bridge.botId.compareTo(b.bridge.botId);
  });
}

/// After a completed sign-in: refresh whoami (search, sign-out) and the
/// network's health, and return the new account's name when reported.
Future<String?> refreshAfterLogin(
  Client client,
  BridgeEndpoint bridge,
  String network,
  String? loginId,
) async {
  final directory = BridgeDirectory.of(client);
  String? name;
  if (directory.api != null) {
    try {
      final whoami = await directory.refreshLogins(bridge);
      final login = whoami.logins
          .where((login) => login.id == loginId)
          .firstOrNull;
      name = login?.name;
    } catch (error) {
      logBackgroundError('network_login_whoami', error);
    }
  }
  unawaited(BridgeHealthMonitor.of(client).refresh(network, force: true));
  return name;
}

/// Whether "Sign in" on a network page can use this wizard for [network]:
/// the account has a provisioning route and a bridge for it is known.
bool canSignInFromApp(Client client, String network) {
  final backend = NetworkLoginBackend.of(client);
  if (!backend.enabled) return false;
  return discoverBridges(
    client.rooms,
  ).any((bridge) => bridge.network == network && backend.canReach(bridge));
}
