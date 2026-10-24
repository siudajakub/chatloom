import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/ui/notion/notion.dart' show NotionGlassMenuRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The chip excludes its tooltip from semantics (its own label carries the
/// text), so match the material_ui Tooltip directly.
Finder chipTooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && widget.message == message,
);

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
    // Compact chip: glyph only, full description in tooltip and semantics.
    expect(find.text('WhatsApp'), findsNothing);
    expect(chipTooltip('Sending via WhatsApp'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ConversationSourceChip)),
      const Size(48, 48),
    );
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
    expect(chipTooltip('Sending via WhatsApp'), findsOneWidget);
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
      // The compact chip fits inline down to ~300dp; below, it moves above.
      await tester.binding.setSurfaceSize(const Size(280, 700));
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

  testWidgets('320dp and 200 percent text keep compact chip inline', (
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
    // The glyph does not scale with text, so it never takes the field.
    expect(find.text('Messenger'), findsNothing);
    expect(chipTooltip('Messenger, choose sending source'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(
      tester.getSize(find.byType(ConversationSourceChip)).width,
      lessThanOrEqualTo(56),
    );
    expect(
      tester.getSize(find.byType(TextField)).width,
      greaterThanOrEqualTo(120),
    );
    expect(
      (tester.getCenter(find.byType(ConversationSourceChip)).dy -
              tester.getCenter(find.byType(TextField)).dy)
          .abs(),
      lessThan(30),
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
      expect(chipTooltip('Replying via Signal'), findsOneWidget);
      await tester.tap(find.byType(ConversationSourceChip));
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

  Widget trayShell({
    required Widget input,
    required List<ComposerAction> actions,
    TextEditingController? collapseOnText,
    Object? collapseToken,
    ValueChanged<bool>? onExpandedChanged,
    bool reduceMotion = false,
    TextDirection direction = TextDirection.ltr,
    Widget source = const ConversationSourceChip(network: 'whatsapp'),
  }) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: Directionality(
            textDirection: direction,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: CompactComposer(
                input: input,
                source: source,
                actions: actions,
                collapseOnText: collapseOnText,
                collapseToken: collapseToken,
                onExpandedChanged: onExpandedChanged,
                primaryAction: const IconButton(
                  onPressed: null,
                  icon: Icon(Icons.mic_none),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  List<ComposerAction> fictionalActions(List<String> used, {int count = 2}) => [
    for (final (icon, label) in [
      (Icons.attach_file_outlined, 'Attach media or a file'),
      (Icons.add_reaction_outlined, 'Emoji picker'),
      (Icons.videocam_outlined, 'Switch to round video'),
      (Icons.switch_account_outlined, 'Send from another account'),
    ].take(count))
      ComposerAction(
        icon: icon,
        label: label,
        onPressed: () => used.add(label),
      ),
  ];

  bool? expandedFlag(WidgetTester tester, String tooltip) => tester
      .getSemantics(find.byTooltip(tooltip))
      .getSemanticsData()
      .flagsCollection
      .isExpanded
      .toBoolOrNull();

  testWidgets('plus opens inline tray, editor narrows and keeps IME state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(411, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    final used = <String>[];
    final changes = <bool>[];
    await tester.pumpWidget(
      trayShell(
        input: TextField(controller: controller, focusNode: focus),
        actions: fictionalActions(used),
        collapseOnText: controller,
        onExpandedChanged: changes.add,
      ),
    );
    // Collapsed: no hidden targets, no semantics for the tray actions.
    expect(
      find.byTooltip('Attach media or a file').hitTestable(),
      findsNothing,
    );
    expect(find.bySemanticsLabel('Emoji picker'), findsNothing);
    expect(expandedFlag(tester, 'More message actions'), isFalse);
    await tester.showKeyboard(find.byType(TextField));
    controller.value = const TextEditingValue(
      text: '',
      composing: TextRange.empty,
    );
    final editor = tester.state(find.byType(EditableText));
    final collapsedWidth = tester.getSize(find.byType(TextField)).width;
    await tester.tap(find.byTooltip('More message actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // Mid animation the field already narrows instead of being replaced.
    final midWidth = tester.getSize(find.byType(TextField)).width;
    expect(midWidth, lessThan(collapsedWidth));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide message actions'), findsOneWidget);
    expect(expandedFlag(tester, 'Hide message actions'), isTrue);
    expect(changes, [true]);
    expect(
      tester.getSize(find.byType(TextField)).width,
      closeTo(collapsedWidth - 2 * 48, 0.5),
    );
    for (final label in ['Attach media or a file', 'Emoji picker']) {
      expect(find.byTooltip(label).hitTestable(), findsOneWidget);
      expect(tester.getSize(find.byTooltip(label)), const Size(48, 48));
    }
    // The inline action row sits between "+" and the field, in one line.
    expect(
      tester.getCenter(find.byTooltip('Emoji picker')).dx,
      lessThan(tester.getTopLeft(find.byType(TextField)).dx),
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.state(find.byType(EditableText)), same(editor));
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    // Using an action runs it once and collapses the tray.
    await tester.tap(find.byTooltip('Emoji picker'));
    await tester.pumpAndSettle();
    expect(used, ['Emoji picker']);
    expect(find.byTooltip('More message actions'), findsOneWidget);
    expect(changes, [true, false]);
    expect(tester.getSize(find.byType(TextField)).width, collapsedWidth);
    expect(tester.state(find.byType(EditableText)), same(editor));
    semantics.dispose();
  });

  testWidgets('first typed text, plus again and context change collapse', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final used = <String>[];
    Object token = 'room-a';
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return trayShell(
            input: TextField(controller: controller),
            actions: fictionalActions(used),
            collapseOnText: controller,
            collapseToken: token,
          );
        },
      ),
    );
    Future<void> open() async {
      await tester.tap(find.byTooltip('More message actions'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Hide message actions'), findsOneWidget);
    }

    await open();
    // Tapping the editor itself keeps the tray open.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide message actions'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'H');
    await tester.pumpAndSettle();
    expect(find.byTooltip('More message actions'), findsOneWidget);
    expect(controller.text, 'H');

    await open();
    await tester.tap(find.byTooltip('Hide message actions'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('More message actions'), findsOneWidget);

    await open();
    rebuild(() => token = 'room-b');
    await tester.pumpAndSettle();
    expect(find.byTooltip('More message actions'), findsOneWidget);
    expect(used, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow width moves the remainder into a More actions menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final used = <String>[];
    await tester.pumpWidget(
      trayShell(
        input: const TextField(),
        actions: fictionalActions(used, count: 4),
        source: ConversationSourceChip(network: 'telegram', onPressed: () {}),
      ),
    );
    await tester.tap(find.byTooltip('More message actions'));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('Attach media or a file').hitTestable(),
      findsOneWidget,
    );
    expect(find.byTooltip('More actions'), findsOneWidget);
    expect(find.byTooltip('Send from another account'), findsNothing);
    // The source yields its width to the tray, the editor stays usable.
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(40));
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    // The glass Notion menu, not a Material menu with ListTiles.
    expect(find.byType(NotionGlassMenuRow), findsNWidgets(2));
    expect(find.byType(MenuItemButton), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Send from another account'), findsOneWidget);
    await tester.tap(find.text('Send from another account'));
    await tester.pumpAndSettle();
    expect(used, ['Send from another account']);
    expect(find.byTooltip('More message actions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion opens without animation; RTL mirrors the tray', (
    tester,
  ) async {
    final used = <String>[];
    await tester.pumpWidget(
      trayShell(
        input: const TextField(),
        actions: fictionalActions(used),
        reduceMotion: true,
        direction: TextDirection.rtl,
      ),
    );
    await tester.tap(find.byTooltip('More message actions'));
    await tester.pump();
    expect(
      find.byTooltip('Attach media or a file').hitTestable(),
      findsOneWidget,
    );
    // In RTL the tray sits right of the field (between "+" and the editor).
    expect(
      tester.getCenter(find.byTooltip('Emoji picker')).dx,
      greaterThan(tester.getTopRight(find.byType(TextField)).dx),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('chooser and unavailable hints keep semantics labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(
        input: const TextField(),
        source: ConversationSourceChip(
          network: 'telegram',
          label: 'Choose source',
          hint: ConversationSourceHint.choose,
          onPressed: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
    expect(chipTooltip('Choose source, choose sending source'), findsOneWidget);
    await tester.pumpWidget(
      shell(
        input: const TextField(),
        source: ConversationSourceChip(
          network: 'telegram',
          label: 'Telegram · unavailable',
          hint: ConversationSourceHint.unavailable,
          onPressed: () {},
        ),
      ),
    );
    expect(
      chipTooltip('Telegram · unavailable, choose sending source'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp open tray: source yields its width, editor survives', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    final used = <String>[];
    await tester.pumpWidget(
      trayShell(
        input: TextField(controller: controller, focusNode: focus),
        actions: fictionalActions(used, count: 3),
        collapseOnText: controller,
        source: ConversationSourceChip(network: 'telegram', onPressed: () {}),
      ),
    );
    final chip = find.byType(ConversationSourceChip);
    expect(chip.hitTestable(), findsOneWidget);
    final chipWidth = tester.getSize(chip).width;
    await tester.showKeyboard(find.byType(TextField));
    final editor = tester.state(find.byType(EditableText));
    final collapsedWidth = tester.getSize(find.byType(TextField)).width;
    await tester.tap(find.byTooltip('More message actions'));
    await tester.pumpAndSettle();
    // All three actions fit inline because the chip gave up its width.
    for (final label in [
      'Attach media or a file',
      'Emoji picker',
      'Switch to round video',
    ]) {
      expect(find.byTooltip(label).hitTestable(), findsOneWidget);
    }
    expect(find.byTooltip('More actions'), findsNothing);
    expect(chip.hitTestable(), findsNothing);
    // Hidden from assistive technology while it has no width.
    expect(
      find.ancestor(
        of: chip,
        matching: find.byWidgetPredicate(
          (widget) => widget is ExcludeSemantics && widget.excluding,
        ),
      ),
      findsOneWidget,
    );
    final open = tester.getSize(find.byType(TextField)).width;
    expect(open, closeTo(collapsedWidth + chipWidth + 1 - 3 * 48, 0.5));
    expect(open, greaterThan(40));
    expect(tester.state(find.byType(EditableText)), same(editor));
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    // Closing gives the width back to the source.
    await tester.tap(find.byTooltip('Hide message actions'));
    await tester.pumpAndSettle();
    expect(chip.hitTestable(), findsOneWidget);
    expect(tester.getSize(chip).width, chipWidth);
    expect(tester.getSize(find.byType(TextField)).width, collapsedWidth);
    expect(tester.state(find.byType(EditableText)), same(editor));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('wide composer keeps the source while the tray is open', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      trayShell(
        input: const TextField(),
        actions: fictionalActions(<String>[], count: 3),
      ),
    );
    await tester.tap(find.byTooltip('More message actions'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationSourceChip).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
