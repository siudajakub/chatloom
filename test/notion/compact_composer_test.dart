import 'dart:ui' as ui;

import 'package:fluffychat/pages/chat/compact_composer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget shell({
    required Widget input,
    Widget source = const ConversationSourceChip(network: 'whatsapp'),
    Widget? preview,
    Widget? add,
    Widget? primary,
    double scale = 1,
  }) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: CompactComposer(
              input: input,
              source: source,
              contextPreview: preview,
              addAction:
                  add ??
                  const IconButton(onPressed: null, icon: Icon(Icons.add)),
              primaryAction:
                  primary ??
                  const IconButton(onPressed: null, icon: Icon(Icons.mic_none)),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('single line row is 50dp and actions retain 48dp targets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      shell(
        input: const TextField(
          decoration: InputDecoration(isDense: true, border: InputBorder.none),
        ),
      ),
    );
    expect(tester.getSize(find.byType(CompactComposer)).height, 62);
    expect(
      tester.getSize(find.widgetWithIcon(IconButton, Icons.add)),
      const Size(48, 48),
    );
    expect(
      tester.getSize(find.widgetWithIcon(IconButton, Icons.mic_none)),
      const Size(48, 48),
    );
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source stays visible while actions and multiline input work', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var additions = 0;
    var sends = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => shell(
          input: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
          ),
          add: IconButton(
            onPressed: () => additions++,
            icon: const Icon(Icons.add),
          ),
          primary: IconButton(
            onPressed: () => sends++,
            icon: Icon(
              controller.text.isEmpty ? Icons.mic_none : Icons.arrow_upward,
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'One\nTwo\nThree\nFour\nFive',
    );
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.text('WhatsApp'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.arrow_upward));
    expect(additions, 1);
    expect(sends, 1);
    expect(controller.text, 'One\nTwo\nThree\nFour\nFive');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'resize moves only source and preserves active IME editor state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        shell(
          input: TextField(
            controller: controller,
            focusNode: focus,
            minLines: 1,
            maxLines: 4,
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      controller.value = const TextEditingValue(
        text: 'Fictional draft',
        selection: TextSelection(baseOffset: 4, extentOffset: 9),
        composing: TextRange(start: 0, end: 9),
      );
      await tester.pump();
      final editorState = tester.state(find.byType(EditableText));
      final originalValue = controller.value;
      final inlineTop = tester
          .getTopLeft(find.byType(ConversationSourceChip))
          .dy;
      final fieldTop = tester.getTopLeft(find.byType(TextField)).dy;
      expect((inlineTop - fieldTop).abs(), lessThan(30));
      await tester.binding.setSurfaceSize(const Size(320, 700));
      await tester.pump();
      expect(tester.state(find.byType(EditableText)), same(editorState));
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(controller.value, originalValue);
      expect(
        tester.getTopLeft(find.byType(ConversationSourceChip)).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      expect(
        tester.getSize(find.byType(TextField)).width,
        greaterThanOrEqualTo(120),
      );
      await tester.binding.setSurfaceSize(const Size(500, 700));
      await tester.pump();
      expect(tester.state(find.byType(EditableText)), same(editorState));
      expect(controller.value, originalValue);
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320dp and 200 percent text keep network readable above editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      shell(
        scale: 2,
        input: const TextField(minLines: 1, maxLines: 4),
        source: ConversationSourceChip(network: 'messenger', onPressed: () {}),
      ),
    );
    expect(find.text('Messenger'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(
      tester.getSize(find.byType(TextField)).width,
      greaterThanOrEqualTo(120),
    );
    expect(
      tester.getTopLeft(find.byType(ConversationSourceChip)).dy,
      lessThan(tester.getTopLeft(find.byType(TextField)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply lock disables picker and exposes its actual source', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var opens = 0;
      await tester.pumpWidget(
        shell(
          input: const TextField(),
          source: ConversationSourceChip(
            network: 'signal',
            locked: true,
            onPressed: () => opens++,
          ),
        ),
      );
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
      final node = find.semantics
          .byLabel('Replying via Signal')
          .evaluate()
          .single;
      expect(
        node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isFalse,
      );
      await tester.tap(find.text('Signal'));
      expect(opens, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('context preview can cancel without replacing the editor', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Retained draft');
    addTearDown(controller.dispose);
    var replying = true;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => shell(
          input: TextField(controller: controller),
          preview: replying
              ? Row(
                  children: [
                    const Expanded(
                      child: Text('Replying to a fictional source'),
                    ),
                    IconButton(
                      tooltip: 'Cancel reply',
                      onPressed: () => setState(() => replying = false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                )
              : null,
        ),
      ),
    );
    final editor = tester.state(find.byType(EditableText));
    await tester.tap(find.byTooltip('Cancel reply'));
    await tester.pump();
    expect(tester.state(find.byType(EditableText)), same(editor));
    expect(controller.text, 'Retained draft');
    expect(find.text('Replying to a fictional source'), findsNothing);
  });
}
