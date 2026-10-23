// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A bridge known from room state (`m.bridge` and friends): its bot, its
/// ghost namespace and the network it serves.
///
/// bbctl and Beeper name a bridge's bot `@<bridge>bot:<domain>` and its
/// ghosts `@<bridge>_<id>:<domain>` (`@sh-whatsappbot:beeper.local`,
/// `@sh-whatsapp_48600100200:beeper.local`).
@immutable
class BridgeEndpoint {
  const BridgeEndpoint({
    required this.botId,
    required this.network,
    required this.label,
  });

  /// The bridge bot, e.g. `@sh-whatsappbot:beeper.local`.
  final String botId;

  /// Canonical network key (`whatsapp`, `telegram`, …) or the raw protocol
  /// id for networks the app has no name for (`linkedin`).
  final String network;

  /// Human network name for headers ("WhatsApp").
  final String label;

  String get _localpart {
    final colon = botId.indexOf(':');
    return botId.substring(1, colon < 0 ? botId.length : colon);
  }

  /// The bridge (appservice) name: the bot localpart without `bot`.
  String get name {
    final local = _localpart;
    return local.endsWith('bot') ? local.substring(0, local.length - 3) : local;
  }

  /// The server part of the bot id (`beeper.local`).
  String get domain {
    final colon = botId.indexOf(':');
    return colon < 0 ? '' : botId.substring(colon + 1);
  }

  /// Whether [userId] is one of this bridge's ghosts.
  bool ownsGhost(String userId) =>
      name.isNotEmpty &&
      userId.startsWith('@${name}_') &&
      userId.endsWith(':$domain') &&
      userId != botId;

  @override
  bool operator ==(Object other) =>
      other is BridgeEndpoint && other.botId == botId;

  @override
  int get hashCode => botId.hashCode;
}

/// One remote login of a bridge (a WhatsApp number, a Telegram account).
@immutable
class BridgeLogin {
  const BridgeLogin({
    required this.id,
    required this.name,
    this.state,
    this.stateDetails,
  });

  final String id;
  final String name;

  /// bridgev2 state event (`CONNECTED`, `BAD_CREDENTIALS`, `LOGGED_OUT`, …).
  final String? state;

  /// The whole bridge state object (`state_event`, `timestamp`, `error`,
  /// `user_action`, …) for the network status; read through
  /// `BridgeStateReport.fromLogin`, never logged.
  final Map<Object?, Object?>? stateDetails;

  /// Logged out or rejected logins cannot list contacts or start chats.
  bool get usable => state != 'BAD_CREDENTIALS' && state != 'LOGGED_OUT';

  static BridgeLogin? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final name = json['name'];
    final state = json['state'];
    final stateEvent = state is Map ? state['state_event'] : null;
    final legacy = json['state_event'];
    return BridgeLogin(
      id: id,
      name: name is String ? name : '',
      stateDetails: state is Map
          ? state
          : legacy is String
          ? {'state_event': legacy}
          : null,
      state: stateEvent is String
          ? stateEvent
          : legacy is String
          ? legacy
          : null,
    );
  }
}

/// `GET /v3/whoami` of the bridgev2 provisioning API.
@immutable
class BridgeWhoami {
  const BridgeWhoami({
    required this.bridgeBot,
    required this.networkName,
    required this.networkId,
    required this.logins,
    this.commandPrefix = '',
    this.managementRoom,
  });

  final String bridgeBot;
  final String networkName;
  final String networkId;
  final List<BridgeLogin> logins;

  /// The bridge's `command_prefix` (`!wa`); empty when not reported.
  final String commandPrefix;

  /// The user's management room with the bridge bot, where commands need
  /// no prefix (`management_room`, omitted until one exists).
  final String? managementRoom;

  List<BridgeLogin> get usableLogins =>
      logins.where((login) => login.usable).toList(growable: false);

  /// Null unless [json] is a bridgev2 whoami: a proxy or route that answers
  /// something else must not count as a working bridge.
  static BridgeWhoami? fromJson(Object? json) {
    if (json is! Map) return null;
    final bot = json['bridge_bot'];
    final network = json['network'];
    final logins = json['logins'];
    if (bot is! String || network is! Map) return null;
    final name = network['displayname'];
    final id = network['network_id'];
    final prefix = json['command_prefix'];
    final management = json['management_room'];
    return BridgeWhoami(
      bridgeBot: bot,
      networkName: name is String ? name : '',
      networkId: id is String ? id : '',
      commandPrefix: prefix is String && !prefix.contains(RegExp(r'\s'))
          ? prefix
          : '',
      managementRoom: management is String && management.startsWith('!')
          ? management
          : null,
      logins: [
        if (logins is List)
          for (final login in logins) ?BridgeLogin.fromJson(login),
      ],
    );
  }
}

/// `GET /v3/capabilities` → `resolve_identifier` of bridgev2
/// (`ProvisioningCapabilities` in mautrix-go `bridgev2/networkinterface.go`).
@immutable
class BridgeProvisioningCapabilities {
  const BridgeProvisioningCapabilities({
    this.createDm = false,
    this.lookupPhone = false,
    this.lookupEmail = false,
    this.lookupUsername = false,
    this.anyPhone = false,
    this.contactList = false,
    this.search = false,
  });

  final bool createDm;
  final bool lookupPhone;
  final bool lookupEmail;
  final bool lookupUsername;
  final bool anyPhone;
  final bool contactList;
  final bool search;

  bool get lookup => lookupPhone || lookupEmail || lookupUsername;

  static const none = BridgeProvisioningCapabilities();

  static BridgeProvisioningCapabilities fromJson(Object? json) {
    final resolve = json is Map ? json['resolve_identifier'] : null;
    if (resolve is! Map) return none;
    bool flag(String key) => resolve[key] == true;
    return BridgeProvisioningCapabilities(
      createDm: flag('create_dm'),
      lookupPhone: flag('lookup_phone'),
      lookupEmail: flag('lookup_email'),
      lookupUsername: flag('lookup_username'),
      anyPhone: flag('any_phone'),
      contactList: flag('contact_list'),
      search: flag('search'),
    );
  }
}

/// A person on a network as the bridge describes it (`RespResolveIdentifier`
/// in mautrix-go `bridgev2/provisionutil`). [ghostId] and [dmRoomId] are
/// internal keys; the UI never shows them.
@immutable
class BridgeContact {
  const BridgeContact({
    required this.id,
    this.name = '',
    this.avatarUrl,
    this.identifiers = const [],
    this.ghostId,
    this.dmRoomId,
  });

  /// The network user id.
  final String id;
  final String name;
  final Uri? avatarUrl;

  /// Network identifiers such as `tel:+48600100200` or `telegram:anna`.
  final List<String> identifiers;
  final String? ghostId;
  final String? dmRoomId;

  /// The identifier to show under the name (a phone number or @username),
  /// never a Matrix id.
  String? get displayIdentifier {
    for (final raw in identifiers) {
      final colon = raw.indexOf(':');
      if (colon <= 0) continue;
      final scheme = raw.substring(0, colon);
      final value = raw.substring(colon + 1);
      if (value.isEmpty || value.contains(':')) continue;
      return switch (scheme) {
        'tel' || 'email' => value,
        _ => value.startsWith('@') ? value : '@$value',
      };
    }
    return null;
  }

  static BridgeContact? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final name = json['name'];
    final avatar = json['avatar_url'];
    final identifiers = json['identifiers'];
    final ghost = json['mxid'];
    final room = json['dm_room_mxid'];
    final avatarUri = avatar is String && avatar.startsWith('mxc://')
        ? Uri.tryParse(avatar)
        : null;
    return BridgeContact(
      id: id,
      name: name is String ? name.trim() : '',
      avatarUrl: avatarUri,
      identifiers: [
        if (identifiers is List) ...identifiers.whereType<String>(),
      ],
      ghostId: ghost is String && ghost.isNotEmpty ? ghost : null,
      dmRoomId: room is String && room.isNotEmpty ? room : null,
    );
  }

  static List<BridgeContact> listFromJson(Object? json, String key) {
    final list = json is Map ? json[key] : null;
    if (list is! List) return const [];
    return [for (final item in list) ?BridgeContact.fromJson(item)];
  }
}

/// A failed provisioning request. [message] is the bridge's own text when it
/// sent one (mautrix errors are written for people); it never contains the
/// request URL or credentials.
class BridgeProvisioningException implements Exception {
  const BridgeProvisioningException(this.status, {this.errcode, this.message});

  /// HTTP status, or 0 when the request did not complete.
  final int status;
  final String? errcode;
  final String? message;

  /// The bridge does not offer this endpoint (`M_UNRECOGNIZED`).
  bool get unsupported => errcode == 'M_UNRECOGNIZED';

  /// No route, no websocket proxy, or the token was not accepted.
  bool get unreachable =>
      status == 0 || status == 404 || status == 401 || status == 403;

  /// Short technical reason for diagnostics (status and error code only).
  String get reason =>
      [if (status != 0) 'HTTP $status' else 'no response', ?errcode].join(' ');

  @override
  String toString() => 'BridgeProvisioningException($reason)';
}

/// One request of the bridgev2 provisioning API, relative to
/// `/_matrix/provision` (e.g. `/v3/whoami`).
@immutable
class BridgeProvisioningRequest {
  const BridgeProvisioningRequest(
    this.method,
    this.path, {
    this.query = const {},
    this.body,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, Object?>? body;
}

/// How requests reach a bridge's provisioning API. Production uses
/// [BeeperProvisioningTransport]; tests use a fake.
abstract interface class BridgeProvisioningTransport {
  /// Returns the decoded JSON body of a 2xx response; throws
  /// [BridgeProvisioningException] otherwise.
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  );
}

/// The bridgev2 provisioning endpoints the search uses. Every call is
/// explicit: nothing here runs while the user only types.
class BridgeProvisioningApi {
  BridgeProvisioningApi(this.transport);

  final BridgeProvisioningTransport transport;

  Map<String, String> _login(String? loginId) =>
      loginId == null ? const {} : {'login_id': loginId};

  /// Read-only; also tells whether the bridge is reachable at all.
  Future<BridgeWhoami> whoami(BridgeEndpoint bridge) async {
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
    return whoami;
  }

  Future<BridgeProvisioningCapabilities> capabilities(
    BridgeEndpoint bridge,
  ) async => BridgeProvisioningCapabilities.fromJson(
    await transport.send(
      bridge,
      const BridgeProvisioningRequest('GET', '/v3/capabilities'),
    ),
  );

  /// The login's contact list (no query leaves the device).
  Future<List<BridgeContact>> contacts(
    BridgeEndpoint bridge, {
    String? loginId,
  }) async => BridgeContact.listFromJson(
    await transport.send(
      bridge,
      BridgeProvisioningRequest('GET', '/v3/contacts', query: _login(loginId)),
    ),
    'contacts',
  );

  /// Searches the network for [query] (sent to the bridge and network).
  Future<List<BridgeContact>> searchUsers(
    BridgeEndpoint bridge,
    String query, {
    String? loginId,
  }) async => BridgeContact.listFromJson(
    await transport.send(
      bridge,
      BridgeProvisioningRequest(
        'POST',
        '/v3/search_users',
        query: _login(loginId),
        body: {'query': query},
      ),
    ),
    'results',
  );

  /// Looks up a phone number or username; creates nothing.
  Future<BridgeContact?> resolveIdentifier(
    BridgeEndpoint bridge,
    String identifier, {
    String? loginId,
  }) async {
    try {
      return BridgeContact.fromJson(
        await transport.send(
          bridge,
          BridgeProvisioningRequest(
            'GET',
            '/v3/resolve_identifier/${Uri.encodeComponent(identifier)}',
            query: _login(loginId),
          ),
        ),
      );
    } on BridgeProvisioningException catch (e) {
      if (e.status == 404 && e.errcode == 'M_NOT_FOUND') return null;
      rethrow;
    }
  }

  /// Asks the bridge to create (or return) the DM with [identifier]. Only
  /// called after the user confirmed starting the chat.
  Future<BridgeContact> createDm(
    BridgeEndpoint bridge,
    String identifier, {
    String? loginId,
  }) async {
    final contact = BridgeContact.fromJson(
      await transport.send(
        bridge,
        BridgeProvisioningRequest(
          'POST',
          '/v3/create_dm/${Uri.encodeComponent(identifier)}',
          query: _login(loginId),
          body: const {},
        ),
      ),
    );
    if (contact == null || contact.dmRoomId == null) {
      throw const BridgeProvisioningException(
        200,
        errcode: 'CHATLOOM_NO_ROOM',
        message: 'The bridge did not return a chat.',
      );
    }
    return contact;
  }
}

/// Reaches bridgev2 provisioning APIs of the account's bridges.
///
/// Bridges run by bbctl (and Beeper's own) connect to hungryserv with an
/// appservice websocket and have no HTTP listener; hungryserv forwards
/// client requests to them with the websocket command `http_proxy`
/// (mautrix-go `appservice/wshttp.go`, bbctl `cmd/bbctl/proxy.go`).
///
/// * Default (Beeper): `POST {homeserver}/_hungryserv/{user}/_matrix/asmux/
///   mxauth/appservice/{user}/{bridge}/exec/http_proxy` with an
///   `HTTPProxyRequest`. The `mxauth/appservice/{user}/{bridge}` root is the
///   one bbctl registers bridges with; `exec/{command}` is how asmux exposed
///   websocket commands to Matrix-authenticated clients. Hungryserv's
///   client route is not publicly documented, so the first `whoami` decides
///   whether it works; a failure leaves the feature off for the session.
/// * Override: `--dart-define=CHATLOOM_BRIDGE_PROVISIONING_URL=<template>`
///   with `{bridge}` and `{user}` placeholders, e.g.
///   `https://bridges.example.org/{bridge}`; requests then go directly to
///   `{url}/_matrix/provision/v3/…`.
///
/// Authentication: the account's Matrix access token plus `user_id`; the
/// bridge accepts it because bbctl configures `provisioning.allow_matrix_auth`
/// and checks the token with a whoami on hungryserv (mautrix-go
/// `bridgev2/matrix/provisioning.go`). The token only goes to the
/// homeserver origin unless the override names another host.
class BeeperProvisioningTransport implements BridgeProvisioningTransport {
  BeeperProvisioningTransport({
    required this.httpClient,
    required this.homeserver,
    required this.userId,
    required this.accessToken,
    this.overrideUrl = const String.fromEnvironment(
      'CHATLOOM_BRIDGE_PROVISIONING_URL',
    ),
    this.timeout = const Duration(seconds: 20),
  });

  final http.Client httpClient;
  final Uri homeserver;
  final String userId;
  final String? Function() accessToken;

  /// Direct base URL template (empty: the hungryserv exec route).
  final String overrideUrl;
  final Duration timeout;

  String get _localpart {
    final colon = userId.indexOf(':');
    return userId.substring(1, colon < 0 ? userId.length : colon);
  }

  /// The exec endpoint of [bridge] (default mode).
  Uri execUri(BridgeEndpoint bridge) {
    final user = _localpart;
    return Uri(
      scheme: homeserver.scheme,
      host: homeserver.host,
      port: homeserver.hasPort ? homeserver.port : null,
      pathSegments: [
        ...homeserver.pathSegments.where((s) => s.isNotEmpty),
        if (!homeserver.pathSegments.contains('_hungryserv')) ...[
          '_hungryserv',
          user,
        ],
        '_matrix',
        'asmux',
        'mxauth',
        'appservice',
        user,
        bridge.name,
        'exec',
        'http_proxy',
      ],
    );
  }

  /// The direct provisioning URL of [request] (override mode).
  Uri directUri(BridgeEndpoint bridge, BridgeProvisioningRequest request) {
    final base = Uri.parse(
      overrideUrl
          .replaceAll('{bridge}', Uri.encodeComponent(bridge.name))
          .replaceAll('{user}', Uri.encodeComponent(_localpart)),
    );
    final path = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$path/_matrix/provision${request.path}',
      queryParameters: {'user_id': userId, ...request.query},
    );
  }

  String _queryString(BridgeProvisioningRequest request) =>
      Uri(queryParameters: {'user_id': userId, ...request.query}).query;

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) async {
    final token = accessToken();
    if (token == null || token.isEmpty) {
      throw const BridgeProvisioningException(401, errcode: 'M_MISSING_TOKEN');
    }
    final authorization = 'Bearer $token';
    final http.Response response;
    try {
      if (overrideUrl.isNotEmpty) {
        final uri = directUri(bridge, request);
        final httpRequest = http.Request(request.method, uri)
          ..headers['Authorization'] = authorization
          ..headers['Accept'] = 'application/json';
        if (request.body != null) {
          httpRequest
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode(request.body);
        }
        response = await http.Response.fromStream(
          await httpClient.send(httpRequest).timeout(timeout),
        ).timeout(timeout);
        return _decode(response.statusCode, response.body);
      }
      final httpRequest = http.Request('POST', execUri(bridge))
        ..headers['Authorization'] = authorization
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'application/json'
        ..body = jsonEncode({
          'method': request.method,
          'path': '/_matrix/provision${request.path}',
          'query': _queryString(request),
          'headers': {
            'Authorization': [authorization],
            'Content-Type': ['application/json'],
          },
          'body': ?request.body,
        });
      response = await http.Response.fromStream(
        await httpClient.send(httpRequest).timeout(timeout),
      ).timeout(timeout);
    } on BridgeProvisioningException {
      rethrow;
    } catch (_) {
      // Network errors may echo the URL; report only that nothing came back.
      throw const BridgeProvisioningException(0);
    }
    final outer = _decode(response.statusCode, response.body);
    return _unwrapProxy(outer);
  }

  /// Unwraps an `HTTPProxyResponse` (`{status, headers, body}`).
  static Object? _unwrapProxy(Object? outer) {
    if (outer is! Map || outer['status'] is! int) {
      throw const BridgeProvisioningException(
        200,
        errcode: 'CHATLOOM_NOT_A_PROXY',
      );
    }
    final status = outer['status'] as int;
    var body = outer['body'];
    if (body is String) {
      // Non-JSON bodies arrive base64-encoded; a provisioning answer is JSON.
      try {
        body = jsonDecode(utf8.decode(base64.decode(base64.normalize(body))));
      } catch (_) {
        body = null;
      }
    }
    return _checked(status, body);
  }

  static Object? _decode(int status, String text) {
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      json = null;
    }
    return _checked(status, json);
  }

  static Object? _checked(int status, Object? json) {
    if (status >= 200 && status < 300) return json;
    final errcode = json is Map ? json['errcode'] : null;
    final error = json is Map ? json['error'] : null;
    throw BridgeProvisioningException(
      status,
      errcode: errcode is String ? errcode : null,
      message: error is String ? error : null,
    );
  }
}
