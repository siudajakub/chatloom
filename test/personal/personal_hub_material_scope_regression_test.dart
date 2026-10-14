// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/personal_hub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets('PersonalHub reports a failed action in the app messenger', (
    tester,
  ) async {
    // No session means connect fails locally, without touching network or keys.
    final client = Client(
      'hub-material-scope-regression',
      database: _UnusedDatabase(),
    );
    final personal = PersonalClient.of(client);
    await tester.pumpWidget(MaterialApp(home: PersonalHub(client: client)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Połącz prywatną synchronizację'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text(
        'Operacja nie została potwierdzona. Sprawdź prywatną synchronizację.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    personal.dispose();
  });
}
