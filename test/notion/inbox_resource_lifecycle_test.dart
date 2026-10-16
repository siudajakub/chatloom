// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/pages/chat_list/chat_list_body.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

class _Inbox extends ChatList {
  const _Inbox({super.key}) : super(activeChat: null);
  @override
  ChatListController createState() => _Controller();
}

class _Controller extends ChatListController {
  @override
  // Native plugins are outside this offline subscription regression.
  // ignore: must_call_super
  void initState() {
    activeFilter = ActiveFilter.allChats;
  }

  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => Scaffold(body: ChatListViewBody(this));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets('inbox retains subscriptions across parent builds and rebinds accounts', (
    tester,
  ) async {
    final a = ConversationClient();
    final b = ConversationClient('@other:example.invalid');
    final matrix = ConversationMatrix(a, AppSettings.store);
    addTearDown(() => PersonalClient.of(a).dispose());
    addTearDown(() => PersonalClient.of(b).dispose());
    final key = GlobalKey<ChatListController>();
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: matrix,
        child: MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: _Inbox(key: key),
        ),
      ),
    );
    final controller = key.currentState! as _Controller;
    Stream<Object>? updates() => tester
        .widget<StreamBuilder<Object>>(find.byType(StreamBuilder<Object>))
        .stream;
    final first = updates();
    controller.rebuild();
    await tester.pump();
    expect(updates(), same(first));
    matrix.active = b;
    controller.rebuild();
    await tester.pump();
    expect(updates(), isNot(same(first)));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
