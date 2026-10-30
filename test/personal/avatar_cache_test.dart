// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/media/avatar_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('avatar sizes share a few physical buckets', () {
    expect(AvatarCache.bucketFor(null), 96);
    expect(AvatarCache.bucketFor(42 * 2.625), 256);
    expect(AvatarCache.bucketFor(24 * 3), 96);
    expect(AvatarCache.bucketFor(120 * 3), 640);
    expect(AvatarCache.bucketFor(5000), 640);
  });
}
