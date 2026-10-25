// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:http/http.dart' as http;

// The bridges of a Beeper account (wave 8, BR-03 approved by J 2026-10-25).
//
// Beeper's account API answers `GET https://api.<beeper domain>/whoami`
// with the account's bridges, the same call bbctl makes
// (beeper/bridge-manager `api/beeperapi`): `user.bridges` maps a bridge
// name (`sh-whatsapp` for a self-hosted bbctl bridge) to its state, with
// `bridgeState.bridgeType` naming the network.
//
// The answer also carries account data (user info, remote states), so the
// body is parsed here and dropped: only bridge names and types leave this
// file, and only the HTTP status is ever logged.

/// A failed account-API request: the HTTP status only (0: no answer).
class BeeperAccountException implements Exception {
  const BeeperAccountException(this.status);
  final int status;

  @override
  String toString() => 'BeeperAccountException(HTTP $status)';
}

/// `https://api.beeper.com/whoami` for `https://matrix.beeper.com`, or null
/// when [homeserver] is not a Beeper host.
Uri? beeperAccountWhoamiUri(Uri homeserver) {
  final match = RegExp(
    r'(?:^|\.)(beeper(?:-staging|-dev)?\.com)$',
  ).firstMatch(homeserver.host);
  if (match == null) return null;
  return Uri(scheme: 'https', host: 'api.${match.group(1)}', path: '/whoami');
}

/// The self-hosted (bbctl) bridges in a Beeper whoami answer, as endpoints
/// on `beeper.local` (the only ones the hungryserv route reaches). Beeper's
/// cloud bridges are left out: their bot ids are not in the answer.
List<BridgeEndpoint> beeperBridgesFromWhoami(Object? json) {
  final user = json is Map ? json['user'] : null;
  final bridges = user is Map ? user['bridges'] : null;
  if (bridges is! Map) {
    throw const BeeperAccountException(200);
  }
  final result = <BridgeEndpoint>[];
  for (final MapEntry(:key, :value) in bridges.entries) {
    if (key is! String || !RegExp(r'^sh-[a-z0-9-]+$').hasMatch(key)) continue;
    final state = value is Map ? value['bridgeState'] : null;
    final type = state is Map ? state['bridgeType'] : null;
    final short = key.substring(3);
    final network =
        canonicalNetwork(type) ??
        canonicalNetwork(short) ??
        (type is String && type.isNotEmpty ? type.toLowerCase() : short);
    result.add(
      BridgeEndpoint(
        botId: '@${key}bot:beeper.local',
        network: network,
        label: notionNetworkLabel(network),
      ),
    );
  }
  result.sort((a, b) => a.botId.compareTo(b.botId));
  return result;
}

/// Asks Beeper's account API for the account's self-hosted bridges. The
/// access token goes only to Beeper's own API origin.
Future<List<BridgeEndpoint>> fetchBeeperAccountBridges({
  required http.Client httpClient,
  required Uri homeserver,
  required String? Function() accessToken,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final uri = beeperAccountWhoamiUri(homeserver);
  final token = accessToken();
  if (uri == null || token == null || token.isEmpty) {
    throw const BeeperAccountException(0);
  }
  final http.Response response;
  try {
    response = await httpClient
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        )
        .timeout(timeout);
  } catch (_) {
    // Network errors may echo the URL; report only that nothing came back.
    throw const BeeperAccountException(0);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw BeeperAccountException(response.statusCode);
  }
  Object? json;
  try {
    json = jsonDecode(response.body);
  } catch (_) {
    throw BeeperAccountException(response.statusCode);
  }
  return beeperBridgesFromWhoami(json);
}
