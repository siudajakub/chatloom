// SPDX-License-Identifier: AGPL-3.0-or-later
// The timeline footer must not reload participants and re-check device
// signatures on every list rebuild, and never shows in bridged chats.
// Fictional offline fixtures only.
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/encryption_info.dart';
import 'package:chatloom/personal/bridged_room.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

class _EncryptedRoom extends ConversationRoom {
  int requests = 0;

  /// A native Matrix room unless [bridged] (the fixture is a bridge portal).
  _EncryptedRoom(super.client, super.id, {bool bridged = false}) {
    if (!bridged) states.remove('m.bridge');
  }
  @override
  bool get encrypted => true;
  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock,
    ],
    bool suppressWarning = false,
    bool? cache,
    bool enforceFetchFromServer = false,
  ]) async {
    requests++;
    return const [];
  }
}

Widget _app(Room room, void Function(StateSetter) onSetState) => MaterialApp(
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: StatefulBuilder(
    builder: (context, setState) {
      onSetState(setState);
      return EncryptionInfo(room: room);
    },
  ),
);

void main() {
  testWidgets('participants are loaded once, not per rebuild', (tester) async {
    final room = _EncryptedRoom(ConversationClient(), '!e2ee:example.invalid');
    expect(isBridgedRoom(room), isFalse);
    late StateSetter rebuild;
    await tester.pumpWidget(_app(room, (setState) => rebuild = setState));
    await tester.pumpAndSettle();
    expect(room.requests, 1);
    for (var i = 0; i < 10; i++) {
      rebuild(() {});
      await tester.pump();
    }
    expect(room.requests, 1);
    // A device-list change from sync refreshes it on the next rebuild.
    room.client.onSync.add(
      SyncUpdate(
        nextBatch: 'fixture',
        deviceLists: DeviceListsUpdate(changed: ['@anna:example.invalid']),
      ),
    );
    await tester.pump();
    rebuild(() {});
    await tester.pump();
    expect(room.requests, 2);
  });

  testWidgets(
    'bridged chats never load participants or show the unverified banner',
    (tester) async {
      final client = ConversationClient();
      final room = _EncryptedRoom(
        client,
        '!bridged:example.invalid',
        bridged: true,
      );
      expect(isBridgedRoom(room), isTrue);
      late StateSetter rebuild;
      await tester.pumpWidget(_app(room, (setState) => rebuild = setState));
      await tester.pumpAndSettle();
      // Device-list changes and rebuilds keep it hidden and free.
      client.onSync.add(
        SyncUpdate(
          nextBatch: 'fixture',
          deviceLists: DeviceListsUpdate(changed: ['@anna:example.invalid']),
        ),
      );
      await tester.pump();
      rebuild(() {});
      await tester.pumpAndSettle();
      expect(room.requests, 0);
      expect(find.textContaining('unverified'), findsNothing);
      expect(find.text('Check'), findsNothing);
      expect(find.byType(AnimatedSize), findsNothing);
    },
  );

  test('bridge info of any known type marks a portal; empty content does not', () {
    final client = ConversationClient();
    final room = _EncryptedRoom(client, '!native:example.invalid');
    expect(isBridgedRoom(room), isFalse);
    room.state('uk.half-shot.bridge', {}, key: 'cleared');
    expect(isBridgedRoom(room), isFalse);
    room.state('com.beeper.bridge', {
      'bridgebot': '@bot:example.invalid',
    }, key: 'portal');
    expect(isBridgedRoom(room), isTrue);
  });
}
