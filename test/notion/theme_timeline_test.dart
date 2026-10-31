// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 6 theme-timeline: Notion date/time pickers, flat menus, sheets as
// centred dialogs on wide desktop windows (MAC-18), capped spinners,
// long-press haptics, service chips and the header back button.
import 'dart:async';

import 'package:chatloom/pages/chat/conversation_service_chip.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<BuildContext> _host(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(400, 800),
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark).copyWith(platform: platform),
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: disableAnimations),
        child: Builder(
          builder: (context) {
            captured = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  group('theme', () {
    test('date and time pickers are themed; menus are flat', () {
      for (final brightness in Brightness.values) {
        final theme = NotionTheme.build(brightness);
        final tokens = theme.extension<NotionTokens>()!;
        final date = theme.datePickerTheme;
        expect(date.elevation, 0);
        expect(date.backgroundColor, tokens.colors.surface);
        expect(date.headerBackgroundColor, tokens.colors.surface);
        expect(date.todayBorder?.color, tokens.palette.accent);
        expect(
          date.dayBackgroundColor?.resolve({WidgetState.selected}),
          tokens.palette.accentFill,
        );
        expect(date.shape, isA<RoundedRectangleBorder>());
        final time = theme.timePickerTheme;
        expect(time.elevation, 0);
        expect(time.dialHandColor, tokens.palette.accentFill);
        expect(theme.popupMenuTheme.elevation, 0);
        expect(theme.menuTheme.style?.elevation?.resolve({}), 0);
      }
    });

    testWidgets('the Material date picker opens with the Notion surface', (
      tester,
    ) async {
      final context = await _host(tester);
      final picked = showDatePicker(
        context: context,
        initialDate: DateTime(2026, 10, 24),
        firstDate: DateTime(2026),
        lastDate: DateTime(2027),
      );
      await tester.pumpAndSettle();
      final tokens = context.notion;
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(DatePickerDialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, tokens.colors.surface);
      expect(material.elevation, 0);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await picked, DateTime(2026, 10, 24));
    });

    testWidgets('menuStyleOf honours reduced motion', (tester) async {
      final reduced = await _host(tester, disableAnimations: true);
      expect(NotionMotion.menuStyleOf(reduced).duration, NotionMotion.instant);
      final normal = await _host(tester);
      expect(NotionMotion.menuStyleOf(normal), NotionMotion.menuStyle);
    });
  });

  group('showNotionSheet (MAC-18)', () {
    testWidgets('a phone keeps the bottom sheet with its handle', (
      tester,
    ) async {
      final context = await _host(tester);
      expect(notionSheetAsDialog(context), isFalse);
      final result = showNotionSheet<int>(
        context: context,
        title: 'Fictional sheet',
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).pop(3),
          child: const Text('Pick'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(NotionDialogFrame), findsNothing);
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(await result, 3);
    });

    testWidgets('a wide Android tablet keeps the sheet', (tester) async {
      final context = await _host(tester, size: const Size(1100, 800));
      expect(notionSheetAsDialog(context), isFalse);
    });

    testWidgets('a wide Mac window shows a centred glass dialog', (
      tester,
    ) async {
      final context = await _host(
        tester,
        platform: TargetPlatform.macOS,
        size: const Size(1120, 800),
      );
      expect(notionSheetAsDialog(context), isTrue);
      final result = showNotionSheet<int>(
        context: context,
        title: 'Fictional sheet',
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).pop(5),
          child: const Text('Pick'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(NotionDialogFrame), findsOneWidget);
      expect(find.text('Fictional sheet'), findsOneWidget);
      final panel = tester.getRect(find.byType(NotionGlassPanel));
      expect(panel.width, lessThanOrEqualTo(NotionSize.sheetDialogMaxWidth));
      expect(panel.center.dx, closeTo(560, 1));
      expect(panel.center.dy, closeTo(400, 1));
      // No drag handle in the dialog: only the content and title remain.
      expect(
        find.descendant(
          of: find.byType(NotionSheet),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.constraints?.maxWidth == 36,
          ),
        ),
        findsNothing,
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(await result, 5);
    });

    testWidgets('Escape and the barrier close the desktop dialog', (
      tester,
    ) async {
      final context = await _host(
        tester,
        platform: TargetPlatform.macOS,
        size: const Size(1120, 800),
      );
      final result = showNotionSheet<int>(
        context: context,
        builder: (context) => const Text('Body'),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Body'), findsNothing);
      expect(await result, isNull);
    });

    testWidgets('a narrow Mac window and asDialog: false keep the sheet', (
      tester,
    ) async {
      final narrow = await _host(
        tester,
        platform: TargetPlatform.macOS,
        size: const Size(600, 800),
      );
      expect(notionSheetAsDialog(narrow), isFalse);
      final wide = await _host(
        tester,
        platform: TargetPlatform.macOS,
        size: const Size(1120, 800),
      );
      unawaited(
        showNotionSheet<void>(
          context: wide,
          asDialog: false,
          builder: (context) => const Text('Body'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  });

  group('spinners and haptics', () {
    testWidgets('a zero-delay spinner shows at once and rests at the cap', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: const Center(
            child: NotionDelayedSpinner(
              delay: Duration.zero,
              semanticsLabel: 'Loading',
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
      await tester.pump(NotionMotion.short + NotionMotion.loopCap);
      await tester.pump(const Duration(milliseconds: 100));
      // Rested: the ring's ticker is muted (its last frame stays).
      expect(
        TickerMode.valuesOf(
          tester.element(find.byType(CircularProgressIndicator)),
        ).enabled,
        isFalse,
      );
    });

    testWidgets('a busy NotionButton uses the capped spinner', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: const Scaffold(
            body: Center(
              child: NotionButton(label: 'Save', busy: true, onPressed: null),
            ),
          ),
        ),
      );
      expect(find.byType(NotionDelayedSpinner), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('NotionTapTarget buzzes on long press, not on right click', (
      tester,
    ) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: NotionTapTarget(
              behavior: HitTestBehavior.opaque,
              onLongPress: () => presses++,
              child: const SizedBox.square(dimension: 80),
            ),
          ),
        ),
      );
      await tester.longPress(find.byType(NotionTapTarget));
      expect(presses, 1);
      // Android long-press buzz: HapticFeedback.vibrate() has no arguments.
      expect(haptics, [null]);
      await tester.tap(find.byType(NotionTapTarget), buttons: kSecondaryButton);
      expect(presses, 2);
      expect(haptics, hasLength(1));
    });
  });

  group('chrome', () {
    testWidgets('service chip: opaque surface, lg corners, muted caption', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: const Scaffold(
            body: ConversationServiceChip(
              text: TextSpan(text: 'Anna joined'),
              strikeThrough: true,
            ),
          ),
        ),
      );
      final context = tester.element(find.byType(ConversationServiceChip));
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(ConversationServiceChip),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color, context.notion.colors.surface);
      expect(decoration.borderRadius, NotionRadius.lgAll);
      final text = tester.widget<RichText>(find.byType(RichText));
      expect(text.text.style?.color, context.notion.colors.textSecondary);
      expect(text.text.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('NotionScaffold back button has the press motion', (
      tester,
    ) async {
      var backs = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: NotionScaffold(
            title: 'Fictional',
            onBack: () => backs++,
            children: const [Text('Row')],
          ),
        ),
      );
      final back = find.byTooltip('Back');
      expect(
        find.ancestor(of: back, matching: find.byType(NotionPressable)),
        findsOneWidget,
      );
      await tester.tap(back);
      expect(backs, 1);
    });
  });
}
