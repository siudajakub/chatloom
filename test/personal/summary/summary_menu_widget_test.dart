// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/personal/summary/ui/conversation_summary_sheet.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../notion/conversation_test_support.dart';

class _Room extends ConversationRoom {
  final bool direct;
  _Room(super.client, super.id, {required this.direct});
  @override
  bool get isDirectChatForDisplay => direct;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  Future<PersonalClient> mount(
    WidgetTester tester, {
    required bool direct,
  }) async {
    final client = ConversationClient();
    final room = _Room(client, '!fictional:example.invalid', direct: direct);
    final composer = TextEditingController(text: 'Unsent draft');
    addTearDown(composer.dispose);
    final personal = PersonalClient.of(client);
    final matrix = ConversationMatrix(
      client,
      await SharedPreferences.getInstance(),
    );
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: matrix,
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          builder: (context, child) =>
              AppLockWidget(isLoggedIn: true, child: child!),
          home: Scaffold(
            appBar: AppBar(
              actions: [
                RoomPersonalButton(
                  room: room,
                  composer: composer,
                  readCutoff: () => null,
                  includeChatSettings: true,
                  isCurrentSource: () => true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Conversation options'));
    await tester.pumpAndSettle();
    return personal;
  }

  testWidgets('group overflow opens options without creating a summary job', (
    tester,
  ) async {
    final personal = await mount(tester, direct: false);
    expect(find.text('Summarize conversation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-summary')));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationSummarySheet), findsOneWidget);
    expect(find.byKey(const ValueKey('summary-generate')), findsOneWidget);
    expect(personal.pending, isEmpty);
    expect(personal.summaries, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    personal.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct conversation keeps its ordinary overflow actions', (
    tester,
  ) async {
    final personal = await mount(tester, direct: true);
    expect(find.text('Summarize conversation'), findsNothing);
    expect(find.text('Search conversation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    personal.dispose();
    expect(tester.takeException(), isNull);
  });
}
