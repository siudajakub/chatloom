// SPDX-License-Identifier: AGPL-3.0-or-later
// A forced profile refresh never joins an older in-flight request.
// Fictional offline fixtures only.
import 'dart:async';

import 'package:chatloom/pages/settings/settings_account_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Account extends Client {
  _Account() : super('fictional profile cache', database: _NoDatabase());
  final answers = <Completer<Profile>>[];
  @override
  String? get userID => '@cache-fixture:example.invalid';
  @override
  Future<Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) {
    final answer = Completer<Profile>();
    answers.add(answer);
    return answer.future;
  }
}

Profile _profile(String name) =>
    Profile(userId: '@cache-fixture:example.invalid', displayName: name);

void main() {
  test('forced profile load supersedes an in-flight ordinary load', () async {
    final client = _Account();
    final cache = SettingsAccountCache.of(client);
    final ordinary = cache.loadProfile();
    // A second ordinary caller shares the request.
    expect(identical(cache.loadProfile(), ordinary), isTrue);
    final forced = cache.loadProfile(force: true);
    expect(client.answers, hasLength(2));

    // The forced (post-edit) answer lands first, then the stale one.
    client.answers[1].complete(_profile('After edit'));
    expect((await forced).displayName, 'After edit');
    client.answers[0].complete(_profile('Before edit'));
    expect((await ordinary).displayName, 'After edit');
    expect(cache.profile?.displayName, 'After edit');
    expect(cache.profileFresh, isTrue);
    // Fresh now: no request.
    expect((await cache.loadProfile()).displayName, 'After edit');
    expect(client.answers, hasLength(2));
  });

  test('stale answer arriving first never overwrites the forced one', () async {
    final client = _Account();
    final cache = SettingsAccountCache.of(client);
    final ordinary = cache.loadProfile();
    final forced = cache.loadProfile(force: true);
    client.answers[0].complete(_profile('Before edit'));
    await Future<void>.delayed(Duration.zero);
    expect(cache.profile, isNull);
    // The finished stale request did not drop the newer pending one.
    expect(identical(cache.loadProfile(), forced), isTrue);
    // Ordinary callers wait for the newer request instead.
    client.answers[1].complete(_profile('After edit'));
    expect((await ordinary).displayName, 'After edit');
    expect((await forced).displayName, 'After edit');
    expect(cache.profile?.displayName, 'After edit');
    expect(client.answers, hasLength(2));
  });
}
