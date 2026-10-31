// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Search across the connected networks: matching, grouping by network,
// de-duplication, and the bridgev2 provisioning client. Every bridge here is
// a fake; no request leaves the test.
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/bridge_start_chat.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show ConversationMetadata, InboxRecord;

const _whatsapp = BridgeEndpoint(
  botId: '@sh-whatsappbot:beeper.local',
  network: 'whatsapp',
  label: 'WhatsApp',
);
const _telegram = BridgeEndpoint(
  botId: '@sh-telegrambot:beeper.local',
  network: 'telegram',
  label: 'Telegram',
);

/// Records every provisioning request; answers from [handler].
class FakeProvisioning implements BridgeProvisioningTransport {
  FakeProvisioning(this.handler);

  final Object? Function(BridgeEndpoint bridge, BridgeProvisioningRequest r)
  handler;
  final requests = <(String, String, String, Map<String, String>, Object?)>[];

  List<String> get paths => [for (final r in requests) '${r.$2} ${r.$3}'];

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) async {
    requests.add((
      bridge.botId,
      request.method,
      request.path,
      request.query,
      request.body,
    ));
    return handler(bridge, request);
  }
}

Map<String, Object?> whoami(
  BridgeEndpoint bridge, {
  List<Map<String, Object?>> logins = const [
    {
      'id': 'login-1',
      'name': 'Fictional login',
      'state': {'state_event': 'CONNECTED'},
    },
  ],
}) => {
  'network': {'displayname': bridge.label, 'network_id': bridge.network},
  'bridge_bot': bridge.botId,
  'logins': logins,
};

const _allCapabilities = {
  'resolve_identifier': {
    'create_dm': true,
    'lookup_phone': true,
    'lookup_username': true,
    'contact_list': true,
    'search': true,
  },
};

/// A bridge that answers like mautrix bridgev2 with [contacts].
Object? Function(BridgeEndpoint, BridgeProvisioningRequest) bridgeAnswers({
  List<Map<String, Object?>> contacts = const [],
  List<Map<String, Object?>> found = const [],
  Map<String, Object?>? resolved,
  Map<String, Object?> capabilities = _allCapabilities,
}) =>
    (bridge, request) => switch (request.path) {
      '/v3/whoami' => whoami(bridge),
      '/v3/capabilities' => capabilities,
      '/v3/contacts' => {'contacts': contacts},
      '/v3/search_users' => {'results': found},
      final path when path.startsWith('/v3/resolve_identifier/') =>
        resolved ??
            (throw const BridgeProvisioningException(
              404,
              errcode: 'M_NOT_FOUND',
            )),
      final path when path.startsWith('/v3/create_dm/') => {
        'id': 'network-user',
        'dm_room_mxid': '!created:example.invalid',
      },
      _ => throw const BridgeProvisioningException(
        404,
        errcode: 'M_UNRECOGNIZED',
      ),
    };

InboxRecord record(
  String id,
  String name, {
  bool group = false,
  bool archived = false,
  bool technical = false,
  DateTime? at,
  Set<String> networks = const {'whatsapp'},
}) => InboxRecord(
  representativeRoomId: id,
  entityId: id,
  displayName: name,
  metadata: ConversationMetadata(entityId: id, archived: archived),
  networks: networks,
  isGroup: group,
  technical: technical,
  lastActivity: at,
);

SearchChatCandidate chat(InboxRecord record) =>
    SearchChatCandidate(record: record, roomIds: [record.representativeRoomId]);

BridgePerson person(
  String ghost,
  String name, {
  BridgeEndpoint bridge = _whatsapp,
  String? dm,
  List<String> shared = const [],
}) => BridgePerson(
  ghostId: ghost,
  name: name,
  bridge: bridge,
  dmRoomId: dm,
  sharedRooms: shared,
);

void main() {
  group('matching', () {
    test('folds case and diacritics (Polish and Western names)', () {
      expect(searchFold('Łukasz Żółć'), 'lukasz zolc');
      expect(searchFold('Ångström Müller'), 'angstrom muller');
      expect(searchTerms('  Łuk  ŻÓ '), ['luk', 'zo']);
    });

    test('word starts rank before inner matches; every term must match', () {
      final name = searchFold('Anna Kowalska-Nowak');
      expect(searchRank(name, ['ann']), 0);
      expect(searchRank(name, ['nowak']), 0);
      expect(searchRank(name, ['owal']), 1);
      expect(searchRank(name, ['anna', 'kow']), 0);
      expect(searchRank(name, ['anna', 'zz']), isNull);
      expect(searchRank(name, []), isNull);
    });

    test('identifiers: phone, @username and e-mail, never a Matrix id', () {
      final phone = detectIdentifier('+48 600-100 200');
      expect(phone?.kind, SearchIdentifierKind.phone);
      expect(phone?.value, '+48600100200');
      final user = detectIdentifier('@fictional_user');
      expect(user?.kind, SearchIdentifierKind.username);
      expect(user?.value, 'fictional_user');
      expect(user?.display, '@fictional_user');
      expect(
        detectIdentifier('someone@example.invalid')?.kind,
        SearchIdentifierKind.email,
      );
      expect(detectIdentifier('@someone:example.invalid'), isNull);
      expect(detectIdentifier('Anna'), isNull);
      expect(detectIdentifier('12'), isNull);
    });
  });

  group('network usernames', () {
    const ig = SearchHandle(display: '@anna.kowalska', network: 'Instagram');
    const tg = SearchHandle(display: '@AnnaK_tg', network: 'Telegram');
    const tel = SearchHandle(
      display: '+48600100200',
      network: 'WhatsApp',
      phone: true,
    );

    test('match with or without @, any case, start before inside', () {
      expect(searchHandleRank(ig, '@anna.kowalska'), 0);
      expect(searchHandleRank(ig, 'ANNA.KOW'), 0);
      expect(searchHandleRank(ig, '@@anna'), 0);
      // A part after "." or "_" starts too.
      expect(searchHandleRank(ig, 'kowal'), 0);
      expect(searchHandleRank(tg, 'tg'), 0);
      expect(searchHandleRank(tg, 'annak'), 0);
      // Inside a part: 3+ characters only.
      expect(searchHandleRank(ig, 'owals'), 1);
      expect(searchHandleRank(ig, 'ow'), isNull);
      expect(searchHandleRank(ig, 'anna kowalska'), isNull);
      expect(searchHandleRank(ig, '@'), isNull);
      expect(searchHandleRank(ig, 'zz'), isNull);
      expect(ig.label, '@anna.kowalska · Instagram');
    });

    test('phone numbers match by 4+ digits of a number-like query', () {
      expect(searchHandleRank(tel, '+48 600'), 0);
      expect(searchHandleRank(tel, '600 100'), 1);
      expect(searchHandleRank(tel, '200'), isNull);
      expect(searchHandleRank(tel, 'anna 6001'), isNull);
      expect(searchHandleRank(ig, '6001'), isNull);
    });

    test('a chat found by a handle ranks after every name match and '
        'carries the handle; a name match does not', () {
      final now = DateTime.utc(2026, 10, 21, 12);
      SearchChatCandidate withHandles(
        InboxRecord r,
        List<SearchHandle> handles,
      ) => SearchChatCandidate(
        record: r,
        roomIds: [r.representativeRoomId],
        handles: handles,
      );
      final results = mergeUnifiedSearch(
        query: '@anna',
        chats: [
          withHandles(
            record('!ig', 'Zofia', at: now, networks: {'instagram'}),
            const [ig],
          ),
          withHandles(
            record(
              '!tg',
              'Wiktor',
              at: now.subtract(const Duration(days: 1)),
              networks: {'telegram'},
            ),
            const [tg],
          ),
          withHandles(record('!name', 'Anna Nowak'), const []),
          withHandles(record('!inner', 'Joanna'), const []),
          withHandles(record('!none', 'Bob'), const [tel]),
        ],
        people: const [],
        bridges: const [],
        messages: [
          SearchMessageCandidate(
            roomId: '!none',
            eventId: r'$m',
            chatName: 'Bob',
            text: 'ask @anna',
            time: now,
          ),
        ],
      );
      // "@anna" is not a name match ("@" is not part of a name)...
      expect(results.chats.map((c) => c.record.representativeRoomId), [
        '!ig',
        '!tg',
      ]);
      expect(results.chats.first.handle, ig);
      expect(results.chats.first.rank, searchHandleRankOffset);
      // ...message hits stay in their own section.
      expect(results.messages.single.eventId, r'$m');

      final byName = mergeUnifiedSearch(
        query: 'anna',
        chats: [
          withHandles(record('!ig', 'Zofia', at: now), const [ig]),
          withHandles(record('!inner', 'Joanna', at: now), const []),
          withHandles(record('!name', 'Anna Nowak'), const [tg]),
        ],
        people: const [],
        bridges: const [],
      );
      expect(byName.chats.map((c) => c.record.representativeRoomId), [
        '!name',
        '!inner',
        '!ig',
      ]);
      expect(byName.chats.first.handle, isNull);
      expect(byName.chats.last.handle, ig);
    });
  });

  group('bridges', () {
    test('endpoint name, domain and ghost namespace follow bbctl naming', () {
      expect(_whatsapp.name, 'sh-whatsapp');
      expect(_whatsapp.domain, 'beeper.local');
      expect(_whatsapp.ownsGhost('@sh-whatsapp_48600:beeper.local'), isTrue);
      expect(_whatsapp.ownsGhost('@sh-whatsappbot:beeper.local'), isFalse);
      expect(_whatsapp.ownsGhost('@sh-telegram_1:beeper.local'), isFalse);
      expect(_whatsapp.ownsGhost('@sh-whatsapp_1:example.invalid'), isFalse);
    });

    test('network names come from the bridge protocol, never Matrix', () {
      expect(bridgeNetworkOf({'id': 'whatsapp'}), ('whatsapp', 'WhatsApp'));
      expect(bridgeNetworkOf({'id': 'facebookgo'}), ('messenger', 'Messenger'));
      expect(bridgeNetworkOf({'id': 'linkedin', 'displayname': 'LinkedIn'}), (
        'linkedin',
        'LinkedIn',
      ));
      expect(bridgeNetworkOf({'id': 'matrix'}), isNull);
    });

    test('contacts parse bridgev2 answers and show no Matrix id', () {
      final contact = BridgeContact.fromJson({
        'id': '48600100200',
        'name': ' Fictional Person ',
        'avatar_url': 'mxc://example.invalid/a',
        'identifiers': ['tel:+48600100200'],
        'mxid': '@sh-whatsapp_48600100200:beeper.local',
        'dm_room_mxid': '!dm:example.invalid',
      })!;
      expect(contact.name, 'Fictional Person');
      expect(contact.displayIdentifier, '+48600100200');
      expect(contact.ghostId, '@sh-whatsapp_48600100200:beeper.local');
      expect(contact.dmRoomId, '!dm:example.invalid');
      expect(
        const BridgeContact(
          id: '1',
          identifiers: ['telegram:fictional'],
        ).displayIdentifier,
        '@fictional',
      );
      expect(
        const BridgeContact(
          id: '1',
          identifiers: ['matrix:@a:example.invalid'],
        ).displayIdentifier,
        isNull,
      );
      expect(BridgeContact.fromJson({'name': 'no id'}), isNull);
    });
  });

  group('merging and grouping', () {
    final now = DateTime.utc(2026, 10, 21, 12);

    test('chats first: word starts, then visible before archived, newest', () {
      final results = mergeUnifiedSearch(
        query: 'an',
        chats: [
          chat(
            record(
              '!old',
              'Anna old',
              at: now.subtract(const Duration(days: 9)),
            ),
          ),
          chat(record('!new', 'Anna new', at: now)),
          chat(record('!arch', 'Anna archived', archived: true, at: now)),
          chat(record('!inner', 'Joanna', at: now)),
          chat(record('!tech', 'Anna bridge bot', technical: true)),
          chat(record('!other', 'Bob')),
        ],
        people: const [],
        bridges: const [],
      );
      expect(results.chats.map((c) => c.record.representativeRoomId), [
        '!new',
        '!old',
        '!arch',
        '!inner',
      ]);
    });

    test('people are grouped by network; chat members before contacts '
        'before network search', () {
      final directory = BridgeDirectory(
        BridgeProvisioningApi(FakeProvisioning(bridgeAnswers())),
      );
      final state = directory.stateOf(_whatsapp)
        ..status = BridgeRemoteStatus.ready
        ..capabilities = BridgeProvisioningCapabilities.fromJson(
          _allCapabilities,
        )
        ..contacts = [
          const BridgeRemoteContact(
            BridgeContact(id: 'c1', name: 'Anna Contact'),
            null,
          ),
          // The same person as a chat member: shown once.
          const BridgeRemoteContact(
            BridgeContact(
              id: 'c2',
              name: 'Anna Member',
              ghostId: '@sh-whatsapp_2:beeper.local',
            ),
            null,
          ),
          const BridgeRemoteContact(BridgeContact(id: 'c3', name: 'Bob'), null),
        ];
      state.searches['anna'] = [
        const BridgeRemoteContact(
          BridgeContact(id: 'c1', name: 'Anna Contact'),
          null,
        ),
        const BridgeRemoteContact(
          BridgeContact(id: 's1', name: 'Anna Stranger'),
          null,
        ),
      ];
      final results = mergeUnifiedSearch(
        query: 'Anna',
        chats: const [],
        people: [
          person(
            '@sh-whatsapp_2:beeper.local',
            'Anna Member',
            shared: ['Family'],
          ),
          person(
            '@sh-telegram_9:beeper.local',
            'Anna Telegram',
            bridge: _telegram,
          ),
        ],
        bridges: const [_telegram, _whatsapp],
        remote: directory.stateOf,
      );
      expect(results.networks.map((g) => g.bridge.label), [
        'Telegram',
        'WhatsApp',
      ]);
      final whatsapp = results.networks.last;
      expect(whatsapp.people.map((p) => (p.name, p.source)), [
        ('Anna Member', SearchPersonSource.chat),
        ('Anna Contact', SearchPersonSource.contact),
        ('Anna Stranger', SearchPersonSource.search),
      ]);
      expect(whatsapp.people.first.subtitle, 'In Family');
      expect(whatsapp.canSearch, isTrue);
      expect(whatsapp.searched, isTrue);
      expect(whatsapp.canStartChats, isTrue);
      // Telegram is not reachable here: its member still shows, without
      // network actions.
      final telegram = results.networks.first;
      expect(telegram.people.single.name, 'Anna Telegram');
      expect(telegram.status, BridgeRemoteStatus.unknown);
      expect(telegram.hasActions, isFalse);
      expect(telegram.canStartChats, isFalse);
    });

    test(
      'a person whose chat is already listed under Chats is not repeated',
      () {
        final results = mergeUnifiedSearch(
          query: 'anna',
          chats: [chat(record('!dm', 'Anna Member'))],
          people: [
            person('@sh-whatsapp_2:beeper.local', 'Anna Member', dm: '!dm'),
            person('@sh-whatsapp_3:beeper.local', 'Anna Other', dm: '!dm3'),
          ],
          bridges: const [_whatsapp],
        );
        expect(results.chats.single.record.displayName, 'Anna Member');
        final people = results.networks.single.people;
        expect(people.map((p) => p.name), ['Anna Other']);
        // Her chat exists (renamed in the inbox): the row opens it.
        expect(people.single.roomId, '!dm3');
        expect(people.single.hasChat, isTrue);
      },
    );

    test('contacts match by phone digits; lookups only where supported', () {
      final directory = BridgeDirectory(
        BridgeProvisioningApi(FakeProvisioning(bridgeAnswers())),
      );
      directory.stateOf(_whatsapp)
        ..status = BridgeRemoteStatus.ready
        ..capabilities = const BridgeProvisioningCapabilities(
          createDm: true,
          lookupPhone: true,
          contactList: true,
        )
        ..contacts = [
          const BridgeRemoteContact(
            BridgeContact(
              id: 'p',
              name: 'Plumber',
              identifiers: ['tel:+48600100200'],
            ),
            null,
          ),
        ];
      directory.stateOf(_telegram)
        ..status = BridgeRemoteStatus.ready
        ..capabilities = const BridgeProvisioningCapabilities(
          lookupUsername: true,
        );
      final results = mergeUnifiedSearch(
        query: '600 100',
        chats: const [],
        people: const [],
        bridges: const [_telegram, _whatsapp],
        remote: directory.stateOf,
      );
      final whatsapp = results.networks.single;
      expect(whatsapp.bridge, _whatsapp);
      expect(whatsapp.people.single.name, 'Plumber');
      expect(whatsapp.people.single.subtitle, '+48600100200 · Contact');
      // "600 100" is too short for a phone lookup.
      expect(whatsapp.lookup, isNull);
      final phone = mergeUnifiedSearch(
        query: '+48 600 100 200',
        chats: const [],
        people: const [],
        bridges: const [_telegram, _whatsapp],
        remote: directory.stateOf,
      );
      expect(phone.networks.single.lookup?.value, '+48600100200');
      final username = mergeUnifiedSearch(
        query: '@fictional',
        chats: const [],
        people: const [],
        bridges: const [_telegram, _whatsapp],
        remote: directory.stateOf,
      );
      expect(username.networks.single.bridge, _telegram);
      expect(username.networks.single.lookup?.display, '@fictional');
    });

    test('messages: matching latest messages, newest first', () {
      final results = mergeUnifiedSearch(
        query: 'invoice',
        chats: const [],
        people: const [],
        bridges: const [],
        messages: [
          SearchMessageCandidate(
            roomId: '!a',
            eventId: r'$1',
            chatName: 'Accounting',
            text: 'Invoice attached',
            time: now.subtract(const Duration(hours: 1)),
          ),
          SearchMessageCandidate(
            roomId: '!b',
            eventId: r'$2',
            chatName: 'Shop',
            text: 'Your invoice is ready',
            time: now,
          ),
          SearchMessageCandidate(
            roomId: '!c',
            eventId: r'$3',
            chatName: 'Friends',
            text: 'Lunch?',
            time: now,
          ),
        ],
      );
      expect(results.messages.map((m) => m.eventId), [r'$2', r'$1']);
      expect(results.isEmpty, isFalse);
      expect(
        mergeUnifiedSearch(
          query: '   ',
          chats: [chat(record('!a', 'Anything'))],
          people: const [],
          bridges: const [],
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('directory (fake provisioning)', () {
    test(
      'probe asks whoami and capabilities once; typing sends nothing',
      () async {
        final transport = FakeProvisioning(bridgeAnswers());
        final directory = BridgeDirectory(BridgeProvisioningApi(transport));
        expect(transport.requests, isEmpty);
        await directory.probe([_whatsapp]);
        await directory.probe([_whatsapp]);
        expect(transport.paths, ['GET /v3/whoami', 'GET /v3/capabilities']);
        final state = directory.stateOf(_whatsapp);
        expect(state.status, BridgeRemoteStatus.ready);
        expect(state.capabilities.createDm, isTrue);
        await directory.loadContacts([_whatsapp]);
        await directory.loadContacts([_whatsapp]);
        expect(transport.paths.last, 'GET /v3/contacts');
        expect(
          transport.requests.where((r) => r.$3 == '/v3/contacts'),
          hasLength(1),
        );
        // No request carries a query until an explicit search.
        expect(transport.requests.every((r) => r.$5 == null), isTrue);
        await directory.searchUsers(_whatsapp, 'Fictional');
        expect(transport.requests.last.$3, '/v3/search_users');
        expect(transport.requests.last.$5, {'query': 'Fictional'});
        await directory.searchUsers(_whatsapp, 'fictional');
        expect(
          transport.requests.where((r) => r.$3 == '/v3/search_users'),
          hasLength(1),
        );
        await directory.lookUp(_whatsapp, detectIdentifier('+48600100200')!);
        expect(
          transport.paths.last,
          'GET /v3/resolve_identifier/%2B48600100200',
        );
        expect(state.lookups.containsKey('+48600100200'), isTrue);
        expect(state.lookups['+48600100200'], isNull);
        expect(transport.paths.where((p) => p.contains('create_dm')), isEmpty);
      },
    );

    test(
      'unreachable, foreign or logged-out bridges are reported, not used',
      () async {
        final transport = FakeProvisioning((bridge, request) {
          if (bridge == _telegram) {
            throw const BridgeProvisioningException(
              404,
              errcode: 'M_UNRECOGNIZED',
            );
          }
          if (request.path == '/v3/whoami') {
            return whoami(
              bridge,
              logins: [
                {
                  'id': 'l',
                  'name': 'x',
                  'state': {'state_event': 'LOGGED_OUT'},
                },
              ],
            );
          }
          return _allCapabilities;
        });
        final directory = BridgeDirectory(BridgeProvisioningApi(transport));
        await directory.probe([_telegram, _whatsapp]);
        expect(
          directory.stateOf(_telegram).status,
          BridgeRemoteStatus.unavailable,
        );
        expect(
          directory.stateOf(_telegram).reason,
          'ChatLoom can’t reach this bridge',
        );
        expect(
          directory.stateOf(_whatsapp).status,
          BridgeRemoteStatus.notLoggedIn,
        );
        await directory.loadContacts([_telegram, _whatsapp]);
        await directory.searchUsers(_telegram, 'anna');
        expect(transport.paths.where((p) => p.contains('contacts')), isEmpty);
        expect(transport.paths.where((p) => p.contains('search')), isEmpty);

        // A route that answers with another bridge's whoami is not this bridge.
        final foreign = FakeProvisioning(
          (bridge, request) => whoami(_telegram),
        );
        final second = BridgeDirectory(BridgeProvisioningApi(foreign));
        await second.probe([_whatsapp]);
        expect(
          second.stateOf(_whatsapp).status,
          BridgeRemoteStatus.unavailable,
        );
      },
    );

    test('bridges the route cannot reach are never asked', () async {
      final transport = FakeProvisioning(bridgeAnswers());
      final directory = BridgeDirectory(
        BridgeProvisioningApi(transport),
        reaches: (bridge) => bridge.domain == 'beeper.local',
      );
      const foreign = BridgeEndpoint(
        botId: '@telegrambot:example.invalid',
        network: 'telegram',
        label: 'Telegram',
      );
      await directory.probe([foreign, _whatsapp]);
      expect(directory.stateOf(foreign).status, BridgeRemoteStatus.unavailable);
      expect(directory.stateOf(_whatsapp).status, BridgeRemoteStatus.ready);
      expect(transport.requests.where((r) => r.$1 == foreign.botId), isEmpty);
    });

    test('a disabled directory never makes requests', () async {
      final directory = BridgeDirectory.disabled('Not on Beeper.');
      await directory.probe([_whatsapp]);
      await directory.loadContacts([_whatsapp]);
      await directory.searchUsers(_whatsapp, 'anna');
      expect(
        directory.stateOf(_whatsapp).status,
        BridgeRemoteStatus.unavailable,
      );
      expect(directory.stateOf(_whatsapp).reason, 'Not on Beeper.');
    });
  });

  group('Beeper transport (mock HTTP, no network)', () {
    BeeperProvisioningTransport transport(
      Future<http.Response> Function(http.Request request) handler, {
      String override = '',
      String homeserver = 'https://matrix.example.invalid',
    }) => BeeperProvisioningTransport(
      httpClient: MockClient(handler),
      homeserver: Uri.parse(homeserver),
      userId: '@fictional:example.invalid',
      accessToken: () => 'fictional-token',
      overrideUrl: override,
    );

    test('wraps requests in an http_proxy exec on hungryserv', () async {
      late http.Request sent;
      final client = transport((request) async {
        sent = request;
        return http.Response(
          jsonEncode({'status': 200, 'headers': {}, 'body': whoami(_whatsapp)}),
          200,
        );
      });
      final answer = await BridgeProvisioningApi(client).whoami(_whatsapp);
      expect(answer.networkName, 'WhatsApp');
      expect(sent.method, 'POST');
      expect(
        sent.url.toString(),
        'https://matrix.example.invalid/_hungryserv/fictional/_matrix/asmux/'
        'mxauth/appservice/fictional/sh-whatsapp/exec/http_proxy',
      );
      expect(sent.headers['Authorization'], 'Bearer fictional-token');
      final body = jsonDecode(sent.body) as Map;
      expect(body['method'], 'GET');
      expect(body['path'], '/_matrix/provision/v3/whoami');
      expect(Uri.splitQueryString(body['query'] as String), {
        'user_id': '@fictional:example.invalid',
      });
      expect(body['headers']['Authorization'], ['Bearer fictional-token']);
      expect(body.containsKey('body'), isFalse);
    });

    test('preserves an already scoped homeserver without duplicating routing', () async {
      late Uri sent;
      final client = transport(
        (request) async {
          sent = request.url;
          return http.Response(
            jsonEncode({'status': 200, 'headers': {}, 'body': whoami(_whatsapp)}),
            200,
          );
        },
        homeserver: 'https://matrix.example.invalid/_hungryserv/fictional',
      );
      await BridgeProvisioningApi(client).whoami(_whatsapp);
      expect(
        sent.path,
        '/_hungryserv/fictional/_matrix/asmux/mxauth/appservice/'
        'fictional/sh-whatsapp/exec/http_proxy',
      );
    });
    test('unwraps base64 bodies and maps bridge and proxy errors', () async {
      final ok = transport(
        (request) async => http.Response(
          jsonEncode({
            'status': 200,
            'body': base64
                .encode(utf8.encode(jsonEncode({'contacts': []})))
                .replaceAll('=', ''),
          }),
          200,
        ),
      );
      expect(await BridgeProvisioningApi(ok).contacts(_whatsapp), isEmpty);
      final bridgeError = transport(
        (request) async => http.Response(
          jsonEncode({
            'status': 400,
            'body': {
              'errcode': 'FI.MAU.NOT_LOGGED_IN',
              'error': 'Not logged in',
            },
          }),
          200,
        ),
      );
      await expectLater(
        BridgeProvisioningApi(bridgeError).contacts(_whatsapp),
        throwsA(
          isA<BridgeProvisioningException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.errcode, 'errcode', 'FI.MAU.NOT_LOGGED_IN')
              .having((e) => e.message, 'message', 'Not logged in'),
        ),
      );
      final noRoute = transport(
        (request) async => http.Response(
          jsonEncode({'errcode': 'M_UNRECOGNIZED', 'error': 'Unrecognized'}),
          404,
        ),
      );
      final error = await BridgeProvisioningApi(noRoute)
          .whoami(_whatsapp)
          .then<Object>((_) => 'no error', onError: (Object e) => e);
      expect(error, isA<BridgeProvisioningException>());
      error as BridgeProvisioningException;
      expect(error.unreachable, isTrue);
      expect(error.toString(), isNot(contains('fictional-token')));
      expect(error.toString(), isNot(contains('example.invalid')));
      final offline = transport(
        (request) async => throw http.ClientException('x'),
      );
      await expectLater(
        BridgeProvisioningApi(offline).whoami(_whatsapp),
        throwsA(
          isA<BridgeProvisioningException>().having(
            (e) => e.status,
            'status',
            0,
          ),
        ),
      );
    });

    test('an override URL calls the provisioning API directly', () async {
      late http.Request sent;
      final client = transport((request) async {
        sent = request;
        return http.Response(
          jsonEncode({'id': 'u', 'dm_room_mxid': '!dm:example.invalid'}),
          201,
        );
      }, override: 'https://bridges.example.invalid/{bridge}/');
      final contact = await BridgeProvisioningApi(
        client,
      ).createDm(_whatsapp, '+48600100200', loginId: 'login-1');
      expect(contact.dmRoomId, '!dm:example.invalid');
      expect(sent.method, 'POST');
      expect(
        sent.url.path,
        '/sh-whatsapp/_matrix/provision/v3/create_dm/%2B48600100200',
      );
      expect(sent.url.queryParameters, {
        'user_id': '@fictional:example.invalid',
        'login_id': 'login-1',
      });
      expect(jsonDecode(sent.body), <String, Object?>{});
    });
  });

  group('http_proxy path parameters (as mautrix-go wshttp.go reads them)', () {
    const instagram = BridgeEndpoint(
      botId: '@sh-instagrambot:beeper.local',
      network: 'instagram',
      label: 'Instagram',
    );
    const messenger = BridgeEndpoint(
      botId: '@sh-metabot:beeper.local',
      network: 'facebook',
      label: 'Messenger',
    );

    /// The `{identifier}` a bridge's router sees for a proxied request:
    /// `path` is taken as decoded text unless `escaped_path` is set
    /// (`appservice/wshttp.go`), and Go's mux unescapes each raw segment.
    String routedIdentifier(Map<Object?, Object?> proxied) {
      final path = proxied['path'] as String;
      final segments = path.split('/');
      return proxied['escaped_path'] == true
          ? Uri.decodeComponent(segments.last)
          : segments.last;
    }

    /// A hungryserv + bridge that records what the bridge router saw.
    (BeeperProvisioningTransport, List<String>, List<Map<Object?, Object?>>)
    bridge() {
      final seen = <String>[];
      final proxied = <Map<Object?, Object?>>[];
      final transport = BeeperProvisioningTransport(
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<Object?, Object?>;
          proxied.add(body);
          seen.add(routedIdentifier(body));
          return http.Response(
            jsonEncode({
              'status': 201,
              'headers': {},
              'body': {
                'id': '1000001',
                'mxid': '@sh-instagram_1000001:beeper.local',
                'dm_room_mxid': '!created:example.invalid',
              },
            }),
            200,
          );
        }),
        homeserver: Uri.parse('https://matrix.example.invalid'),
        userId: '@fictional:example.invalid',
        accessToken: () => 'fictional-token',
        overrideUrl: '',
      );
      return (transport, seen, proxied);
    }

    test('create_dm reaches the bridge with the ghost id, not %-escapes', () async {
      final (transport, seen, proxied) = bridge();
      final api = BridgeProvisioningApi(transport);
      await api.createDm(
        instagram,
        '@sh-instagram_1000001:beeper.local',
        loginId: 'login-1',
      );
      await api.createDm(messenger, '@sh-meta_1000002:beeper.local');
      await api.createDm(_whatsapp, '+48600100200');
      await api.createDm(_telegram, '1000003');
      expect(seen, [
        '@sh-instagram_1000001:beeper.local',
        '@sh-meta_1000002:beeper.local',
        '+48600100200',
        '1000003',
      ]);
      expect(proxied.first['method'], 'POST');
      expect(
        proxied.first['path'],
        '/_matrix/provision/v3/create_dm/@sh-instagram_1000001:beeper.local',
      );
      expect(proxied.first.containsKey('escaped_path'), isFalse);
      expect(Uri.splitQueryString(proxied.first['query'] as String), {
        'user_id': '@fictional:example.invalid',
        'login_id': 'login-1',
      });
    });

    test('resolve_identifier lookups are routed the same way', () async {
      final (transport, seen, _) = bridge();
      await BridgeProvisioningApi(
        transport,
      ).resolveIdentifier(_whatsapp, '+48 600 100 200');
      expect(seen, ['+48 600 100 200']);
    });

    test('an identifier with a slash keeps its segment via escaped_path', () async {
      final (transport, seen, proxied) = bridge();
      await BridgeProvisioningApi(transport).createDm(_telegram, 'a/b');
      expect(proxied.single['escaped_path'], isTrue);
      expect(proxied.single['path'], '/_matrix/provision/v3/create_dm/a%2Fb');
      expect(seen, ['a/b']);
    });

    test('a found Instagram person opens the bridged DM once it syncs', () async {
      final (transport, seen, _) = bridge();
      final directory = BridgeDirectory(BridgeProvisioningApi(transport));
      final client = Client('fictional instagram', database: _NoDatabase());
      final pending = startBridgedChat(
        directory: directory,
        bridge: instagram,
        identifier: '@sh-instagram_1000001:beeper.local',
        loginId: 'login-1',
        client: client,
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Beeper delivers the portal as an invite first; it still opens.
      final room = Room(
        id: '!created:example.invalid',
        client: client,
        membership: Membership.invite,
      );
      client.rooms.add(room);
      client.onSyncStatus.add(SyncStatusUpdate(SyncStatus.finished));
      expect(await pending, same(room));
      expect(seen, ['@sh-instagram_1000001:beeper.local']);
    });
  });

  group('starting a chat (fake bridge, synthetic client)', () {
    test('creates the DM once and returns the room when it arrives', () async {
      final transport = FakeProvisioning(bridgeAnswers());
      final directory = BridgeDirectory(BridgeProvisioningApi(transport));
      final client = Client('fictional start chat', database: _NoDatabase());
      final pending = startBridgedChat(
        directory: directory,
        bridge: _whatsapp,
        identifier: '@sh-whatsapp_2:beeper.local',
        client: client,
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.paths, [
        'POST /v3/create_dm/%40sh-whatsapp_2%3Abeeper.local',
      ]);
      final room = Room(
        id: '!created:example.invalid',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(room);
      client.onSyncStatus.add(SyncStatusUpdate(SyncStatus.finished));
      expect(await pending, same(room));
      expect(
        transport.paths.where((p) => p.contains('create_dm')),
        hasLength(1),
      );
    });

    test('times out without the room and explains failures plainly', () async {
      final transport = FakeProvisioning(bridgeAnswers());
      final directory = BridgeDirectory(BridgeProvisioningApi(transport));
      final client = Client('fictional timeout', database: _NoDatabase());
      await expectLater(
        startBridgedChat(
          directory: directory,
          bridge: _whatsapp,
          identifier: 'network-user',
          client: client,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        bridgedChatError(TimeoutException('x'), 'WhatsApp'),
        contains('WhatsApp'),
      );
      expect(
        bridgedChatError(
          const BridgeProvisioningException(404, errcode: 'M_UNRECOGNIZED'),
          'WhatsApp',
        ),
        'ChatLoom can’t reach your WhatsApp bridge.',
      );
      expect(
        bridgedChatError(
          const BridgeProvisioningException(
            400,
            message: 'Identifier not found',
          ),
          'WhatsApp',
        ),
        'No one on WhatsApp has that number or username.',
      );
      // The network's own sentence stays; bridgev2's technical ones don't.
      expect(
        bridgedChatError(
          const BridgeProvisioningException(
            400,
            message: 'The phone number is not on WhatsApp',
          ),
          'WhatsApp',
        ),
        'The phone number is not on WhatsApp.',
      );
      expect(
        bridgedChatError(
          const BridgeProvisioningException(
            400,
            errcode: 'FI.MAU.NOT_LOGGED_IN',
            message: 'Not logged in',
          ),
          'WhatsApp',
        ),
        'You’re signed out of WhatsApp. Sign in on the Networks page.',
      );
      expect(
        bridgedChatError(
          const BridgeProvisioningException(
            500,
            errcode: 'M_UNKNOWN',
            message: 'Failed to create portal room',
          ),
          'WhatsApp',
        ),
        'The bridge couldn’t open the chat. Try again.',
      );
      expect(
        bridgedChatError(
          const BridgeProvisioningException(
            500,
            errcode: 'M_UNKNOWN',
            message: 'Internal error resolving identifier',
          ),
          'Instagram',
        ),
        'The bridge couldn’t find or open this person on Instagram. Try '
        'again later.',
      );
      expect(
        bridgedChatError(
          const BridgeProvisioningException(
            404,
            errcode: 'M_UNRECOGNIZED',
            message: 'This bridge does not support resolving identifiers',
          ),
          'Messenger',
        ),
        'This bridge can’t start new chats.',
      );
      expect(
        bridgedChatError(
          const BridgeProvisioningException(400, message: 'M_NOT_JSON'),
          'WhatsApp',
        ),
        'The bridge couldn’t do that.',
      );
    });
  });
}

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}
