// SPDX-License-Identifier: AGPL-3.0-or-later
// Pack import (ST-08): links, the bridges' image pack provisioning API and
// human error messages. Fake transport, fictional packs; nothing leaves.
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/stickers/sticker_pack_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

class _Transport implements BridgeProvisioningTransport {
  final requests = <BridgeProvisioningRequest>[];
  Object? Function(BridgeProvisioningRequest request)? answer;

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) async {
    requests.add(request);
    final value = answer!(request);
    return value is Future ? await value : value;
  }
}

const _telegram = BridgeEndpoint(
  botId: '@sh-telegrambot:beeper.local',
  network: 'telegram',
  label: 'Telegram',
);

void main() {
  group('links', () {
    test('Telegram links in every form', () {
      for (final raw in [
        'https://t.me/addstickers/FictionalPack',
        't.me/addstickers/FictionalPack',
        'https://telegram.me/addstickers/FictionalPack/',
        'tg://addstickers?set=FictionalPack',
      ]) {
        final link = StickerPackLink.parse(raw);
        expect(link?.network, 'telegram', reason: raw);
        expect(
          link?.url,
          'https://t.me/addstickers/FictionalPack',
          reason: raw,
        );
        expect(link?.emoji, isFalse);
      }
      expect(
        StickerPackLink.parse('https://t.me/addemoji/FictionalSet')?.emoji,
        isTrue,
      );
    });

    test('WhatsApp packs and non-pack links', () {
      expect(
        StickerPackLink.parse('https://wa.me/stickerpack/fictional.id')?.url,
        'https://wa.me/stickerpack/fictional.id',
      );
      for (final raw in [
        'https://t.me/someone',
        'https://example.invalid/addstickers/x',
        'https://t.me/addstickers/',
        '',
        null,
      ]) {
        expect(StickerPackLink.parse(raw), isNull, reason: '$raw');
      }
    });
  });

  group('provisioning', () {
    late _Transport transport;
    late FakeStickerBackend backend;
    late StickerPackProvisioning provisioning;
    setUp(() {
      transport = _Transport();
      backend = FakeStickerBackend();
      provisioning = StickerPackProvisioning(
        ConversationClient(),
        transport: transport,
        bridges: const [_telegram],
      );
    });

    test('lists the Telegram packs, stickers before emoji', () async {
      transport.answer = (_) => [
        {
          'display_name': 'Fictional emoji',
          'usage': ['emoticon'],
          'fi.mau.bridged_pack': {
            'network': 'telegram',
            'url': 'https://t.me/addemoji/FictionalEmoji',
          },
        },
        {
          'display_name': 'Fictional pack',
          'usage': ['sticker'],
          'fi.mau.bridged_pack': {
            'network': 'telegram',
            'url': 'https://t.me/addstickers/FictionalPack',
          },
        },
        {'display_name': 'No link'},
      ];
      final packs = await provisioning.listPacks();
      expect(packs.map((p) => p.title), ['Fictional pack', 'Fictional emoji']);
      expect(packs.last.emoji, isTrue);
      expect(transport.requests.single.path, '/v3/image_pack/list');
      expect(transport.requests.single.method, 'GET');
    });

    test('previews and installs a pack into the library', () async {
      final link = StickerPackLink.parse('t.me/addstickers/FictionalPack')!;
      transport.answer = (request) => request.method == 'GET'
          ? {
              'images': {'FictionalPack_smile': packImage('a')},
              'pack': {'display_name': 'Fictional pack'},
            }
          : {
              'room_id': '!space:example.invalid',
              'state_key': 'FictionalPack',
              'state_keys': ['FictionalPack', 'FictionalPack.001'],
            };
      final preview = await provisioning.preview(link);
      expect(preview.images, hasLength(1));
      expect(transport.requests.first.query, {
        'pack_url': 'https://t.me/addstickers/FictionalPack',
      });
      final library = fakeLibrary(backend);
      addTearDown(library.dispose);
      final ref = await provisioning.install(
        link,
        preview: preview,
        library: library,
      );
      expect(transport.requests.last.method, 'POST');
      expect(ref.stateKey, 'FictionalPack');
      expect(ref.packUrl, link.url);
      // Usable at once from the cached preview (state not synced yet).
      expect(library.packs.single.title, 'Fictional pack');
      expect(library.isInstalled(link.url), isTrue);
    });

    test(
      'install is idempotent: one import for concurrent adds, none when added',
      () async {
        final link = StickerPackLink.parse('t.me/addstickers/FictionalPack')!;
        final gate = Completer<Object?>();
        transport.answer = (request) => request.method == 'POST'
            ? gate.future
            : {
                'images': {'FictionalPack_smile': packImage('a')},
                'pack': {'display_name': 'Fictional pack'},
              };
        final library = fakeLibrary(backend);
        addTearDown(library.dispose);
        final preview = await provisioning.preview(link);
        final first = provisioning.install(
          link,
          preview: preview,
          library: library,
        );
        final second = provisioning.install(
          link,
          preview: preview,
          library: library,
        );
        await pumpEventQueue();
        gate.complete({
          'room_id': '!space:example.invalid',
          'state_key': 'FictionalPack',
        });
        expect((await first).key, (await second).key);
        final again = await provisioning.install(link, library: library);
        expect(again.key, (await first).key);
        expect(
          transport.requests.where((r) => r.method == 'POST'),
          hasLength(1),
        );
        expect(library.doc.packs, hasLength(1));
      },
    );

    Future<String> failure(
      BridgeProvisioningException e, {
      bool post = false,
    }) async {
      transport.answer = (_) => throw e;
      final link = StickerPackLink.parse('t.me/addstickers/FictionalPack')!;
      try {
        post
            ? await provisioning.import(link)
            : await provisioning.preview(link);
      } on StickerImportException catch (error) {
        return error.message;
      }
      fail('no error');
    }

    test('bridge errors become sentences', () async {
      expect(
        await failure(
          const BridgeProvisioningException(501, errcode: 'M_UNRECOGNIZED'),
        ),
        'Your Telegram bridge can’t import sticker packs.',
      );
      expect(
        await failure(const BridgeProvisioningException(0)),
        contains('didn’t answer'),
      );
      expect(
        await failure(
          const BridgeProvisioningException(
            404,
            errcode: 'M_NOT_FOUND',
            message:
                'Can\'t import image pack to space when personal filtering spaces are disabled',
          ),
          post: true,
        ),
        'Your Telegram bridge has no space to keep imported packs in.',
      );
      expect(
        await failure(
          const BridgeProvisioningException(404, errcode: 'M_NOT_FOUND'),
        ),
        'This sticker pack doesn’t exist or isn’t available.',
      );
      expect(
        await failure(const BridgeProvisioningException(403)),
        'ChatLoom can’t reach your Telegram bridge right now.',
      );
      for (final message in [
        await failure(
          const BridgeProvisioningException(500, errcode: 'M_UNKNOWN'),
        ),
      ]) {
        expect(message, isNot(contains('M_')));
        expect(message, isNot(contains('500')));
      }
    });

    test('no bridge or no route', () async {
      final noBridge = StickerPackProvisioning(
        ConversationClient(),
        transport: transport,
        bridges: const [],
      );
      await expectLater(
        noBridge.listPacks(),
        throwsA(
          isA<StickerImportException>().having(
            (e) => e.message,
            'message',
            'No Telegram bridge is connected to this account.',
          ),
        ),
      );
      final unreachable = StickerPackProvisioning(
        ConversationClient(),
        transport: transport,
        bridges: const [_telegram],
        reaches: (_) => false,
      );
      await expectLater(
        unreachable.listPacks(),
        throwsA(
          isA<StickerImportException>().having(
            (e) => e.message,
            'message',
            'ChatLoom can’t reach your Telegram bridge from this account.',
          ),
        ),
      );
      expect(transport.requests, isEmpty);
    });
  });
}
