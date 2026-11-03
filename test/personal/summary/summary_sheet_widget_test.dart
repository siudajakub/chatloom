// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline UI fixtures. No journal, provider, account or HTTP access.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/summary/ui/conversation_summary_sheet.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

const _captureKey = ValueKey('summary-capture');
const _summaryText = '''## Overview
The group agreed to meet on Saturday morning and move the picnic indoors if it rains.

## Decisions
- **When:** Saturday at 10:00.
- **Where:** Riverside café, with a park walk if the weather allows.

## Next steps
- Anna will book a table for six people.
- Leo will confirm the weather on Friday evening.

## Open questions
- Two people have not confirmed whether they can join.''';

SummaryResult _result({bool complete = true, String? note}) => SummaryResult(
  text: _summaryText,
  model: 'google/gemini-3.1-flash-lite',
  messageCount: 100,
  startedAt: DateTime.utc(2026, 11, 1, 8),
  endedAt: DateTime.utc(2026, 11, 3, 12),
  complete: complete,
  coverageNote: note,
  estimatedCostUsd: .0004,
);

Future<void> _advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(NotionMotion.long);
  await tester.pump(NotionMotion.long);
}

Future<void> _open(
  WidgetTester tester, {
  required SummaryRunner runner,
  Size size = const Size(390, 844),
  TargetPlatform platform = TargetPlatform.android,
  double textScale = 1,
  bool reducedMotion = false,
  Listenable? accessChanges,
  bool Function()? isCurrent,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark).copyWith(platform: platform),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      builder: (context, child) => RepaintBoundary(
        key: _captureKey,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reducedMotion,
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('Weekend plans')),
        body: Builder(
          builder: (context) => Center(
            child: NotionButton(
              key: const ValueKey('summary-open'),
              label: 'Open summary',
              onPressed: () => showConversationSummary(
                context,
                chatName: 'Weekend plans',
                summarize: runner,
                accessChanges: accessChanges,
                isCurrent: isCurrent,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _advance(tester);
  await tester.tap(find.byKey(const ValueKey('summary-open')));
  await _advance(tester);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await _advance(tester);
  await tester.tap(target);
  await _advance(tester);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory =
      Platform.environment['SUMMARY_CAPTURE_DIR'] ??
      Platform.environment['CONVERSATION_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final text = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      text.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
    }
    await text.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets('range, detail and language reach the runner only on generate', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <SummaryRequest>[];
    await _open(
      tester,
      runner: (request, progress, cancellation) async {
        requests.add(request);
        return _result();
      },
    );
    expect(requests, isEmpty);
    await _tap(tester, 'summary-scope-hours');
    await _tap(tester, 'summary-amount-6');
    await _tap(tester, 'summary-detail-detailed');
    final language = find.byKey(const ValueKey('summary-language'));
    await tester.ensureVisible(language);
    await _advance(tester);
    await tester.tap(language);
    await _advance(tester);
    await tester.tap(find.text('English'));
    await _advance(tester);
    expect(requests, isEmpty);
    await _tap(tester, 'summary-generate');
    expect(requests, hasLength(1));
    expect(requests.single.scope, SummaryScopeKind.hours);
    expect(requests.single.amount, 6);
    expect(requests.single.detail, SummaryDetail.detailed);
    expect(requests.single.language, 'en');
    expect(find.byKey(const ValueKey('summary-result')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom range validates before any work and whole history needs no number',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <SummaryRequest>[];
      await _open(
        tester,
        runner: (request, progress, cancellation) async {
          requests.add(request);
          return _result();
        },
      );
      final field = find.byType(TextField);
      await tester.enterText(field, '0');
      await _advance(tester);
      expect(
        find.text('Enter a whole number from 1 to 10000.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<NotionButton>(
              find.byKey(const ValueKey('summary-generate')),
            )
            .onPressed,
        isNull,
      );
      expect(requests, isEmpty);
      await _tap(tester, 'summary-scope-days');
      await tester.enterText(find.byType(TextField), '14');
      await _advance(tester);
      await _tap(tester, 'summary-scope-all');
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('before the bridge import'), findsOneWidget);
      await _tap(tester, 'summary-generate');
      expect(requests.single.scope, SummaryScopeKind.all);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stop cancels and a late response cannot replace the editor', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = Completer<SummaryResult>();
    late SummaryCancellation cancellation;
    late ValueChanged<SummaryUiProgress> report;
    await _open(
      tester,
      runner: (request, progress, token) {
        cancellation = token;
        report = progress;
        return result.future;
      },
    );
    await _tap(tester, 'summary-generate');
    report(
      const SummaryUiProgress(
        stage: SummaryUiStage.waitingWorker,
        messageCount: 100,
      ),
    );
    await _advance(tester);
    expect(find.text('Waiting for the summary service'), findsOneWidget);
    await _tap(tester, 'summary-stop');
    expect(cancellation.isCancelled, isTrue);
    result.complete(_result());
    report(const SummaryUiProgress(stage: SummaryUiStage.summarizing));
    await _advance(tester);
    expect(find.byKey(const ValueKey('summary-options')), findsOneWidget);
    expect(find.byKey(const ValueKey('summary-result')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing cancels the request without touching a disposed sheet', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = Completer<SummaryResult>();
    late SummaryCancellation cancellation;
    await _open(
      tester,
      runner: (request, progress, token) {
        cancellation = token;
        return result.future;
      },
    );
    await _tap(tester, 'summary-generate');
    await _tap(tester, 'summary-close');
    expect(cancellation.isCancelled, isTrue);
    result.complete(_result());
    await _advance(tester);
    expect(find.byType(ConversationSummarySheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy preserves the full result and coverage is visible', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await _open(
      tester,
      runner: (request, progress, cancellation) async => _result(
        complete: false,
        note: '2 media messages had no transcript and were omitted.',
      ),
    );
    await _tap(tester, 'summary-generate');
    expect(find.text('Partial conversation'), findsOneWidget);
    expect(find.textContaining('2 media messages'), findsOneWidget);
    final rendered = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(rendered.textSpan!.toPlainText(), contains('• When: Saturday'));
    expect(rendered.textSpan!.toPlainText(), isNot(contains('## Overview')));
    await _tap(tester, 'summary-copy');
    expect(copied, [_summaryText]);
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'access revocation cancels the request and removes its own route',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final access = ValueNotifier(true);
      addTearDown(access.dispose);
      final result = Completer<SummaryResult>();
      late SummaryCancellation cancellation;
      await _open(
        tester,
        accessChanges: access,
        isCurrent: () => access.value,
        runner: (request, progress, token) {
          cancellation = token;
          return result.future;
        },
      );
      await _tap(tester, 'summary-generate');
      access.value = false;
      await _advance(tester);
      expect(cancellation.isCancelled, isTrue);
      expect(find.byType(ConversationSummarySheet), findsNothing);
      result.complete(_result());
      await _advance(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stale copy action cannot expose a result after access changes',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final access = ValueNotifier(true);
      addTearDown(access.dispose);
      var writes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') writes++;
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await _open(
        tester,
        accessChanges: access,
        isCurrent: () => access.value,
        runner: (request, progress, token) async => _result(),
      );
      await _tap(tester, 'summary-generate');
      final copy = tester
          .widget<NotionButton>(find.byKey(const ValueKey('summary-copy')))
          .onPressed!;
      access.value = false;
      copy();
      await _advance(tester);
      expect(writes, 0);
      expect(find.byType(ConversationSummarySheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'language picker completion is safe after its summary loses access',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final access = ValueNotifier(true);
      addTearDown(access.dispose);
      await _open(
        tester,
        accessChanges: access,
        isCurrent: () => access.value,
        runner: (request, progress, token) async => _result(),
      );
      await _tap(tester, 'summary-language');
      expect(find.text('English'), findsOneWidget);
      access.value = false;
      await _advance(tester);
      expect(find.byType(ConversationSummarySheet), findsNothing);
      // The picker is a separate route above the removed summary. Completing
      // it must never call setState on that disposed summary's state.
      await tester.tap(find.text('English'));
      await _advance(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unconfirmed timeout does not offer an immediate paid retry', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _open(
      tester,
      runner: (request, progress, cancellation) async =>
          throw const SummaryException('summary_timeout'),
    );
    await _tap(tester, 'summary-generate');
    expect(find.textContaining('may still be running'), findsOneWidget);
    expect(find.byKey(const ValueKey('summary-retry')), findsNothing);
    expect(find.byKey(const ValueKey('summary-edit')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('unknown failures never expose provider error payloads', () {
    const privateFixture = 'provider response with fictional-private-payload';
    expect(
      summaryFailureMessage(StateError(privateFixture)),
      isNot(contains(privateFixture)),
    );
    expect(
      summaryFailureMessage(const SummaryException('disappearing_messages')),
      contains('Disappearing conversations'),
    );
    expect(
      summaryFailureMessage(
        const SummaryException('summary_history_incomplete'),
      ),
      contains('shorter time range'),
    );
  });

  for (final scenario in [
    (
      name: 'phone',
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      scale: 1.0,
      reduced: false,
    ),
    (
      name: 'desktop',
      size: const Size(1000, 800),
      platform: TargetPlatform.macOS,
      scale: 1.0,
      reduced: false,
    ),
    (
      name: 'narrow-large-type',
      size: const Size(320, 740),
      platform: TargetPlatform.android,
      scale: 2.0,
      reduced: true,
    ),
  ]) {
    testWidgets(
      '${scenario.name} settings and result fit the real sheet route',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _open(
          tester,
          size: scenario.size,
          platform: scenario.platform,
          textScale: scenario.scale,
          reducedMotion: scenario.reduced,
          runner: (request, progress, cancellation) async => _result(),
        );
        expect(tester.takeException(), isNull);
        final generateLabel = find.descendant(
          of: find.byKey(const ValueKey('summary-generate')),
          matching: find.text('Summarize'),
        );
        expect(
          tester.renderObject<RenderParagraph>(generateLabel).didExceedMaxLines,
          isFalse,
        );
        expect(
          find.byType(NotionDialogFrame),
          scenario.platform == TargetPlatform.macOS
              ? findsOneWidget
              : findsNothing,
        );
        await _capture(tester, 'summary-${scenario.name}-settings');
        await tester.ensureVisible(
          find.byKey(const ValueKey('summary-provider-note')),
        );
        await _advance(tester);
        await _capture(tester, 'summary-${scenario.name}-settings-details');
        await _tap(tester, 'summary-generate');
        expect(tester.takeException(), isNull);
        expect(find.byType(SelectableText), findsOneWidget);
        await _capture(tester, 'summary-${scenario.name}-result');
        await _tap(tester, 'summary-close');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('number input remains reachable with the keyboard open', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await _open(
      tester,
      runner: (request, progress, cancellation) async => _result(),
    );
    await tester.tap(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await _advance(tester);
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '37');
    await _advance(tester);
    expect(find.text('37'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'summary-phone-keyboard');
    await _tap(tester, 'summary-close');
  });
}
