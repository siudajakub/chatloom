// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/widgets/presence_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  _Client(String name) : super(name, database: _Database());
  final requests = <(String, bool, Completer<CachedPresence>)>[];

  @override
  Future<CachedPresence> fetchCurrentPresence(
    String userId, {
    bool fetchOnlyFromCached = false,
  }) {
    final result = Completer<CachedPresence>();
    requests.add((userId, fetchOnlyFromCached, result));
    return result.future;
  }
}

CachedPresence _presence(String id, PresenceType type) =>
    CachedPresence(type, null, null, null, id);

Widget _host(Client client, String userId) => MaterialApp(
  home: PresenceBuilder(
    client: client,
    userId: userId,
    builder: (_, presence) => Text(
      presence == null
          ? 'unknown'
          : '${presence.userid}:${presence.presence.name}',
    ),
  ),
);

void main() {
  testWidgets('cache-only lookup cannot overwrite live presence', (
    tester,
  ) async {
    final client = _Client('presence-cache');
    await tester.pumpWidget(_host(client, '@peer:example.invalid'));
    expect(client.requests.single.$2, isTrue);
    client.onPresenceChanged.add(
      _presence('@peer:example.invalid', PresenceType.online),
    );
    await tester.pump();
    client.requests.single.$3.complete(
      _presence('@peer:example.invalid', PresenceType.offline),
    );
    await tester.pump();
    expect(find.text('@peer:example.invalid:online'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('same widget rebinds account and ignores late old result', (
    tester,
  ) async {
    final first = _Client('presence-first');
    final second = _Client('presence-second');
    const peer = '@peer:example.invalid';
    await tester.pumpWidget(_host(first, peer));
    await tester.pumpWidget(_host(second, peer));
    second.requests.single.$3.complete(
      _presence(peer, PresenceType.unavailable),
    );
    await tester.pump();
    first.requests.single.$3.complete(_presence(peer, PresenceType.online));
    first.onPresenceChanged.add(_presence(peer, PresenceType.online));
    await tester.pump();
    expect(find.text('$peer:unavailable'), findsOneWidget);
    await tester.pumpWidget(_host(second, '@next:example.invalid'));
    expect(find.text('unknown'), findsOneWidget);
    expect(second.requests.length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    second.requests.last.$3.complete(
      _presence('@next:example.invalid', PresenceType.online),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed cache lookup preserves unknown without error', (
    tester,
  ) async {
    final client = _Client('presence-error');
    await tester.pumpWidget(_host(client, '@peer:example.invalid'));
    client.requests.single.$3.completeError(StateError('cache unavailable'));
    await tester.pump();
    expect(find.text('unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
