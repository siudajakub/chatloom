// SPDX-License-Identifier: AGPL-3.0-or-later
// The decrypted private avatar cache is bounded by bytes as well as entries
// (64 × 2 MB used to allow 128 MB) and empties on a memory trim.
// Synthetic bytes only.
import 'dart:typed_data';

import 'package:chatloom/personal/memory_trim.dart';
import 'package:chatloom/personal/private_avatar.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int length) => Uint8List(length);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    MemoryTrim.debugReset();
    debugResetPrivateAvatarCache();
  });
  tearDown(() {
    MemoryTrim.debugReset();
    debugResetPrivateAvatarCache();
  });

  test('evicts least recently used avatars past the byte budget', () {
    const mb = 1024 * 1024;
    for (var i = 0; i < 4; i++) {
      debugRememberPrivateAvatar('h$i', _bytes(2 * mb));
    }
    expect(debugPrivateAvatarCache, (entries: 4, bytes: 8 * mb));
    // A read refreshes h0, so h1 is the oldest.
    expect(cachedPrivateAvatar({'sha256': 'h0'}), isNotNull);
    debugRememberPrivateAvatar('h4', _bytes(2 * mb));
    expect(debugPrivateAvatarCache, (entries: 4, bytes: 8 * mb));
    expect(cachedPrivateAvatar({'sha256': 'h1'}), isNull);
    expect(cachedPrivateAvatar({'sha256': 'h0'}), isNotNull);
    // Replacing an entry does not count its old bytes twice.
    debugRememberPrivateAvatar('h4', _bytes(mb));
    expect(debugPrivateAvatarCache.bytes, 7 * mb);
    // Bigger than the whole budget: never kept, nothing else dropped.
    debugRememberPrivateAvatar('huge', _bytes(privateAvatarCacheBytes + 1));
    expect(cachedPrivateAvatar({'sha256': 'huge'}), isNull);
    expect(debugPrivateAvatarCache.entries, 4);
  });

  test('keeps at most 64 small avatars', () {
    for (var i = 0; i < 70; i++) {
      debugRememberPrivateAvatar('s$i', _bytes(100));
    }
    expect(debugPrivateAvatarCache, (entries: 64, bytes: 6400));
    expect(cachedPrivateAvatar({'sha256': 's5'}), isNull);
    expect(cachedPrivateAvatar({'sha256': 's6'}), isNotNull);
  });

  test('a background trim keeps it; memory pressure empties it', () {
    debugRememberPrivateAvatar('a', _bytes(10));
    MemoryTrim.trim(background: true);
    expect(cachedPrivateAvatar({'sha256': 'a'}), isNotNull);
    MemoryTrim.trim();
    expect(debugPrivateAvatarCache, (entries: 0, bytes: 0));
    expect(cachedPrivateAvatar({'sha256': 'a'}), isNull);
  });
}
