// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 12: adding a Telegram pack when the bridge can't keep it in its
// personal filtering space. The space import stays the first choice; on a
// space failure the preview is saved in the account (chunked account data)
// and shows, searches, reorders and removes like every pack. Fake transport,
// fictional packs; nothing leaves.
import 'dart:convert';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/stickers/sticker_account_packs.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_pack_import.dart';
import 'package:chatloom/personal/stickers/sticker_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'catalog_test_support.dart';
import 'sticker_test_support.dart';

const _url = 'https://t.me/addstickers/FictionalPack';
final _link = StickerPackLink.parse(_url)!;

const _noSpace = BridgeProvisioningException(
  404,
  errcode: 'M_NOT_FOUND',
  message:
      'Can\'t import image pack to space when personal filtering spaces are disabled',
);

Map<String, Object?> _preview({
  int count = 3,
  String title = 'Fictional pack',
}) => pack(title, {
  for (var i = 0; i < count; i++)
    'FictionalPack_s$i': packImage('s$i', emoji: '😀'),
}, url: _url).toJson();

/// A large Telegram-like pack: long shortcodes and full bridge tags.
ImagePackContent _bigPack(int count) => ImagePackContent.fromJson({
  'pack': {
    'display_name': 'Fictional big pack',
    'usage': ['sticker'],
    'fi.mau.bridged_pack': {'network': 'telegram', 'url': _url},
  },
  'images': {
    for (var i = 0; i < count; i++)
      'FictionalPack_grinning_face_with_big_eyes_$i': {
        'url': 'mxc://example.invalid/${'m' * 40}$i',
        'body': '😃',
        'info': {
          'mimetype': 'image/webp',
          'w': 512,
          'h': 512,
          'size': 30000 + i,
          'xyz.amorgan.blurhash': 'L' * 30,
          'fi.mau.bridged_sticker': {
            'network': 'telegram',
            'id': '${5000000000000000000 + i}',
            'emoji': '😃',
            'pack_url': _url,
          },
        },
      },
  },
});

void main() {
  late CatalogTransport transport;
  late FakeStickerBackend backend;
  late StickerLibrary library;
  late StickerPackProvisioning provisioning;

  setUp(() {
    transport = CatalogTransport();
    backend = FakeStickerBackend();
    library = fakeLibrary(backend);
    provisioning = StickerPackProvisioning(
      ConversationClient(),
      transport: transport,
      bridges: const [telegramBridge],
    );
  });
  tearDown(() => library.dispose());

  Iterable<String> accountTypes() =>
      backend.synced.keys.where((t) => t.startsWith(accountPackTypePrefix));

  test('the space import stays the first choice when it works', () async {
    transport.answer = (r) => r.method == 'POST'
        ? {'room_id': '!space:example.invalid', 'state_key': 'FictionalPack'}
        : _preview();
    final ref = await provisioning.install(_link, library: library);
    expect(ref.roomId, '!space:example.invalid');
    expect(ref.accountPack, isNull);
    expect(accountTypes(), isEmpty, reason: 'nothing saved in the account');
    expect(library.packs.single.title, 'Fictional pack');
  });

  for (final (name, failure) in [
    ('personal filtering spaces disabled', _noSpace),
    (
      'the bot can’t write to the space',
      const BridgeProvisioningException(500, errcode: 'M_UNKNOWN'),
    ),
    (
      'a bridge without the import route',
      const BridgeProvisioningException(404, errcode: 'M_UNRECOGNIZED'),
    ),
  ]) {
    test('$name: the preview is saved in the account and shows', () async {
      transport.answer = (r) {
        if (r.method == 'POST') throw failure;
        if (failure.unsupported) {
          // Old bridges answer both routes the same way.
          throw failure;
        }
        return _preview();
      };
      if (failure.unsupported) {
        await expectLater(
          provisioning.install(_link, library: library),
          throwsA(
            isA<StickerImportException>().having(
              (e) => e.message,
              'message',
              'Your Telegram bridge can’t import sticker packs.',
            ),
          ),
        );
        expect(accountTypes(), isEmpty);
        return;
      }
      final ref = await provisioning.install(_link, library: library);
      expect(ref.accountPack, 'telegram.fictionalpack');
      expect(ref.packUrl, _url);
      expect(transport.requests.map((r) => r.method), [
        'POST',
        'GET',
      ], reason: 'space first, then the preview');
      expect(accountTypes(), [accountPackType('telegram.fictionalpack', 0)]);
      final shown = library.packs.single;
      expect(shown.title, 'Fictional pack');
      expect(shown.stickers, hasLength(3));
      expect(shown.source, StickerPackSource.installed);
      expect(library.isInstalled(_url), isTrue);
      expect(library.search('Fictional pack'), isNotEmpty);
      // Stored in the synced list too, so other devices show it.
      await library.flush();
      final synced = backend.synced[stickerLibraryType]!['packs'] as List;
      expect((synced.single as Map)['account_pack'], 'telegram.fictionalpack');
      // Native sending keeps working: the bridge tag survives, decoration
      // (blurhash) does not reach the account data.
      final item = shown.stickers.first;
      expect(item.bridged?.packUrl, _url);
      expect(item.info.containsKey('xyz.amorgan.blurhash'), isFalse);
    });
  }

  test('another device sees the saved pack from account data alone', () async {
    transport.answer = (r) => r.method == 'POST' ? throw _noSpace : _preview();
    await provisioning.install(_link, library: library);
    final other = fakeLibrary(backend);
    addTearDown(other.dispose);
    expect(other.packs.single.title, 'Fictional pack');
    expect(other.packs.single.ref?.accountPack, 'telegram.fictionalpack');
  });

  test(
    'a preview loaded by the sheet is saved without another request',
    () async {
      transport.answer = (r) =>
          r.method == 'POST' ? throw _noSpace : _preview();
      final preview = await provisioning.preview(_link);
      transport.requests.clear();
      await provisioning.install(_link, preview: preview, library: library);
      expect(transport.requests.map((r) => r.method), ['POST']);
      expect(library.packs.single.stickers, hasLength(3));
    },
  );

  test('a pack that doesn’t exist is not saved', () async {
    transport.answer = (_) => throw const BridgeProvisioningException(
      404,
      errcode: 'M_NOT_FOUND',
      message: 'Sticker set not found',
    );
    await expectLater(
      provisioning.install(_link, library: library),
      throwsA(
        isA<StickerImportException>().having(
          (e) => e.message,
          'message',
          'This sticker pack doesn’t exist or isn’t available.',
        ),
      ),
    );
    expect(transport.requests, hasLength(1), reason: 'no preview tried');
    expect(accountTypes(), isEmpty);
    expect(library.packs, isEmpty);
  });

  test('the preview gets one more try when the bridge was slow', () async {
    var previews = 0;
    transport.answer = (r) {
      if (r.method == 'POST') throw const BridgeProvisioningException(0);
      if (++previews == 1) throw const BridgeProvisioningException(0);
      return _preview();
    };
    final ref = await provisioning.install(_link, library: library);
    expect(ref.accountPack, isNotNull);
    expect(previews, 2);
  });

  test('a failed account write reads as a sentence; nothing installed', () async {
    transport.answer = (r) => r.method == 'POST' ? throw _noSpace : _preview();
    backend.failWrites = Exception('offline');
    await expectLater(
      provisioning.install(_link, library: library),
      throwsA(
        isA<StickerImportException>().having(
          (e) => e.message,
          'message',
          'The sticker pack couldn’t be saved. Check your connection and try again.',
        ),
      ),
    );
    expect(library.doc.packs, isEmpty);
  });

  group('chunking', () {
    test('a big pack is split under the event budget and read back whole', () {
      final content = _bigPack(240);
      final parts = encodeAccountPack(
        content,
        packUrl: _url,
        network: 'telegram',
        rev: 7,
      );
      expect(parts.length, greaterThan(1));
      expect(parts.length, lessThanOrEqualTo(accountPackMaxParts));
      for (final part in parts) {
        expect(
          utf8.encode(jsonEncode(part)).length,
          lessThanOrEqualTo(accountPackPartBudget),
        );
        expect(part['rev'], 7);
      }
      expect(parts.first['parts'], parts.length);
      final stored = {
        for (var i = 0; i < parts.length; i++)
          accountPackType('telegram.fictionalpack', i): parts[i],
      };
      final saved = decodeAccountPack(
        'telegram.fictionalpack',
        (t) => stored[t],
      )!;
      expect(saved.content.images, hasLength(240));
      expect(saved.content.pack.displayName, 'Fictional big pack');

      // A part of another revision (not synced yet) is left out, not mixed.
      stored[accountPackType('telegram.fictionalpack', 1)] = {
        ...parts[1],
        'rev': 6,
      };
      final partial = decodeAccountPack(
        'telegram.fictionalpack',
        (t) => stored[t],
      )!;
      expect(partial.content.images.length, lessThan(240));
    });

    test('a big pack installs, shows every sticker and syncs', () async {
      final content = _bigPack(200);
      transport.answer = (r) =>
          r.method == 'POST' ? throw _noSpace : content.toJson();
      await provisioning.install(_link, library: library);
      expect(accountTypes().length, greaterThan(1));
      expect(library.packs.single.stickers, hasLength(200));
      final other = fakeLibrary(backend);
      addTearDown(other.dispose);
      expect(other.packs.single.stickers, hasLength(200));
    });

    test('a pack too large for the account says so', () async {
      transport.answer = (r) =>
          r.method == 'POST' ? throw _noSpace : _bigPack(2000).toJson();
      await expectLater(
        provisioning.install(_link, library: library),
        throwsA(
          isA<StickerImportException>().having(
            (e) => e.message,
            'message',
            'This sticker pack is too large to keep in your account.',
          ),
        ),
      );
      expect(accountTypes(), isEmpty);
    });
  });

  test('remove clears the account data; Undo puts it back', () async {
    transport.answer = (r) =>
        r.method == 'POST' ? throw _noSpace : _bigPack(150).toJson();
    await provisioning.install(_link, library: library);
    final types = accountTypes().toList();
    expect(types.length, greaterThan(1));
    final pack = library.packs.single;
    library.removePack(pack);
    expect(library.packs, isEmpty);
    await library.flush();
    await pumpEventQueue();
    for (final type in types) {
      expect(backend.synced[type], isEmpty, reason: type);
    }
    expect(library.isInstalled(_url), isFalse);
    final other = fakeLibrary(backend);
    addTearDown(other.dispose);
    expect(other.packs, isEmpty, reason: 'gone on other devices too');

    library.restorePack(pack, index: 0);
    await library.flush();
    await pumpEventQueue();
    expect(library.packs.single.stickers, hasLength(150));
    final again = fakeLibrary(backend);
    addTearDown(again.dispose);
    expect(again.packs.single.stickers, hasLength(150));
  });

  test('re-adding is idempotent, on this device and another', () async {
    transport.answer = (r) => r.method == 'POST' ? throw _noSpace : _preview();
    final first = await provisioning.install(_link, library: library);
    final requests = transport.requests.length;
    final second = await provisioning.install(_link, library: library);
    expect(second.key, first.key);
    expect(transport.requests, hasLength(requests), reason: 'no new request');

    // Another device adds the same pack: same events, one entry.
    final other = fakeLibrary(backend);
    addTearDown(other.dispose);
    await other.saveAccountPack(
      ImagePackContent.fromJson(_preview()),
      packUrl: _url,
      network: 'telegram',
      name: 'FictionalPack',
    );
    await other.flush();
    expect(accountTypes(), hasLength(1));
    expect(other.doc.packs, hasLength(1));
    expect(library.packs, hasLength(1));
  });

  test('saved packs reorder with the others', () async {
    backend.rooms['!space:example.invalid'] = {
      'Other': pack('Fictional room pack', {'o': packImage('o')}),
    };
    library.addPack(
      const StickerPackRef(roomId: '!space:example.invalid', stateKey: 'Other'),
    );
    transport.answer = (r) => r.method == 'POST' ? throw _noSpace : _preview();
    await provisioning.install(_link, library: library);
    expect(library.packs.map((p) => p.title), [
      'Fictional pack',
      'Fictional room pack',
    ]);
    library.reorderPacks([for (final p in library.packs.reversed) p.key]);
    expect(library.packs.map((p) => p.title), [
      'Fictional room pack',
      'Fictional pack',
    ]);
  });

  test(
    'a removal that could not empty the parts (offline) stays removed',
    () async {
      transport.answer = (r) =>
          r.method == 'POST' ? throw _noSpace : _preview();
      await provisioning.install(_link, library: library);
      await library.flush();
      backend.failWrites = Exception('offline');
      library.removePack(library.packs.single);
      await pumpEventQueue();
      backend.failWrites = null;
      await library.flush();
      expect(
        backend.synced[accountPackType('telegram.fictionalpack', 0)],
        isNotEmpty,
        reason: 'the parts could not be emptied',
      );
      // After a restart (no session memory) the pack stays removed.
      final restarted = fakeLibrary(backend);
      addTearDown(restarted.dispose);
      expect(restarted.packs, isEmpty);
      // Adding it again shows it again.
      await restarted.saveAccountPack(
        ImagePackContent.fromJson(_preview()),
        packUrl: _url,
        network: 'telegram',
        name: 'FictionalPack',
      );
      expect(restarted.packs, hasLength(1));
    },
  );

  test('a saved pack the list doesn’t name (older app) still shows', () {
    final parts = encodeAccountPack(
      ImagePackContent.fromJson(_preview()),
      packUrl: _url,
      network: 'telegram',
      rev: 1,
    );
    backend.synced[accountPackType('telegram.fictionalpack', 0)] = parts.first;
    backend.synced[stickerLibraryType] = {'packs': <Object?>[]};
    final pack = library.packs.single;
    expect(pack.title, 'Fictional pack');
    expect(pack.ref?.accountPack, 'telegram.fictionalpack');
    expect(library.isInstalled(_url), isTrue);
  });

  test('a ref of a pack saved in the account round-trips', () {
    const ref = StickerPackRef.account(
      'telegram.fictionalpack',
      packUrl: _url,
      network: 'telegram',
      title: 'Fictional pack',
      addedTs: 5,
    );
    final back = StickerPackRef.fromJson(ref.toJson())!;
    expect(back.key, 'account|telegram.fictionalpack');
    expect(back.accountPack, 'telegram.fictionalpack');
    expect(back.packUrl, _url);
    expect(ref.toJson().containsKey('room_id'), isFalse);
    expect(StickerPackRef.fromJson({'account_pack': '../x'}), isNull);
  });
}
