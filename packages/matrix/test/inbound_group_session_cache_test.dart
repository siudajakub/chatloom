// SPDX-FileCopyrightText: 2026 Personal Chat contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/encryption/utils/inbound_group_session_cache.dart';
import 'package:test/test.dart';

/// ChatLoom: the key manager's inbound group sessions are a bounded LRU that
/// never drops a held session and remembers what it evicted.
void main() {
  late int max;
  late InboundGroupSessionCache<String> cache;

  setUp(() {
    max = 10;
    cache = InboundGroupSessionCache<String>(maxSessions: () => max);
  });

  test('stays within the bound and keeps the most recent sessions', () {
    for (var i = 0; i < 1000; i++) {
      cache.put('!room${i % 7}', 's$i', 'v$i');
    }
    expect(cache.length, lessThanOrEqualTo(max + max ~/ 10));
    expect(cache.get('!room${999 % 7}', 's999'), 'v999');
    expect(cache.contains('!room0', 's0'), isFalse);
    // Recent evictions are remembered; the oldest are forgotten (treated like
    // sessions not loaded since the app started), so that memory is bounded.
    expect(cache.wasEvicted('!room${900 % 7}', 's900'), isTrue);
    expect(cache.wasEvicted('!room0', 's0'), isFalse);
    expect(
      cache.evictedLength,
      lessThanOrEqualTo(max * InboundGroupSessionCache.evictedMemoryFactor),
    );
  });

  test('a read keeps a session from being evicted next', () {
    for (var i = 0; i < max; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    // s0 is the oldest insert, but in use.
    expect(cache.get('!r', 's0'), 'v0');
    for (var i = max; i < max + max ~/ 10 + 1; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    expect(cache.contains('!r', 's0'), isTrue);
    expect(cache.contains('!r', 's1'), isFalse);
    expect(cache.wasEvicted('!r', 's1'), isTrue);
  });

  test('a held session is never evicted until released', () {
    cache.put('!r', 'held', 'v');
    final release = cache.hold('!r', 'held');
    // A second holder of the same session (nested use).
    final releaseAgain = cache.hold('!r', 'held');
    for (var i = 0; i < 100; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    expect(cache.contains('!r', 'held'), isTrue);

    release();
    release(); // idempotent: must not drop the other hold
    for (var i = 100; i < 200; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    expect(cache.contains('!r', 'held'), isTrue);

    releaseAgain();
    for (var i = 200; i < 300; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    expect(cache.contains('!r', 'held'), isFalse);
    expect(cache.wasEvicted('!r', 'held'), isTrue);
  });

  test('a hold taken before the session is loaded protects it', () {
    final release = cache.hold('!r', 'loading');
    cache.put('!r', 'loading', 'v');
    for (var i = 0; i < 100; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    expect(cache.get('!r', 'loading'), 'v');
    release();
  });

  test('storing or loading an evicted session forgets the eviction', () {
    for (var i = 0; i < 100; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    expect(cache.wasEvicted('!r', 's0'), isTrue);
    cache.put('!r', 's0', 'reloaded');
    expect(cache.wasEvicted('!r', 's0'), isFalse);
    expect(cache.get('!r', 's0'), 'reloaded');
  });

  test('sessions are keyed by room and session id', () {
    cache.put('!a', 's', 'a');
    cache.put('!b', 's', 'b');
    expect(cache.get('!a', 's'), 'a');
    expect(cache.get('!b', 's'), 'b');
    expect(cache.get('!c', 's'), isNull);
  });

  test('clear drops sessions and the evicted-id memory', () {
    for (var i = 0; i < 100; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    cache.clear();
    expect(cache.length, 0);
    expect(cache.evictedLength, 0);
    expect(cache.wasEvicted('!r', 's0'), isFalse);
  });

  test('a bound of zero keeps everything (upstream behavior)', () {
    max = 0;
    for (var i = 0; i < 500; i++) {
      cache.put('!r', 's$i', 'v$i');
    }
    expect(cache.length, 500);
    expect(cache.evictedLength, 0);
  });
}
