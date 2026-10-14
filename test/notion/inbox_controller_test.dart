// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _SearchHarness extends ChatList {
  const _SearchHarness({super.key}) : super(activeChat: null);
  @override
  ChatListController createState() => _ControllerHarness();
}

/// Exercise the actual controller's search/cancel callbacks and real scroll
/// position. Native startup, plugins, storage, transport and private accounts
/// are deliberately excluded from this regression, not claimed as verified.
class _ControllerHarness extends ChatListController {
  String account = 'fictional-account-a';
  int inboxCount = 80;
  @override
  String get inboxAccountKey => account;

  // Calling the superclass would initialize native storage, push and plugins.
  // This probe exercises inherited search callbacks only, not app startup.
  @override
  // ignore: must_call_super
  void initState() {
    activeFilter = ActiveFilter.allChats;
  }

  void switchAccount(String value) => setState(() => account = value);
  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView.builder(
      controller: scrollController,
      itemCount: isSearchMode && searchController.text.isNotEmpty
          ? 1
          : inboxCount,
      itemExtent: 50,
      itemBuilder: (_, index) => Text('Fictional conversation $index'),
    ),
  );
}

Future<_ControllerHarness> _mount(WidgetTester tester) async {
  final key = GlobalKey<ChatListController>();
  await tester.pumpWidget(MaterialApp(home: _SearchHarness(key: key)));
  await tester.pumpAndSettle();
  return key.currentState! as _ControllerHarness;
}

void main() {
  testWidgets('restoration clamps to the current unfiltered list extent', (
    tester,
  ) async {
    final controller = await _mount(tester);
    controller.scrollController.jumpTo(700);
    controller.startSearch();
    controller.searchController.text = 'match';
    controller.onSearchEnter('match');
    await tester.pumpAndSettle();
    controller.inboxCount = 20;
    controller.cancelSearch();
    await tester.pumpAndSettle();
    expect(
      controller.scrollController.offset,
      controller.scrollController.position.maxScrollExtent,
    );
    expect(controller.scrollController.offset, lessThan(700));
    expect(tester.takeException(), isNull);
  });
  testWidgets('cancel restores the first pre-search offset after result clamp', (
    tester,
  ) async {
    final controller = await _mount(tester);
    controller.scrollController.jumpTo(700);
    controller.startSearch();
    controller.searchController.text = 'match';
    controller.onSearchEnter('match');
    await tester.pumpAndSettle();
    expect(controller.scrollController.offset, 0);
    // Re-opening an already active search must not overwrite the saved offset.
    controller.startSearch();
    controller.cancelSearch();
    await tester.pumpAndSettle();
    expect(controller.scrollController.offset, 700);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Clear keeps search open and restoration waits for cancel', (
    tester,
  ) async {
    final controller = await _mount(tester);
    controller.scrollController.jumpTo(700);
    controller.startSearch();
    controller.searchController.text = 'match';
    controller.onSearchEnter('match');
    await tester.pumpAndSettle();
    controller.searchController.clear();
    controller.onSearchEnter('');
    await tester.pumpAndSettle();
    expect(controller.isSearchMode, isTrue);
    expect(controller.scrollController.offset, 0);
    controller.cancelSearch();
    await tester.pumpAndSettle();
    expect(controller.scrollController.offset, 700);
  });
  testWidgets(
    'late restoration does not apply to another account or disposed view',
    (tester) async {
      final controller = await _mount(tester);
      controller.scrollController.jumpTo(700);
      controller.startSearch();
      controller.searchController.text = 'match';
      controller.onSearchEnter('match');
      await tester.pumpAndSettle();
      controller.cancelSearch();
      controller.switchAccount('fictional-account-b');
      await tester.pumpAndSettle();
      expect(controller.scrollController.offset, 0);
      controller.scrollController.jumpTo(500);
      controller.startSearch();
      controller.searchController.text = 'match';
      controller.onSearchEnter('match');
      await tester.pumpAndSettle();
      controller.cancelSearch();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
