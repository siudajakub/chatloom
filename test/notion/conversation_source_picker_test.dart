import 'dart:ui' as ui;

import 'package:fluffychat/pages/chat/conversation_source_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

void main() {
  const first = ConversationRef(
    accountId: 'fictional-account-a',
    roomId: 'fictional-room-a',
    network: 'whatsapp',
  );
  const second = ConversationRef(
    accountId: 'fictional-account-a',
    roomId: 'fictional-room-b',
    network: 'whatsapp',
  );
  const otherAccount = ConversationRef(
    accountId: 'fictional-account-b',
    roomId: 'fictional-room-a',
    network: 'whatsapp',
  );
  final options = [
    const ConversationSourceOption(
      conversation: first,
      title: 'Fictional personal chat',
      subtitle: 'Personal account',
    ),
    const ConversationSourceOption(
      conversation: second,
      title: 'Fictional work chat',
      subtitle: 'Work account',
    ),
    const ConversationSourceOption(
      conversation: otherAccount,
      title: 'Fictional other account',
      subtitle: 'Other account',
    ),
  ];

  Future<void> open(
    WidgetTester tester, {
    required ValueChanged<ConversationRef?> onResult,
    List<ConversationSourceOption>? sources,
    ConversationRef? selected = first,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(
                await showConversationSourcePicker(
                  context,
                  sources: sources ?? options,
                  selected: selected,
                ),
              ),
              child: const Text('Choose source'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose source'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'same-network sources return full selected conversation identity',
    (tester) async {
      ConversationRef? result;
      await open(tester, onResult: (value) => result = value);
      expect(find.text('WhatsApp'), findsNWidgets(3));
      expect(find.text('All chats'), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tap(find.text('Fictional work chat'));
      await tester.pumpAndSettle();
      expect(result, same(second));
      expect(result!.accountId, 'fictional-account-a');
      expect(result!.roomId, 'fictional-room-b');
    },
  );

  testWidgets('account remains part of same-room source identity', (
    tester,
  ) async {
    ConversationRef? result;
    await open(
      tester,
      selected: otherAccount,
      onResult: (value) => result = value,
    );
    final semantics = tester.ensureSemantics();
    try {
      final node = find.semantics
          .byLabel('WhatsApp, Fictional other account, Other account')
          .evaluate()
          .single;
      expect(
        node.getSemanticsData().flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      await tester.tap(find.text('Fictional personal chat'));
      await tester.pumpAndSettle();
      expect(result, same(first));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('cancel returns null without selecting another source', (
    tester,
  ) async {
    var completed = false;
    ConversationRef? result = first;
    await open(
      tester,
      onResult: (value) {
        completed = true;
        result = value;
      },
    );
    await tester.tap(find.byTooltip('Cancel source selection'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('unavailable source exposes reason and cannot be selected', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var completed = false;
      await open(
        tester,
        onResult: (_) => completed = true,
        sources: [
          const ConversationSourceOption(
            conversation: first,
            title: 'Disconnected fictional source',
            available: false,
            unavailableReason: 'Reconnect this source before sending',
          ),
        ],
      );
      expect(find.text('Reconnect this source before sending'), findsOneWidget);
      final node = find.semantics
          .byLabel(
            'WhatsApp, Disconnected fictional source, Reconnect this source before sending',
          )
          .evaluate()
          .single;
      final data = node.getSemanticsData();
      expect(data.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(data.hasAction(ui.SemanticsAction.tap), isFalse);
      await tester.tap(find.text('Disconnected fictional source'));
      await tester.pump();
      expect(completed, isFalse);
      expect(find.text('Send via'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('mobile uses sheet and large text remains scrollable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 560);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await open(tester, onResult: (_) {}, scale: 2);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
    expect(
      MediaQuery.textScalerOf(tester.element(find.text('Send via'))).scale(16),
      32,
    );
    expect(tester.getBottomRight(find.byType(BottomSheet)).dy, closeTo(560, 1));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Fictional other account'),
      120,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fictional other account'));
    await tester.pumpAndSettle();
    expect(find.text('Send via'), findsNothing);
  });

  testWidgets('desktop uses dismissible dialog and empty state is explicit', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    ConversationRef? result = first;
    await open(tester, sources: [], onResult: (value) => result = value);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('No sending sources available'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1000.0]) {
    for (final chooseSource in [false, true]) {
      testWidgets(
        '${width < 600 ? 'sheet' : 'dialog'} ${chooseSource ? 'selection' : 'cancel'} preserves focused editor and active composing',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 700);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final controller = TextEditingController();
          final focus = FocusNode();
          addTearDown(controller.dispose);
          addTearDown(focus.dispose);
          late BuildContext editorContext;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    editorContext = context;
                    return TextField(controller: controller, focusNode: focus);
                  },
                ),
              ),
            ),
          );
          await tester.showKeyboard(find.byType(TextField));
          const draft = TextEditingValue(
            text: 'Fictional composing draft',
            selection: TextSelection.collapsed(offset: 9),
            composing: TextRange(start: 0, end: 9),
          );
          controller.value = draft;
          await tester.pump();
          final editor = tester.state(find.byType(EditableText));

          // Open directly to isolate the picker route. The production source
          // trigger belongs to the composer's TextFieldTapRegion separately.
          final selection = showConversationSourcePicker(
            editorContext,
            sources: options,
            selected: first,
          );
          await tester.pumpAndSettle();
          expect(
            find.byType(BottomSheet),
            width < 600 ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(Dialog),
            width < 600 ? findsNothing : findsOneWidget,
          );
          expect(tester.state(find.byType(EditableText)), same(editor));
          expect(focus.hasFocus, isTrue);
          expect(controller.value, draft);
          expect(tester.testTextInput.isVisible, isTrue);

          if (chooseSource) {
            await tester.tap(find.text('Fictional work chat'));
          } else {
            await tester.tap(find.byTooltip('Cancel source selection'));
          }
          await tester.pumpAndSettle();
          expect(await selection, chooseSource ? same(second) : isNull);
          expect(tester.state(find.byType(EditableText)), same(editor));
          expect(focus.hasFocus, isTrue);
          expect(controller.value, draft);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(tester.takeException(), isNull);
          // Close the input connection before disposing its owners.
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
