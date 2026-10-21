// SPDX-License-Identifier: AGPL-3.0-or-later
// The unverified-devices prompt before a send must not turn a failed member
// list refresh into a silently dropped send (wave 4 integration).
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Client extends Fake implements Client {
  @override
  String get userID => '@fixture:example.invalid';
  @override
  Map<String, DeviceKeysList> get userDeviceKeys => const {};
}

class _Room extends Fake implements Room {
  _Room(this.client);
  @override
  final Client client;
  @override
  bool get encrypted => true;
  int known = 0;

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
  ]) async => throw MatrixException.fromJson({
    'errcode': 'M_UNKNOWN',
    'error': 'M_UNKNOWN',
  });

  @override
  List<User> getParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock,
    ],
  ]) {
    known++;
    return [];
  }
}

void main() {
  testWidgets('a failed member refresh falls back to the known members', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Chat'))),
    );
    final room = _Room(_Client());
    final proceed = await showTrustUserInRoomDialog(
      tester.element(find.text('Chat')),
      room,
    );
    expect(proceed, isTrue);
    expect(room.known, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
