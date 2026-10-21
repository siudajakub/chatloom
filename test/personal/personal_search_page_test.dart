// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_search_page.dart';
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

  test('memo computes once per signature', () {
    final memo = PersonalSearchMemo<int>();
    var value = 0;
    expect(memo.resolve(('a', 1), () => ++value), 1);
    expect(memo.resolve(('a', 1), () => ++value), 1);
    expect(memo.computations, 1);
    expect(memo.resolve(('a', 2), () => ++value), 2);
    expect(memo.resolve(('a', 1), () => ++value), 3);
    expect(memo.computations, 3);
    memo.clear();
    expect(memo.resolve(('a', 1), () => ++value), 4);
  });

  testWidgets('typing is debounced and rebuilds reuse the results', (
    tester,
  ) async {
    final client = Client('search-debounce', database: _UnusedDatabase());
    final personal = PersonalClient.of(client);
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: _Matrix(client),
        child: MaterialApp(home: PersonalSearchPage(personal: personal)),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    final before = PersonalSearchPage.debugScans;
    // A burst of keystrokes inside the pause scans nothing.
    for (final text in ['c', 'co', 'cof', 'coff']) {
      await tester.enterText(field, text);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(PersonalSearchPage.debugScans, before);
    await tester.pump(const Duration(milliseconds: 150));
    expect(PersonalSearchPage.debugScans, before + 1);
    // Rebuilds for other reasons (focus) reuse the memoised list.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(PersonalSearchPage.debugScans, before + 1);
    // Submitting applies the text at once.
    await tester.enterText(field, 'coffee');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(PersonalSearchPage.debugScans, before + 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    personal.dispose();
  });
}
