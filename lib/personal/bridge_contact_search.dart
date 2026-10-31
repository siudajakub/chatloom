// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show InboxRecord;

export 'package:chatloom/personal/bridge_contact_search_provisioning.dart';

// ---------------------------------------------------------------------------
// Text matching
// ---------------------------------------------------------------------------

const _folds = {
  'ą': 'a',
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'æ': 'ae',
  'ć': 'c',
  'ç': 'c',
  'č': 'c',
  'ď': 'd',
  'đ': 'd',
  'ę': 'e',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ě': 'e',
  'ē': 'e',
  'ğ': 'g',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ı': 'i',
  'ł': 'l',
  'ľ': 'l',
  'ĺ': 'l',
  'ń': 'n',
  'ñ': 'n',
  'ň': 'n',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ő': 'o',
  'œ': 'oe',
  'ř': 'r',
  'ś': 's',
  'š': 's',
  'ş': 's',
  'ß': 'ss',
  'ť': 't',
  'ţ': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ů': 'u',
  'ű': 'u',
  'ū': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
};

/// Lower case without diacritics, so "lukasz" finds "Łukasz" (Telegram and
/// Messenger search the same way).
String searchFold(String value) {
  final lower = value.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    out.write(_folds[char] ?? char);
  }
  return out.toString();
}

/// Search terms of [query] (folded, split on white space).
List<String> searchTerms(String query) => searchFold(
  query,
).trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

final _wordBreak = RegExp(r'[\s\-_.,;:()\[\]/+@&|·"!?]+');

/// How well [folded] (a [searchFold]ed text) matches [terms]: 0 when every
/// term starts a word, 1 when some term only appears inside a word, null
/// when a term is missing.
int? searchRank(String folded, List<String> terms) {
  if (terms.isEmpty) return null;
  var rank = 0;
  final words = folded.split(_wordBreak);
  for (final term in terms) {
    if (words.any((w) => w.startsWith(term))) continue;
    if (!folded.contains(term)) return null;
    rank = 1;
  }
  return rank;
}

/// A network username or phone number of the other person of a one-to-one
/// chat, as the bridge put it in that person's member state
/// (`com.beeper.bridge.identifiers`). Search finds the chat by it and shows
/// it under the chat's name.
@immutable
class SearchHandle {
  const SearchHandle({
    required this.display,
    required this.network,
    this.phone = false,
  });

  /// What the row shows: `@anna_k` or `+48600100200`.
  final String display;

  /// The network's label ("Instagram"), empty when unknown.
  final String network;
  final bool phone;

  /// The row's subtitle: `@anna_k · Instagram`.
  String get label => network.isEmpty ? display : '$display · $network';

  @override
  bool operator ==(Object other) =>
      other is SearchHandle &&
      other.display == display &&
      other.network == network &&
      other.phone == phone;

  @override
  int get hashCode => Object.hash(display, network, phone);

  @override
  String toString() => 'SearchHandle(${phone ? 'phone' : 'username'})';
}

final _phoneQuery = RegExp(r'^\+?[\d\s\-().]+$');
final _handleBreak = RegExp(r'[._\-]+');

/// How [handle] matches [query]: 0 when the query starts the handle (or a
/// part of it after `.`, `_` or `-`), 1 when it only appears inside it,
/// null otherwise. A leading `@` of the query is ignored; case and
/// diacritics fold as in [searchFold]. A query with spaces never matches a
/// username. Short queries (under 3 characters) match only at a start, so
/// "a" does not list every handle with an "a". Phone numbers match only a
/// query of phone characters with at least 4 digits.
int? searchHandleRank(SearchHandle handle, String query) {
  final text = query.trim();
  if (handle.phone) {
    if (!_phoneQuery.hasMatch(text)) return null;
    final digits = _digits(text);
    if (digits.length < 4) return null;
    final number = _digits(handle.display);
    if (number.startsWith(digits)) return 0;
    return number.contains(digits) ? 1 : null;
  }
  final folded = searchFold(text).replaceFirst(RegExp('^@+'), '');
  if (folded.isEmpty || folded.contains(RegExp(r'\s'))) return null;
  final name = searchFold(handle.display).replaceFirst(RegExp('^@+'), '');
  if (name.startsWith(folded)) return 0;
  if (name.split(_handleBreak).any((part) => part.startsWith(folded))) {
    return 0;
  }
  if (folded.length < 3) return null;
  return name.contains(folded) ? 1 : null;
}

/// What an explicit lookup would send to a bridge for [query].
enum SearchIdentifierKind { phone, username, email }

@immutable
class SearchIdentifier {
  const SearchIdentifier(this.kind, this.value, this.display);
  final SearchIdentifierKind kind;

  /// Normalised value for the bridge (`+48600100200`, `anna_k`).
  final String value;

  /// As shown in the row ("+48 600 100 200", "@anna_k").
  final String display;
}

/// A phone number, @username or e-mail address in [query], or null. A
/// Matrix id (`@user:server`) is never an identifier: the app does not
/// search Matrix.
SearchIdentifier? detectIdentifier(String query) {
  final text = query.trim();
  if (text.isEmpty || text.contains(':')) return null;
  final phone = text.replaceAll(RegExp(r'[\s\-().]'), '');
  if (RegExp(r'^\+?\d{7,15}$').hasMatch(phone)) {
    return SearchIdentifier(SearchIdentifierKind.phone, phone, text);
  }
  if (RegExp(r'^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$').hasMatch(text)) {
    return SearchIdentifier(SearchIdentifierKind.email, text, text);
  }
  final username = RegExp(
    r'^@?([a-zA-Z][a-zA-Z0-9_.]{2,31})$',
  ).firstMatch(text);
  if (username != null && text.startsWith('@')) {
    final name = username.group(1)!;
    return SearchIdentifier(SearchIdentifierKind.username, name, '@$name');
  }
  return null;
}

/// Whether [capabilities] let the bridge look [identifier] up.
bool canLookUp(
  BridgeProvisioningCapabilities capabilities,
  SearchIdentifier identifier,
) => switch (identifier.kind) {
  SearchIdentifierKind.phone => capabilities.lookupPhone,
  SearchIdentifierKind.username => capabilities.lookupUsername,
  SearchIdentifierKind.email => capabilities.lookupEmail,
};

// ---------------------------------------------------------------------------
// Bridges and people known from local state
// ---------------------------------------------------------------------------

const _bridgeStateTypes = [
  'm.bridge',
  'uk.half-shot.bridge',
  'com.beeper.bridge',
];

/// Network key and label of a bridge's `protocol` section.
(String, String)? bridgeNetworkOf(Map protocol) {
  final id = protocol['id'];
  final displayname = protocol['displayname'];
  final canonical = canonicalNetwork(id) ?? canonicalNetwork(displayname);
  if (canonical == 'matrix') return null;
  final key =
      canonical ??
      (id is String && id.trim().isNotEmpty ? id.trim().toLowerCase() : null);
  if (key == null) return null;
  final known = notionNetworkLabel(key);
  final label = known != key
      ? known
      : displayname is String && displayname.trim().isNotEmpty
      ? displayname.trim()
      : key;
  return (key, label);
}

/// Every bridge the account's rooms declare, once per bot (sorted by label).
List<BridgeEndpoint> discoverBridges(Iterable<Room> rooms) {
  final found = <String, BridgeEndpoint>{};
  for (final room in rooms) {
    for (final type in _bridgeStateTypes) {
      for (final state in room.states[type]?.values ?? <StrippedStateEvent>[]) {
        final bot = state.content['bridgebot'];
        final protocol = state.content['protocol'];
        if (bot is! String ||
            !bot.isValidMatrixIdStrict() ||
            protocol is! Map ||
            found.containsKey(bot)) {
          continue;
        }
        final network = bridgeNetworkOf(protocol);
        if (network == null) continue;
        found[bot] = BridgeEndpoint(
          botId: bot,
          network: network.$1,
          label: network.$2,
        );
      }
    }
  }
  return found.values.toList()..sort((a, b) {
    final byLabel = a.label.compareTo(b.label);
    return byLabel != 0 ? byLabel : a.botId.compareTo(b.botId);
  });
}

/// Someone from a bridged chat (a ghost of one of the account's bridges).
@immutable
class BridgePerson {
  const BridgePerson({
    required this.ghostId,
    required this.name,
    required this.bridge,
    this.avatar,
    this.sharedRooms = const [],
    this.dmRoomId,
  });

  /// Internal key; never shown.
  final String ghostId;
  final String name;
  final Uri? avatar;
  final BridgeEndpoint bridge;

  /// Names of the group chats you share (for the row subtitle).
  final List<String> sharedRooms;

  /// The existing one-to-one chat with this person, if any.
  final String? dmRoomId;
}

/// People of the account's bridged chats, from already loaded member state
/// (nothing is requested). [isOwn] filters the account's own puppets,
/// [isTechnical] bridge management rooms, [roomName] gives group names.
List<BridgePerson> indexBridgePeople({
  required Iterable<Room> rooms,
  required List<BridgeEndpoint> bridges,
  required String ownUserId,
  required bool Function(String userId, String roomId) isOwn,
  required bool Function(Room room) isTechnical,
  String Function(Room room)? roomName,
}) {
  if (bridges.isEmpty) return const [];
  final bots = {for (final bridge in bridges) bridge.botId};
  final names = <String, String>{};
  final avatars = <String, Uri>{};
  final owners = <String, BridgeEndpoint>{};
  final shared = <String, List<String>>{};
  final direct = <String, String>{};
  BridgeEndpoint? ownerOf(String id) {
    if (owners.containsKey(id)) return owners[id];
    for (final bridge in bridges) {
      if (bridge.ownsGhost(id)) return owners[id] = bridge;
    }
    return null;
  }

  for (final room in rooms) {
    if (room.isSpace ||
        room.membership != Membership.join ||
        PersonalPrivacy.isJournal(room) ||
        isTechnical(room)) {
      continue;
    }
    final dmPartner = room.isDirectChatForDisplay
        ? room.directChatMatrixIDForDisplay
        : null;
    for (final user in room.getParticipants(const [
      Membership.join,
      Membership.invite,
    ])) {
      final id = user.id;
      if (id == ownUserId || bots.contains(id)) continue;
      if (ownerOf(id) == null || isOwn(id, room.id)) continue;
      // Only a real display name: a ghost without one would show its id.
      final displayname = user.content['displayname'];
      if (displayname is String && displayname.trim().isNotEmpty) {
        names.putIfAbsent(id, displayname.trim);
      }
      final avatar = user.avatarUrl;
      if (avatar != null) avatars[id] = avatar;
      if (id == dmPartner) {
        direct.putIfAbsent(id, () => room.id);
      } else {
        (shared[id] ??= []).add(
          roomName?.call(room) ?? room.getLocalizedDisplayname(),
        );
      }
    }
  }
  return [
    for (final id in owners.keys)
      if (owners[id] != null && names[id] != null)
        BridgePerson(
          ghostId: id,
          name: names[id]!,
          avatar: avatars[id],
          bridge: owners[id]!,
          sharedRooms: shared[id] ?? const [],
          dmRoomId: direct[id],
        ),
  ];
}

// ---------------------------------------------------------------------------
// Remote state per bridge
// ---------------------------------------------------------------------------

enum BridgeRemoteStatus {
  /// Not asked yet.
  unknown,

  /// whoami/capabilities in flight.
  checking,

  /// The provisioning API answered for a logged-in bridge.
  ready,

  /// The bridge has no usable login.
  notLoggedIn,

  /// The provisioning API cannot be reached from the app.
  unavailable,
}

/// A contact the bridge returned, with the login it belongs to.
@immutable
class BridgeRemoteContact {
  const BridgeRemoteContact(this.contact, this.loginId);
  final BridgeContact contact;
  final String? loginId;
}

class BridgeRemoteState {
  BridgeRemoteStatus status = BridgeRemoteStatus.unknown;
  BridgeWhoami? whoami;
  BridgeProvisioningCapabilities capabilities =
      BridgeProvisioningCapabilities.none;

  /// Technical reason of [BridgeRemoteStatus.unavailable] (no secrets).
  String? reason;
  DateTime? checkedAt;
  List<BridgeRemoteContact>? contacts;
  DateTime? contactsAt;
  bool contactsLoading = false;
  String? contactsError;

  /// Explicit `search_users` results by folded query.
  final searches = <String, List<BridgeRemoteContact>>{};
  final searching = <String>{};

  /// Explicit `resolve_identifier` results by identifier (null: not found).
  final lookups = <String, BridgeRemoteContact?>{};
  final lookingUp = <String>{};

  /// Last explicit request that failed, for the network's caption.
  String? actionError;

  /// Why the explicit search for a folded query or the lookup of an
  /// identifier failed (human text); cleared when it is tried again. The row
  /// shows it with "try again" instead of silently resetting (CC-24).
  final searchErrors = <String, String>{};
  final lookupErrors = <String, String>{};

  String? get defaultLoginId => whoami?.usableLogins.firstOrNull?.id;
}

/// Remote people of the account's bridges via the bridgev2 provisioning API.
///
/// * [probe] (whoami + capabilities) runs when search opens; it sends no
///   query and is cached for the session.
/// * [loadContacts] runs once a query is typed; the list is filtered on the
///   device, so typing discloses nothing.
/// * [searchUsers] and [lookUp] send the query or identifier to the bridge
///   and network; the UI calls them only on an explicit tap.
class BridgeDirectory extends ChangeNotifier {
  BridgeDirectory(
    this.api, {
    DateTime Function()? clock,
    this.disabledReason,
    this.reaches,
  }) : _clock = clock ?? DateTime.now;

  /// A directory that never makes requests (no supported route).
  BridgeDirectory.disabled(String reason)
    : api = null,
      disabledReason = reason,
      reaches = null,
      _clock = DateTime.now;

  final BridgeProvisioningApi? api;

  /// Bridges the transport can reach at all (null: every bridge). The
  /// hungryserv route only reaches the account's own `beeper.local` bridges.
  final bool Function(BridgeEndpoint bridge)? reaches;

  /// Why bridge access is off for this account (shown with the networks).
  final String? disabledReason;
  final DateTime Function() _clock;
  final _states = <String, BridgeRemoteState>{};
  final _inflight = <String, Future<void>>{};

  /// Bumped on every change (memo key for results).
  int revision = 0;

  static const probeTtl = Duration(minutes: 30);
  static const failureTtl = Duration(minutes: 5);
  static const contactsTtl = Duration(minutes: 10);

  static final _sessions = Expando<(String?, BridgeDirectory)>(
    'bridge directory',
  );

  /// The session directory of [client]'s signed-in account (a new one after
  /// the client signs in as someone else).
  static BridgeDirectory of(Client client) {
    final cached = _sessions[client];
    if (cached != null && cached.$1 == client.userID) return cached.$2;
    final directory = _create(client);
    _sessions[client] = (client.userID, directory);
    return directory;
  }

  static BridgeDirectory _create(Client client) {
    const override = String.fromEnvironment('CHATLOOM_BRIDGE_PROVISIONING_URL');
    final homeserver = client.homeserver;
    final userId = client.userID;
    if (homeserver == null || userId == null) {
      return BridgeDirectory.disabled('Not signed in.');
    }
    final beeper = RegExp(
      r'(^|\.)beeper(-staging|-dev)?\.com$',
    ).hasMatch(homeserver.host);
    if (override.isEmpty && !beeper) {
      return BridgeDirectory.disabled(
        'Bridge contacts are available on Beeper accounts.',
      );
    }
    return BridgeDirectory(
      BridgeProvisioningApi(
        BeeperProvisioningTransport(
          httpClient: client.httpClient,
          homeserver: homeserver,
          userId: userId,
          accessToken: () => client.accessToken,
          overrideUrl: override,
        ),
      ),
      reaches: override.isEmpty
          ? (bridge) => bridge.domain == 'beeper.local'
          : null,
    );
  }

  BridgeRemoteState stateOf(BridgeEndpoint bridge) =>
      _states.putIfAbsent(bridge.botId, BridgeRemoteState.new);

  void _changed() {
    revision++;
    notifyListeners();
  }

  /// Runs [run] unless the same request is in flight. The request is
  /// registered before it starts: [run] notifies listeners synchronously,
  /// and a listener asking again must join it instead of starting another.
  Future<void> _once(String key, Future<void> Function() run) {
    final running = _inflight[key];
    if (running != null) return running;
    final done = Completer<void>();
    _inflight[key] = done.future;
    // A block body: returning the removed future would make whenComplete
    // wait for itself.
    run()
        .whenComplete(() {
          _inflight.remove(key);
        })
        .then(done.complete, onError: done.completeError);
    return done.future;
  }

  bool _fresh(DateTime? at, Duration ttl) =>
      at != null && _clock().difference(at) < ttl;

  /// whoami + capabilities for every bridge not checked recently.
  Future<void> probe(Iterable<BridgeEndpoint> bridges, {bool force = false}) =>
      Future.wait([for (final bridge in bridges) _probe(bridge, force: force)]);

  Future<void> _probe(BridgeEndpoint bridge, {required bool force}) {
    final state = stateOf(bridge);
    final api = this.api;
    final reachable = reaches?.call(bridge) ?? true;
    if (api == null || !reachable) {
      if (state.status != BridgeRemoteStatus.unavailable) {
        state
          ..status = BridgeRemoteStatus.unavailable
          ..reason = api == null ? disabledReason : 'not a Beeper bridge';
        _changed();
      }
      return Future.value();
    }
    final ttl = state.status == BridgeRemoteStatus.unavailable
        ? failureTtl
        : probeTtl;
    if (!force &&
        state.status != BridgeRemoteStatus.unknown &&
        _fresh(state.checkedAt, ttl)) {
      return Future.value();
    }
    return _once('probe:${bridge.botId}', () async {
      state.status = BridgeRemoteStatus.checking;
      _changed();
      try {
        final whoami = await api.whoami(bridge);
        state
          ..whoami = whoami
          ..reason = null;
        try {
          state.capabilities = await api.capabilities(bridge);
        } on BridgeProvisioningException {
          // Older bridges: contacts and DMs still work without the flags.
          state.capabilities = const BridgeProvisioningCapabilities(
            createDm: true,
            contactList: true,
          );
        }
        state.status = whoami.usableLogins.isEmpty
            ? BridgeRemoteStatus.notLoggedIn
            : BridgeRemoteStatus.ready;
      } on BridgeProvisioningException catch (e) {
        logBackgroundError('bridge_probe', e);
        state
          ..status = BridgeRemoteStatus.unavailable
          // Shown under the network: words, not `HTTP 404 M_UNRECOGNIZED`.
          ..reason = e.unreachable || e.unsupported
              ? 'ChatLoom can’t reach this bridge'
              : humanErrorText(e, network: bridge.label);
      } catch (_) {
        state
          ..status = BridgeRemoteStatus.unavailable
          ..reason = 'unexpected answer';
      }
      state.checkedAt = _clock();
      _changed();
    });
  }

  /// Asks [bridge] for its current logins (`whoami` only) for the network
  /// status, and keeps the answer: a login that signed out stops being
  /// offered for contacts and new chats. Throws
  /// [BridgeProvisioningException] on failure without touching the cached
  /// state (search shows its own probe result).
  Future<BridgeWhoami> refreshLogins(BridgeEndpoint bridge) async {
    final api = this.api;
    if (api == null) {
      throw BridgeProvisioningException(0, message: disabledReason);
    }
    final running = _logins[bridge.botId];
    if (running != null) return running;
    final request = api.whoami(bridge);
    _logins[bridge.botId] = request;
    try {
      final whoami = await request;
      final state = stateOf(bridge);
      String logins(BridgeWhoami? value) =>
          value?.usableLogins.map((login) => login.id).join(' ') ?? '';
      final before = (state.status, logins(state.whoami));
      state.whoami = whoami;
      if (state.status == BridgeRemoteStatus.ready ||
          state.status == BridgeRemoteStatus.notLoggedIn) {
        state.status = whoami.usableLogins.isEmpty
            ? BridgeRemoteStatus.notLoggedIn
            : BridgeRemoteStatus.ready;
      }
      // Search rebuilds only when what it offers changed.
      if (before != (state.status, logins(whoami))) _changed();
      return whoami;
    } finally {
      _logins.remove(bridge.botId);
    }
  }

  final _logins = <String, Future<BridgeWhoami>>{};

  /// Contact lists of ready bridges that offer one (once per [contactsTtl]).
  Future<void> loadContacts(Iterable<BridgeEndpoint> bridges) =>
      Future.wait([for (final bridge in bridges) _loadContacts(bridge)]);

  Future<void> _loadContacts(BridgeEndpoint bridge) {
    final state = stateOf(bridge);
    final api = this.api;
    if (api == null ||
        state.status != BridgeRemoteStatus.ready ||
        !state.capabilities.contactList ||
        _fresh(state.contactsAt, contactsTtl)) {
      return Future.value();
    }
    return _once('contacts:${bridge.botId}', () async {
      state.contactsLoading = true;
      _changed();
      final logins = state.whoami!.usableLogins;
      final result = <BridgeRemoteContact>[];
      String? error;
      for (final login in logins) {
        try {
          final contacts = await api.contacts(
            bridge,
            loginId: logins.length > 1 ? login.id : null,
          );
          result.addAll(
            contacts.map(
              (c) =>
                  BridgeRemoteContact(c, logins.length > 1 ? login.id : null),
            ),
          );
        } on BridgeProvisioningException catch (e) {
          error = e.unsupported
              ? null
              : humanErrorText(e, network: bridge.label);
          if (e.unsupported) {
            state.capabilities = BridgeProvisioningCapabilities(
              createDm: state.capabilities.createDm,
              lookupPhone: state.capabilities.lookupPhone,
              lookupEmail: state.capabilities.lookupEmail,
              lookupUsername: state.capabilities.lookupUsername,
              anyPhone: state.capabilities.anyPhone,
              search: state.capabilities.search,
            );
          }
        } catch (_) {
          error = 'unexpected answer';
        }
      }
      state
        ..contacts = result
        ..contactsAt = _clock()
        ..contactsLoading = false
        ..contactsError = error;
      _changed();
    });
  }

  /// Explicit network search for [query] on [bridge].
  Future<void> searchUsers(BridgeEndpoint bridge, String query) {
    final state = stateOf(bridge);
    final api = this.api;
    final key = searchFold(query.trim());
    if (api == null ||
        key.isEmpty ||
        state.status != BridgeRemoteStatus.ready ||
        state.searches.containsKey(key)) {
      return Future.value();
    }
    return _once('search:${bridge.botId}:$key', () async {
      state
        ..searching.add(key)
        ..searchErrors.remove(key)
        ..actionError = null;
      _changed();
      try {
        final loginId = state.defaultLoginId;
        final hits = await api.searchUsers(
          bridge,
          query.trim(),
          loginId: (state.whoami?.usableLogins.length ?? 0) > 1
              ? loginId
              : null,
        );
        state.searches[key] = [
          for (final hit in hits) BridgeRemoteContact(hit, loginId),
        ];
      } on BridgeProvisioningException catch (e) {
        state.actionError = state.searchErrors[key] =
            humanErrorText(e, network: bridge.label);
      } catch (e) {
        state.actionError = state.searchErrors[key] = humanErrorText(e);
      }
      state.searching.remove(key);
      _changed();
    });
  }

  /// Explicit lookup of a phone number or username on [bridge].
  Future<void> lookUp(BridgeEndpoint bridge, SearchIdentifier identifier) {
    final state = stateOf(bridge);
    final api = this.api;
    final key = identifier.value;
    if (api == null ||
        state.status != BridgeRemoteStatus.ready ||
        state.lookups.containsKey(key)) {
      return Future.value();
    }
    return _once('lookup:${bridge.botId}:$key', () async {
      state
        ..lookingUp.add(key)
        ..lookupErrors.remove(key)
        ..actionError = null;
      _changed();
      try {
        final loginId = state.defaultLoginId;
        final contact = await api.resolveIdentifier(
          bridge,
          identifier.value,
          loginId: (state.whoami?.usableLogins.length ?? 0) > 1
              ? loginId
              : null,
        );
        state.lookups[key] = contact == null
            ? null
            : BridgeRemoteContact(contact, loginId);
      } on BridgeProvisioningException catch (e) {
        state.actionError = state.lookupErrors[key] =
            humanErrorText(e, network: bridge.label);
      } catch (e) {
        state.actionError = state.lookupErrors[key] = humanErrorText(e);
      }
      state.lookingUp.remove(key);
      _changed();
    });
  }
}

// ---------------------------------------------------------------------------
// Merging and grouping
// ---------------------------------------------------------------------------

/// A conversation of the inbox as search sees it.
@immutable
class SearchChatCandidate {
  const SearchChatCandidate({
    required this.record,
    required this.roomIds,
    this.extraText = '',
    this.handles = const [],
  });

  final InboxRecord record;

  /// The source rooms (one, or every room of a merged person).
  final List<String> roomIds;

  /// More searchable text (e.g. network names).
  final String extraText;

  /// Network usernames and phone numbers of the other person of each
  /// one-to-one source chat. Never group members' (`ChatHandleIndex`).
  final List<SearchHandle> handles;
}

@immutable
class SearchChatHit {
  const SearchChatHit(this.candidate, this.rank, {this.handle});
  final SearchChatCandidate candidate;

  /// 0–1: the name matched ([searchRank]); 2–3: only [handle] did.
  final int rank;

  /// The username or number the chat was found by, when its name did not
  /// match; the row shows it so the user sees why it is listed.
  final SearchHandle? handle;
  InboxRecord get record => candidate.record;
}

/// Rank of a chat found only by a username or phone number: below every
/// name match ([searchRank] gives 0 or 1).
const searchHandleRankOffset = 2;

/// The latest loaded message of a conversation.
@immutable
class SearchMessageCandidate {
  const SearchMessageCandidate({
    required this.roomId,
    required this.eventId,
    required this.chatName,
    required this.text,
    required this.time,
    String? preview,
  }) : preview = preview ?? text;

  final String roomId;
  final String eventId;
  final String chatName;

  /// What the search matches (the message text or media label).
  final String text;

  /// What the row shows (with the inbox's sender prefix).
  final String preview;
  final DateTime time;
}

enum SearchPersonSource { chat, contact, search, lookup }

/// One person row of a network group.
@immutable
class SearchPersonHit {
  const SearchPersonHit({
    required this.key,
    required this.name,
    required this.source,
    this.avatar,
    this.subtitle,
    this.roomId,
    this.identifier,
    this.loginId,
    this.rank = 0,
  });

  final String key;
  final String name;
  final SearchPersonSource source;
  final Uri? avatar;
  final String? subtitle;

  /// Existing chat to open, if any.
  final String? roomId;

  /// What `create_dm` needs when there is no chat yet (a ghost id or a
  /// network id; never shown).
  final String? identifier;
  final String? loginId;
  final int rank;

  bool get hasChat => roomId != null;
}

/// People of one network, plus what the user can ask that network.
@immutable
class SearchNetworkGroup {
  const SearchNetworkGroup({
    required this.bridge,
    required this.people,
    required this.status,
    this.canSearch = false,
    this.searching = false,
    this.searched = false,
    this.lookup,
    this.lookingUp = false,
    this.lookedUp = false,
    this.loadingContacts = false,
    this.canStartChats = false,
    this.error,
    this.searchError,
    this.lookupError,
  });

  final BridgeEndpoint bridge;
  final List<SearchPersonHit> people;
  final BridgeRemoteStatus status;

  /// "Search WhatsApp for …" is offered (explicit network search).
  final bool canSearch;
  final bool searching;
  final bool searched;

  /// "Look up +48… on WhatsApp" is offered for this identifier.
  final SearchIdentifier? lookup;
  final bool lookingUp;
  final bool lookedUp;
  final bool loadingContacts;

  /// The bridge can create DMs (people without a chat can be started).
  final bool canStartChats;
  final String? error;

  /// Why the explicit search for this query / the lookup of [lookup]
  /// failed; null when it did not run or succeeded.
  final String? searchError;
  final String? lookupError;

  bool get hasActions => canSearch || lookup != null;
}

@immutable
class UnifiedSearchResults {
  const UnifiedSearchResults({
    this.chats = const [],
    this.networks = const [],
    this.messages = const [],
  });

  final List<SearchChatHit> chats;
  final List<SearchNetworkGroup> networks;
  final List<SearchMessageCandidate> messages;

  bool get isEmpty =>
      chats.isEmpty &&
      messages.isEmpty &&
      networks.every((g) => g.people.isEmpty && !g.hasActions);

  static const empty = UnifiedSearchResults();
}

int _compareChats(SearchChatHit a, SearchChatHit b) {
  if (a.rank != b.rank) return a.rank - b.rank;
  int hidden(InboxRecord r) =>
      r.metadata.ignored || r.metadata.archived || r.metadata.lowPriority
      ? 1
      : 0;
  final byPlace = hidden(a.record) - hidden(b.record);
  if (byPlace != 0) return byPlace;
  final at = a.record.lastActivity, bt = b.record.lastActivity;
  if (at != bt) {
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  }
  return a.record.displayName.compareTo(b.record.displayName);
}

String _digits(String value) => value.replaceAll(RegExp(r'\D'), '');

/// Merges local chats, bridged people, bridge contacts, explicit network
/// searches and lookups, and the latest messages into Telegram-style
/// sections: chats first, then people grouped by network (people from your
/// chats before contacts, contacts before network search results), then
/// messages. A person whose chat is already listed under Chats is not
/// repeated; the same person found twice on a network appears once.
UnifiedSearchResults mergeUnifiedSearch({
  required String query,
  required List<SearchChatCandidate> chats,
  required List<BridgePerson> people,
  required List<BridgeEndpoint> bridges,
  BridgeRemoteState Function(BridgeEndpoint bridge)? remote,
  List<SearchMessageCandidate> messages = const [],
  bool Function(String roomId)? roomExists,
}) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return UnifiedSearchResults.empty;
  final exists = roomExists ?? (_) => true;
  final identifier = detectIdentifier(query);
  final queryDigits = _digits(query);

  // Chats.
  final chatHits = <SearchChatHit>[];
  final shownRooms = <String>{};
  for (final candidate in chats) {
    if (candidate.record.technical) continue;
    final rank = searchRank(
      searchFold('${candidate.record.displayName} ${candidate.extraText}'),
      terms,
    );
    if (rank != null) {
      chatHits.add(SearchChatHit(candidate, rank));
      shownRooms.addAll(candidate.roomIds);
      continue;
    }
    // A network username or number (Telegram's and Instagram's search):
    // after every name match, with the handle under the name.
    SearchHandle? matched;
    int? handleRank;
    for (final handle in candidate.handles) {
      final r = searchHandleRank(handle, query);
      if (r != null && (handleRank == null || r < handleRank)) {
        matched = handle;
        handleRank = r;
      }
    }
    if (matched == null) continue;
    chatHits.add(
      SearchChatHit(
        candidate,
        searchHandleRankOffset + handleRank!,
        handle: matched,
      ),
    );
    shownRooms.addAll(candidate.roomIds);
  }
  chatHits.sort(_compareChats);

  // People by network.
  final byBridge = <BridgeEndpoint, List<SearchPersonHit>>{};
  final seenGhosts = <String>{};
  final seenIds = <BridgeEndpoint, Set<String>>{};
  final ghostToRoom = <String, String>{};
  for (final person in people) {
    if (person.dmRoomId != null) ghostToRoom[person.ghostId] = person.dmRoomId!;
  }
  bool shownAsChat(String? roomId) =>
      roomId != null && shownRooms.contains(roomId);

  for (final person in people) {
    final rank = searchRank(searchFold(person.name), terms);
    // A contact may still match under another (address book) name.
    if (rank == null) continue;
    seenGhosts.add(person.ghostId);
    if (shownAsChat(person.dmRoomId)) continue;
    final shared = person.sharedRooms;
    (byBridge[person.bridge] ??= []).add(
      SearchPersonHit(
        key: 'chat:${person.ghostId}',
        name: person.name,
        source: SearchPersonSource.chat,
        avatar: person.avatar,
        subtitle: person.dmRoomId != null
            ? '${person.bridge.label} chat'
            : shared.isEmpty
            ? 'From your ${person.bridge.label} chats'
            : shared.length == 1
            ? 'In ${shared.first}'
            : 'In ${shared.first} and ${shared.length - 1} more',
        roomId: person.dmRoomId != null && exists(person.dmRoomId!)
            ? person.dmRoomId
            : null,
        identifier: person.ghostId,
        rank: rank,
      ),
    );
  }

  final groups = <SearchNetworkGroup>[];
  for (final bridge in bridges) {
    final state = remote?.call(bridge);
    final hits = byBridge[bridge] ?? <SearchPersonHit>[];
    final ids = seenIds[bridge] ??= {};

    void addRemote(BridgeRemoteContact entry, SearchPersonSource source) {
      final contact = entry.contact;
      final ghost = contact.ghostId;
      if (ghost != null && seenGhosts.contains(ghost)) return;
      if (!ids.add(contact.id)) return;
      final name = contact.name.isNotEmpty
          ? contact.name
          : contact.displayIdentifier ?? '';
      if (name.isEmpty) return;
      int? rank;
      if (source == SearchPersonSource.contact) {
        rank = searchRank(
          searchFold('$name ${contact.displayIdentifier ?? ''}'),
          terms,
        );
        if (rank == null && queryDigits.length >= 3) {
          final matches = contact.identifiers.any(
            (i) => _digits(i).contains(queryDigits),
          );
          if (matches) rank = 1;
        }
        if (rank == null) {
          ids.remove(contact.id);
          return;
        }
      }
      final room =
          contact.dmRoomId ?? (ghost == null ? null : ghostToRoom[ghost]);
      if (shownAsChat(room)) return;
      if (ghost != null) seenGhosts.add(ghost);
      hits.add(
        SearchPersonHit(
          key: '${source.name}:${bridge.botId}:${contact.id}',
          name: name,
          source: source,
          avatar: contact.avatarUrl,
          subtitle: [
            ?contact.displayIdentifier,
            switch (source) {
              SearchPersonSource.contact => 'Contact',
              SearchPersonSource.search => 'Found on ${bridge.label}',
              SearchPersonSource.lookup => 'Found on ${bridge.label}',
              SearchPersonSource.chat => null,
            },
          ].nonNulls.join(' · '),
          roomId: room != null && exists(room) ? room : null,
          identifier: ghost ?? contact.id,
          loginId: entry.loginId,
          rank: rank ?? 0,
        ),
      );
    }

    final ready = state?.status == BridgeRemoteStatus.ready;
    final folded = searchFold(query.trim());
    if (ready) {
      for (final entry in state!.contacts ?? const <BridgeRemoteContact>[]) {
        addRemote(entry, SearchPersonSource.contact);
      }
      for (final entry in state.searches[folded] ?? const []) {
        addRemote(entry, SearchPersonSource.search);
      }
      if (identifier != null) {
        final found = state.lookups[identifier.value];
        if (found != null) addRemote(found, SearchPersonSource.lookup);
      }
    }
    final capabilities =
        state?.capabilities ?? BridgeProvisioningCapabilities.none;
    final canSearch = ready && capabilities.search && folded.length >= 2;
    final lookup =
        ready && identifier != null && canLookUp(capabilities, identifier)
        ? identifier
        : null;
    if (hits.isEmpty && !canSearch && lookup == null) continue;
    groups.add(
      SearchNetworkGroup(
        bridge: bridge,
        people: hits,
        status: state?.status ?? BridgeRemoteStatus.unknown,
        canSearch: canSearch,
        searching: state?.searching.contains(folded) ?? false,
        searched: state?.searches.containsKey(folded) ?? false,
        lookup: lookup,
        lookingUp:
            lookup != null &&
            (state?.lookingUp.contains(lookup.value) ?? false),
        lookedUp:
            lookup != null &&
            (state?.lookups.containsKey(lookup.value) ?? false),
        loadingContacts: state?.contactsLoading ?? false,
        canStartChats: ready && capabilities.createDm,
        error: state?.actionError,
        searchError: state?.searchErrors[folded],
        lookupError: lookup == null ? null : state?.lookupErrors[lookup.value],
      ),
    );
  }
  int best(SearchNetworkGroup g) => g.people.isEmpty
      ? 99
      : g.people.map((p) => p.rank).reduce((a, b) => a < b ? a : b);
  groups.sort((a, b) {
    final byPeople = (a.people.isEmpty ? 1 : 0) - (b.people.isEmpty ? 1 : 0);
    if (byPeople != 0) return byPeople;
    final byRank = best(a) - best(b);
    if (byRank != 0) return byRank;
    return a.bridge.label.compareTo(b.bridge.label);
  });

  // Messages.
  final messageHits = <SearchMessageCandidate>[
    for (final message in messages)
      if (searchRank(searchFold(message.text), terms) != null) message,
  ]..sort((a, b) => b.time.compareTo(a.time));

  return UnifiedSearchResults(
    chats: chatHits,
    networks: groups,
    messages: messageHits,
  );
}
