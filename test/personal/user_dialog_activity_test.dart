// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

void main() {
  testWidgets('contact profile stays usable without activity data', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = ConversationClient();
    // A bridge whose presence must be hidden still has an ordinary profile.
    ConversationRoom(client, '!profile:example.invalid');
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(
          client,
          await SharedPreferences.getInstance(),
        ),
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: UserDialog(
              Profile(
                userId: '@anna:example.invalid',
                displayName: 'Fictional contact',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fictional contact'), findsOneWidget);
    final l10n = L10n.of(tester.element(find.byType(UserDialog)));
    // The Matrix ignore list is labelled as what it is (FX-01).
    expect(find.text('Ignore'), findsOneWidget);
    expect(find.text(l10n.block), findsNothing);
    expect(find.text(l10n.report), findsOneWidget);
    expect(find.text('Currently active'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
