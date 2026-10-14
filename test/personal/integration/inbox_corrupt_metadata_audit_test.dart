// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('malformed private nickname and draft do not hide conversations', () {
    final client = Client(
      'inbox-corrupt-metadata-audit',
      database: _UnusedDatabase(),
    );
    final personal = PersonalClient.of(client);
    addTearDown(personal.dispose);
    final room = Room(id: '!fixture:example.org', client: client);
    personal.values['nickname:${room.id}'] = {'name': 42};
    personal.values['draft:${room.id}'] = {'text': <String>[]};
    final projection = InboxProjection(personal);
    expect(projection.displayName(room), room.getLocalizedDisplayname());
    expect(projection.rooms([room]), [room]);
    expect(projection.rooms([room], filter: InboxFilter.drafts), isEmpty);
    personal.values['nickname:${room.id}'] = {'name': 'My contact'};
    personal.values['draft:${room.id}'] = {'text': 'Saved draft'};
    expect(projection.displayName(room), 'My contact');
    expect(projection.rooms([room], filter: InboxFilter.drafts), [room]);
  });
}
