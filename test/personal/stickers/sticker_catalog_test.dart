// SPDX-License-Identifier: AGPL-3.0-or-later
// Telegram's sticker catalogue through the bridge fork (wave 11): parsing,
// feature detection, retries, caching and covers. Fake transport, fictional
// sets; nothing leaves the test.
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/stickers/sticker_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../notion/conversation_test_support.dart';
import 'catalog_test_support.dart';

TelegramStickerCatalog testCatalog(
  CatalogTransport transport, {
  List<BridgeEndpoint> bridges = const [telegramBridge],
  DateTime Function()? clock,
}) {
  final client = ConversationClient();
  return TelegramStickerCatalog(
    client,
    transport: transport,
    bridges: bridges,
    useDirectory: false,
    retryDelay: Duration.zero,
    clock: clock,
  );
}

void main() {
  test('parses sets: links, counts, flags; drops invalid and duplicates', () {
    final page = CatalogPage.fromJson({
      'sets': [
        catalogSet(1, cover: true),
        catalogSet(2, emoji: true, installed: true),
        catalogSet(1),
        {'short_name': 'NoLink', 'title': 'No link'},
        {'short_name': 'Wa', 'url': 'https://wa.me/stickerpack/fictional'},
        'junk',
      ],
      'next_offset': 20,
    });
    expect(page.sets.map((s) => s.shortName), [
      'FictionalSet1',
      'FictionalSet2',
    ]);
    final first = page.sets.first;
    expect(first.link.url, 'https://t.me/addstickers/FictionalSet1');
    expect(first.count, 11);
    expect(first.hasCover, isTrue);
    expect(page.sets.last.emoji, isTrue);
    expect(page.sets.last.link.emoji, isTrue);
    expect(page.sets.last.installedOnTelegram, isTrue);
    expect(page.nextOffset, 20);
    expect(
      CatalogPage.fromJson({'sets': [], 'next_offset': 0}).nextOffset,
      isNull,
    );
    expect(CatalogPage.fromJson(null).sets, isEmpty);
  });

  test('search and featured: POST bodies, never a query in the URL', () async {
    final transport = CatalogTransport()
      ..answer = (r) => {
        'sets': [catalogSet(1)],
        if (r.path.endsWith('featured')) 'next_offset': 21,
      };
    final catalog = testCatalog(transport);
    final results = await catalog.search('  Fictional Cats ');
    expect(results.sets, hasLength(1));
    final featured = await catalog.featured();
    expect(featured.nextOffset, 21);
    await catalog.featured(offset: 21);
    expect(transport.paths, [
      '/v3/sticker_sets/search',
      '/v3/sticker_sets/featured',
      '/v3/sticker_sets/featured',
    ]);
    expect(transport.requests.first.method, 'POST');
    expect(transport.requests.first.query, isEmpty);
    expect(transport.requests.first.body, {'query': 'Fictional Cats'});
    expect(transport.requests[2].body, {'offset': 21});
    // An empty query sends nothing.
    expect((await catalog.search('   ')).sets, isEmpty);
    expect(transport.requests, hasLength(3));
  });

  test('pages are cached for ten minutes, by normalised query', () async {
    var now = DateTime.utc(2026, 10, 27);
    final transport = CatalogTransport()
      ..answer = (_) => {
        'sets': [catalogSet(1)],
      };
    final catalog = testCatalog(transport, clock: () => now);
    await catalog.search('Fictional  cats');
    await catalog.search('fictional cats');
    expect(transport.requests, hasLength(1));
    now = now.add(TelegramStickerCatalog.cacheTtl);
    await catalog.search('fictional cats');
    expect(transport.requests, hasLength(2));
  });

  test('an old bridge is detected once and never asked again', () async {
    final transport = CatalogTransport()
      ..answer = (_) => throw const BridgeProvisioningException(
        404,
        errcode: 'M_UNRECOGNIZED',
      );
    final catalog = testCatalog(transport);
    expect(catalog.availability.usable, isTrue);
    await expectLater(
      catalog.featured(),
      throwsA(
        isA<StickerCatalogException>()
            .having((e) => e.retryable, 'retryable', isFalse)
            .having((e) => e.message, 'message', contains('bridge')),
      ),
    );
    expect(catalog.availability.status, CatalogStatus.needsBridgeUpdate);
    await expectLater(
      catalog.search('cats'),
      throwsA(isA<StickerCatalogException>()),
    );
    expect(
      transport.requests,
      hasLength(1),
      reason: 'no request after detection',
    );
    // Another catalogue of the same account knows it too.
    final again = TelegramStickerCatalog(
      catalog.client,
      transport: transport,
      bridges: const [telegramBridge],
      useDirectory: false,
    );
    expect(again.availability.status, CatalogStatus.needsBridgeUpdate);
  });

  test('no bridge: a sentence, no request', () async {
    final transport = CatalogTransport();
    final catalog = testCatalog(transport, bridges: const []);
    expect(catalog.availability.status, CatalogStatus.noBridge);
    await expectLater(
      catalog.search('cats'),
      throwsA(isA<StickerCatalogException>()),
    );
    expect(transport.requests, isEmpty);
    final noRoute = TelegramStickerCatalog(
      ConversationClient(),
      bridges: const [telegramBridge],
      useDirectory: false,
    );
    expect(noRoute.availability.status, CatalogStatus.unreachable);
  });

  test('one quiet retry when the bridge did not answer', () async {
    var calls = 0;
    final transport = CatalogTransport()
      ..answer = (_) {
        calls++;
        if (calls == 1) throw const BridgeProvisioningException(0);
        return {
          'sets': [catalogSet(1)],
        };
      };
    final catalog = testCatalog(transport);
    expect((await catalog.search('cats')).sets, hasLength(1));
    expect(calls, 2);
  });

  test('errors become sentences, never codes', () async {
    Future<String> failure(BridgeProvisioningException e) async {
      final transport = CatalogTransport()..answer = (_) => throw e;
      try {
        await testCatalog(transport).search('cats');
      } on StickerCatalogException catch (error) {
        return error.message;
      }
      fail('no error');
    }

    expect(
      await failure(const BridgeProvisioningException(0)),
      contains('offline'),
    );
    expect(
      await failure(
        const BridgeProvisioningException(429, errcode: 'M_LIMIT_EXCEEDED'),
      ),
      contains('slow down'),
    );
    expect(
      await failure(
        const BridgeProvisioningException(400, errcode: 'FI.MAU.NOT_LOGGED_IN'),
      ),
      contains('Sign in to Telegram'),
    );
    for (final e in [
      const BridgeProvisioningException(
        500,
        errcode: 'M_UNKNOWN',
        message: 'secret',
      ),
      const BridgeProvisioningException(502),
    ]) {
      final message = await failure(e);
      expect(message, isNot(contains('M_')));
      expect(message, isNot(contains('secret')));
      expect(message, isNot(contains('50')));
    }
  });

  test('covers: only sets that have one, cached, a few at a time', () async {
    final gates = <Completer<Object?>>[];
    final transport = CatalogTransport()
      ..answer = (r) {
        final gate = Completer<Object?>();
        gates.add(gate);
        return gate.future;
      };
    final catalog = testCatalog(transport);
    final page = CatalogPage.fromJson({
      'sets': [
        for (var i = 0; i < 5; i++) catalogSet(i, cover: true),
        catalogSet(9),
      ],
    });
    expect(await catalog.cover(page.sets.last), isNull, reason: 'no cover');
    final covers = [for (final set in page.sets.take(5)) catalog.cover(set)];
    await pumpEventQueue();
    expect(transport.requests, hasLength(TelegramStickerCatalog.coverSlots));
    expect(transport.requests.first.body, {'short_name': 'FictionalSet0'});
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
      gates[i].complete({'url': 'mxc://example.invalid/cover$i'});
    }
    final uris = await Future.wait(covers);
    expect(uris.first.toString(), 'mxc://example.invalid/cover0');
    expect(transport.requests, hasLength(5));
    // Cached: no new request.
    await catalog.cover(page.sets.first);
    expect(transport.requests, hasLength(5));
  });

  test('a failed cover is asked for again next time', () async {
    var fail = true;
    final transport = CatalogTransport()
      ..answer = (_) {
        if (fail) {
          throw const BridgeProvisioningException(404, errcode: 'M_NOT_FOUND');
        }
        return {'url': 'mxc://example.invalid/cover'};
      };
    final catalog = testCatalog(transport);
    final set = CatalogPage.fromJson({
      'sets': [catalogSet(1, cover: true)],
    }).sets.single;
    await expectLater(
      catalog.cover(set),
      throwsA(isA<StickerCatalogException>()),
    );
    fail = false;
    expect(
      (await catalog.cover(set)).toString(),
      'mxc://example.invalid/cover',
    );
  });
}
