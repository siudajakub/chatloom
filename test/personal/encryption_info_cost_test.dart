// SPDX-License-Identifier: AGPL-3.0-or-later
// The timeline footer must not reload participants and re-check device
// signatures on every list rebuild. Fictional offline fixtures only.
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/encryption_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

class _EncryptedRoom extends ConversationRoom {
  int requests = 0;
  _EncryptedRoom(super.client, super.id);
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

void main() {
  testWidgets('participants are loaded once, not per rebuild', (tester) async {
    final room = _EncryptedRoom(ConversationClient(), '!e2ee:example.invalid');
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return EncryptionInfo(room: room);
          },
        ),
      ),
    );
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
}
