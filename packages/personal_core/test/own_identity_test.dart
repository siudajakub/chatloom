// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional identifiers only.
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

const account = '@owner:example.invalid';
const tgBot = '@telegrambot:bridge.invalid';
const waBot = '@whatsappbot:bridge.invalid';
const sigBot = '@signalbot:bridge.invalid';

Map<String, dynamic> bridge(
  String bot,
  String protocol, {
  String? receiver,
  String? channel,
  String? type,
}) => {
  'bridgebot': bot,
  'protocol': {'id': protocol},
  'channel': {'id': ?channel, 'fi.mau.receiver': ?receiver},
  'com.beeper.room_type.v2': ?type,
};

/// By default every declaration is sent by its own bridge bot, which is
/// joined, in a room the owner joined; [sender], [botJoined] and
/// [ownerJoined] model spoofed or stale declarations.
BridgeRoomSnapshot room(
  String id,
  List<Map<String, dynamic>> bridges, {
  String? direct,
  Map<String, String?> members = const {},
  String? sender,
  bool botJoined = true,
  bool ownerJoined = true,
}) => BridgeRoomSnapshot(
  roomId: id,
  ownerJoined: ownerJoined,
  bridges: bridges
      .map(
        (content) => BridgeInfoSnapshot.fromContent(
          content,
          senderId: sender ?? content['bridgebot'] as String?,
          isJoined: (_) => botJoined,
        ),
      )
      .whereType<BridgeInfoSnapshot>()
      .toList(),
  directPartnerId: direct,
  joinedMembers: {account: 'Owner', ...members},
);

OwnRemoteIdentity resolve(
  List<BridgeRoomSnapshot> rooms, {
  String? Function(String)? names,
}) => OwnRemoteIdentity.resolve(
  accountUserId: account,
  rooms: rooms,
  displaynameOf: names,
);

void main() {
  test('account itself is always own; nothing else without evidence', () {
    final identity = resolve([]);
    expect(identity.isOwn(account), isTrue);
    expect(identity.evidenceFor(account), OwnIdentityEvidence.account);
    expect(identity.isOwn('@telegram_100:bridge.invalid'), isFalse);
    expect(identity.ownGhostIds, isEmpty);
  });

  test(
    'Telegram receiver ghost is own in DMs and in groups without receiver',
    () {
      final dm = room(
        '!dm:example.invalid',
        [
          bridge(
            tgBot,
            'telegram',
            receiver: '100',
            channel: '200',
            type: 'dm',
          ),
        ],
        members: {
          tgBot: 'Telegram bridge bot',
          '@telegram_200:bridge.invalid': 'Partner',
          '@telegram_100:bridge.invalid': 'excellent P',
        },
      );
      final group = room('!group:example.invalid', [
        bridge(tgBot, 'telegram', channel: '-1009', type: 'group_dm'),
      ]);
      final identity = resolve([dm, group]);
      expect(identity.isOwn('@telegram_100:bridge.invalid'), isTrue);
      expect(
        identity.evidenceFor('@telegram_100:bridge.invalid'),
        OwnIdentityEvidence.receiver,
      );
      expect(identity.isOwn('@telegram_200:bridge.invalid'), isFalse);
      expect(identity.isOwn(tgBot), isFalse);
      // Same id on another server is somebody else.
      expect(identity.isOwn('@telegram_100:other.invalid'), isFalse);
      // Suffix collisions do not match.
      expect(identity.isOwn('@telegram_1100:bridge.invalid'), isFalse);
    },
  );

  test('go-suffixed protocol and bot localpart give the ghost prefix', () {
    final info = BridgeInfoSnapshot.fromContent(
      bridge('@sh-telegrambot:bridge.invalid', 'telegramgo', receiver: '5'),
    )!;
    expect(info.ghostPrefixes, containsAll(['telegramgo', 'telegram']));
    expect(info.receiverGhostIds, contains('@telegram_5:bridge.invalid'));
  });

  test('Signal ACI receiver ghost', () {
    const aci = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';
    final identity = resolve([
      room('!signal:example.invalid', [
        bridge(
          sigBot,
          'signal',
          receiver: aci,
          channel: '11111111-2222-3333-4444-555555555555',
          type: 'dm',
        ),
      ]),
    ]);
    expect(identity.isOwn('@signal_$aci:bridge.invalid'), isTrue);
    expect(
      identity.isOwn(
        '@signal_11111111-2222-3333-4444-555555555555:bridge.invalid',
      ),
      isFalse,
    );
  });

  test('WhatsApp LID own ghost in a DM, corroborated by own display name', () {
    final group = room(
      '!wa-group:example.invalid',
      [bridge(waBot, 'whatsapp', channel: '1203@g.us', type: 'group_dm')],
      members: {'@whatsapp_48100:bridge.invalid': 'excellent P'},
    );
    final dm = room(
      '!wa-dm:example.invalid',
      [
        bridge(
          waBot,
          'whatsapp',
          receiver: '48100',
          channel: '48200@s.whatsapp.net',
          type: 'dm',
        ),
      ],
      members: {
        waBot: 'WhatsApp bridge bot',
        '@whatsapp_48200:bridge.invalid': 'Partner',
        '@whatsapp_lid-777:bridge.invalid': 'excellent P',
      },
    );
    final identity = resolve([group, dm]);
    expect(identity.isOwn('@whatsapp_48100:bridge.invalid'), isTrue);
    expect(
      identity.isOwn(
        '@whatsapp_lid-777:bridge.invalid',
        roomId: '!wa-dm:example.invalid',
      ),
      isTrue,
    );
    expect(
      identity.evidenceFor(
        '@whatsapp_lid-777:bridge.invalid',
        roomId: '!wa-dm:example.invalid',
      ),
      OwnIdentityEvidence.dmStructure,
    );
    // Layer-2 evidence stays in the DM it came from and is weak.
    expect(
      identity.isOwn(
        '@whatsapp_lid-777:bridge.invalid',
        roomId: '!wa-group:example.invalid',
      ),
      isFalse,
    );
    expect(identity.isOwn('@whatsapp_lid-777:bridge.invalid'), isFalse);
    expect(identity.isStronglyOwn('@whatsapp_lid-777:bridge.invalid'), isFalse);
    expect(identity.isStronglyOwn('@whatsapp_48100:bridge.invalid'), isTrue);
    expect(identity.isOwn('@whatsapp_48200:bridge.invalid'), isFalse);
  });

  test(
    'own name may come from the adapter lookup instead of a member list',
    () {
      final dm = room(
        '!wa-dm:example.invalid',
        [
          bridge(
            waBot,
            'whatsapp',
            receiver: '48100',
            channel: '48200@s.whatsapp.net',
            type: 'dm',
          ),
        ],
        members: {
          '@whatsapp_48200:bridge.invalid': 'Partner',
          '@whatsapp_lid-777:bridge.invalid': 'excellent P',
        },
      );
      final identity = resolve(
        [dm],
        names: (id) =>
            id == '@whatsapp_48100:bridge.invalid' ? 'excellent P' : null,
      );
      expect(
        identity.isOwn(
          '@whatsapp_lid-777:bridge.invalid',
          roomId: '!wa-dm:example.invalid',
        ),
        isTrue,
      );
    },
  );

  test('recurring extra ghost in two DMs is own without a known name', () {
    BridgeRoomSnapshot dm(String partner) => room(
      '!dm-$partner:example.invalid',
      [
        bridge(
          waBot,
          'whatsapp',
          channel: '$partner@s.whatsapp.net',
          type: 'dm',
        ),
      ],
      members: {
        '@whatsapp_$partner:bridge.invalid': 'Partner $partner',
        '@whatsapp_lid-777:bridge.invalid': 'Someone',
      },
    );
    final identity = resolve([dm('48201'), dm('48202')]);
    for (final id in [
      '!dm-48201:example.invalid',
      '!dm-48202:example.invalid',
    ]) {
      expect(
        identity.isOwn('@whatsapp_lid-777:bridge.invalid', roomId: id),
        isTrue,
      );
    }
    expect(
      identity.isOwn(
        '@whatsapp_lid-777:bridge.invalid',
        roomId: '!other:example.invalid',
      ),
      isFalse,
    );
    expect(identity.isOwn('@whatsapp_48201:bridge.invalid'), isFalse);
  });

  group('false-positive guards', () {
    test('a single DM extra ghost without corroboration stays foreign', () {
      // E.g. the partner's own LID alias ghost.
      final identity = resolve([
        room(
          '!wa-dm:example.invalid',
          [
            bridge(
              waBot,
              'whatsapp',
              channel: '48200@s.whatsapp.net',
              type: 'dm',
            ),
          ],
          members: {
            '@whatsapp_48200:bridge.invalid': 'Mom',
            '@whatsapp_lid-555:bridge.invalid': 'Anna',
          },
        ),
      ]);
      expect(identity.ownGhostIds, isEmpty);
    });

    test('extra ghost with the partner display name is the partner alias', () {
      BridgeRoomSnapshot dm(String id, String partner) => room(
        id,
        [
          bridge(
            waBot,
            'whatsapp',
            channel: '$partner@s.whatsapp.net',
            type: 'dm',
          ),
        ],
        members: {
          '@whatsapp_$partner:bridge.invalid': 'Anna',
          '@whatsapp_lid-555:bridge.invalid': 'Anna',
        },
      );
      final identity = resolve([
        dm('!a:example.invalid', '48200'),
        dm('!b:example.invalid', '48200'),
      ]);
      expect(identity.ownGhostIds, isEmpty);
    });

    test('known own name rejects a differently named extra ghost', () {
      final identity = resolve([
        room(
          '!wa-dm:example.invalid',
          [
            bridge(
              waBot,
              'whatsapp',
              receiver: '48100',
              channel: '48200@s.whatsapp.net',
              type: 'dm',
            ),
          ],
          members: {
            '@whatsapp_48100:bridge.invalid': 'excellent P',
            '@whatsapp_48200:bridge.invalid': 'Partner',
            '@whatsapp_lid-555:bridge.invalid': 'Partner (LID)',
          },
        ),
      ]);
      expect(identity.isOwn('@whatsapp_lid-555:bridge.invalid'), isFalse);
      expect(identity.isOwn('@whatsapp_48100:bridge.invalid'), isTrue);
    });

    test('display name alone never identifies a group member', () {
      final identity = resolve([
        room(
          '!group:example.invalid',
          [bridge(tgBot, 'telegram', channel: '-100', type: 'group_dm')],
          members: {
            '@telegram_300:bridge.invalid': 'excellent P',
            '@telegram_301:bridge.invalid': 'Other',
          },
        ),
        room(
          '!dm:example.invalid',
          [bridge(tgBot, 'telegram', receiver: '100', type: 'dm')],
          members: {'@telegram_100:bridge.invalid': 'excellent P'},
        ),
      ]);
      expect(identity.isOwn('@telegram_300:bridge.invalid'), isFalse);
      expect(identity.isOwn('@telegram_100:bridge.invalid'), isTrue);
    });

    test('native m.direct and channel id disagreeing makes a DM ambiguous', () {
      BridgeRoomSnapshot dm(String id) => room(
        id,
        [bridge(waBot, 'whatsapp', channel: '48200@s.whatsapp.net')],
        direct: '@whatsapp_lid-9:bridge.invalid',
        members: {
          '@whatsapp_48200:bridge.invalid': 'Partner',
          '@whatsapp_lid-9:bridge.invalid': 'Other',
        },
      );
      final identity = resolve([
        dm('!a:example.invalid'),
        dm('!b:example.invalid'),
      ]);
      expect(identity.ownGhostIds, isEmpty);
    });

    test('a ghost that is the partner of another DM is never own', () {
      BridgeRoomSnapshot dm(String id, String partner, String extra) => room(
        id,
        [
          bridge(
            waBot,
            'whatsapp',
            channel: '$partner@s.whatsapp.net',
            type: 'dm',
          ),
        ],
        members: {
          '@whatsapp_$partner:bridge.invalid': 'P $partner',
          '@whatsapp_$extra:bridge.invalid': 'X $extra',
        },
      );
      final identity = resolve([
        dm('!a:example.invalid', '1', '2'),
        dm('!b:example.invalid', '3', '2'),
        dm('!c:example.invalid', '2', '4'),
      ]);
      expect(identity.isOwn('@whatsapp_2:bridge.invalid'), isFalse);
    });

    test('unsafe receivers and malformed bridge content are ignored', () {
      expect(BridgeInfoSnapshot.fromContent({'bridgebot': 'nobody'}), isNull);
      expect(BridgeInfoSnapshot.fromContent('x'), isNull);
      final info = BridgeInfoSnapshot.fromContent(
        bridge(tgBot, 'telegram', receiver: 'Has Space'),
      )!;
      expect(info.receiverGhostIds, isEmpty);
    });
  });

  test('display-name tie-break only inside a DM with an unknown partner', () {
    final identity = resolve([
      room(
        '!tg-dm:example.invalid',
        [bridge(tgBot, 'telegram', receiver: '100', type: 'dm')],
        members: {'@telegram_100:bridge.invalid': 'excellent P'},
      ),
      room(
        '!odd-dm:example.invalid',
        [bridge(tgBot, 'telegram', type: 'dm')],
        members: {
          '@telegram_a1:bridge.invalid': 'excellent P',
          '@telegram_b2:bridge.invalid': 'Partner',
        },
      ),
    ]);
    expect(
      identity.isOwn(
        '@telegram_a1:bridge.invalid',
        roomId: '!odd-dm:example.invalid',
      ),
      isTrue,
    );
    expect(
      identity.evidenceFor(
        '@telegram_a1:bridge.invalid',
        roomId: '!odd-dm:example.invalid',
      ),
      OwnIdentityEvidence.displaynameTieBreak,
    );
    expect(OwnIdentityEvidence.displaynameTieBreak.strong, isFalse);
    expect(
      identity.isOwn(
        '@telegram_a1:bridge.invalid',
        roomId: '!tg-dm:example.invalid',
      ),
      isFalse,
    );
    expect(identity.isStronglyOwn('@telegram_a1:bridge.invalid'), isFalse);
    expect(identity.isOwn('@telegram_b2:bridge.invalid'), isFalse);
  });

  group('bridge declaration trust (spoofing)', () {
    Map<String, dynamic> spoofed() => bridge(
      tgBot,
      'telegram',
      // A real contact's remote id declared as "receiver".
      receiver: '200',
      channel: '-1001',
      type: 'group_dm',
    );
    const contact = '@telegram_200:bridge.invalid';

    test('a declaration sent by somebody other than the bot is ignored', () {
      final identity = resolve([
        room('!attacker:example.invalid', [
          spoofed(),
        ], sender: '@mallory:example.invalid'),
      ]);
      expect(identity.isOwn(contact), isFalse);
      expect(identity.ownGhostIds, isEmpty);
    });

    test('a declaration whose bridge bot is not joined is ignored', () {
      final identity = resolve([
        room('!stale:example.invalid', [spoofed()], botJoined: false),
      ]);
      expect(identity.isOwn(contact), isFalse);
    });

    test('a declaration in a room the owner has not joined is ignored', () {
      final identity = resolve([
        room('!invite:example.invalid', [spoofed()], ownerJoined: false),
      ]);
      expect(identity.isOwn(contact), isFalse);
    });

    test('declarations without provenance are never trusted', () {
      final info = BridgeInfoSnapshot.fromContent(spoofed())!;
      expect(info.trusted, isFalse);
      final identity = OwnRemoteIdentity.resolve(
        accountUserId: account,
        rooms: [
          BridgeRoomSnapshot(
            roomId: '!raw:example.invalid',
            bridges: [info],
            ownerJoined: true,
          ),
        ],
      );
      expect(identity.isOwn(contact), isFalse);
    });

    test('a spoofed declaration next to a trusted one is dropped alone', () {
      final trusted = room('!dm:example.invalid', [
        bridge(tgBot, 'telegram', receiver: '100', channel: '200', type: 'dm'),
      ]);
      final mixed = BridgeRoomSnapshot(
        roomId: '!mixed:example.invalid',
        ownerJoined: true,
        bridges: [
          BridgeInfoSnapshot.fromContent(
            bridge(tgBot, 'telegram', channel: '-100', type: 'group_dm'),
            senderId: tgBot,
            isJoined: (_) => true,
          )!,
          BridgeInfoSnapshot.fromContent(
            spoofed(),
            senderId: '@mallory:example.invalid',
            isJoined: (_) => true,
          )!,
        ],
      );
      final identity = resolve([trusted, mixed]);
      expect(identity.isStronglyOwn('@telegram_100:bridge.invalid'), isTrue);
      expect(identity.isOwn(contact), isFalse);
    });

    test('a foreign sender cannot exclude the partner as a "bridge bot"', () {
      // Declaring the partner ghost as bridgebot would hide it from the DM
      // structure and turn another ghost into the "extra" own ghost.
      BridgeRoomSnapshot dm(String id) => room(
        id,
        [
          bridge(
            waBot,
            'whatsapp',
            channel: '48200@s.whatsapp.net',
            type: 'dm',
          ),
        ],
        members: {
          '@whatsapp_48200:bridge.invalid': 'Mom',
          '@whatsapp_lid-555:bridge.invalid': 'Anna',
        },
      );
      final identity = resolve([
        dm('!a:example.invalid'),
        room('!attacker:example.invalid', [
          bridge('@whatsapp_48200:bridge.invalid', 'whatsapp'),
        ], sender: '@mallory:example.invalid'),
      ]);
      expect(identity.ownGhostIds, isEmpty);
    });
  });
}
