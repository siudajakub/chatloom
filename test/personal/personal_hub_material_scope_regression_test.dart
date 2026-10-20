// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Matrix extends MatrixState {
  final Client active;
  _Matrix(this.active);
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [active], store: AppSettings.store);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets('private sync reports a failed action in the app messenger', (
    tester,
  ) async {
    // No session means connect fails locally, without touching network or keys.
    final client = Client(
      'hub-material-scope-regression',
      database: _UnusedDatabase(),
    );
    final personal = PersonalClient.of(client);
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: _Matrix(client),
        child: MaterialApp(
          home: PersonalSettingsPage(
            client: client,
            section: PersonalSettingsSection.sync,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Connect private sync'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('The operation was not confirmed. Check private sync.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    personal.dispose();
  });
}
