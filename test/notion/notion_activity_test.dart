// SPDX-License-Identifier: AGPL-3.0-or-later
// PF-08: decorative animation stops while the app is not in front of the
// user (unfocused macOS window, Android shade, hidden window) and resumes
// when it is; one-shot motion started meanwhile shows its end state.
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Probe extends StatelessWidget {
  const _Probe(this.seen);
  final List<(bool, bool)> seen;
  @override
  Widget build(BuildContext context) {
    seen.add((
      TickerMode.valuesOf(context).enabled,
      NotionMotion.reduced(context),
    ));
    return const SizedBox.shrink();
  }
}

Widget _app(Widget child, {ValueNotifier<bool>? visible}) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  builder: (context, app) =>
      NotionActivity(windowVisible: visible, child: app!),
  home: Scaffold(body: Center(child: child)),
);

double _opacity(WidgetTester tester, Finder finder) => tester
    .widgetList<FadeTransition>(
      find.ancestor(of: finder, matching: find.byType(FadeTransition)),
    )
    .fold(1.0, (value, fade) => value * fade.opacity.value);

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('inactive app: tickers off, reduced motion, loops idle', (
    tester,
  ) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final seen = <(bool, bool)>[];
    await tester.pumpWidget(
      _app(Column(children: [_Probe(seen), const NotionTypingDots()])),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(seen.last, (true, false));
    expect(binding.hasScheduledFrame, isTrue, reason: 'typing dots loop');

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(seen.last, (false, true));
    expect(binding.hasScheduledFrame, isFalse, reason: 'no idle frames');

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(seen.last, (true, false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(binding.hasScheduledFrame, isTrue, reason: 'loop resumed');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an entrance that starts while inactive is shown at once', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(
      _app(const NotionEntrance(afterRoute: false, child: Text('Fictional'))),
    );
    await tester.pump();
    expect(_opacity(tester, find.text('Fictional')), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a hidden window counts as inactive', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final seen = <(bool, bool)>[];
    await tester.pumpWidget(_app(_Probe(seen), visible: visible));
    expect(seen.last, (true, false));
    visible.value = false;
    await tester.pump();
    expect(seen.last, (false, true));
    visible.value = true;
    await tester.pump();
    expect(seen.last, (true, false));
  });

  testWidgets('scrolling an unfocused window animates for a grace period', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final seen = <(bool, bool)>[];
    await tester.pumpWidget(
      _app(SizedBox(width: 200, height: 200, child: _Probe(seen))),
    );
    expect(seen.last, (false, true));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byType(SizedBox).last)),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
    await tester.pump();
    expect(seen.last, (true, false));
    await tester.pump(NotionActivity.pointerGrace);
    await tester.pump();
    expect(seen.last, (false, true));
  });

  testWidgets('without a NotionActivity everything is active', (tester) async {
    final seen = <(bool, bool)>[];
    await tester.pumpWidget(MaterialApp(home: _Probe(seen)));
    expect(seen.last, (true, false));
  });

  testWidgets('power saving: lite mode reduces motion and turns glass off '
      'without stopping tickers or remounting the app', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final saving = ValueNotifier(false);
    addTearDown(saving.dispose);
    final seen = <(bool, bool)>[];
    final glass = <bool>[];
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        builder: (context, app) =>
            NotionActivity(powerSaving: saving, child: app!),
        home: Scaffold(
          body: Builder(
            key: key,
            builder: (context) {
              glass.add(
                NotionGlassScope.modeOf(context) == NotionGlassMode.off,
              );
              return _Probe(seen);
            },
          ),
        ),
      ),
    );
    final element = key.currentContext;
    expect(seen.last, (true, false));
    expect(glass.last, isFalse);

    saving.value = true;
    await tester.pump();
    expect(seen.last, (true, true), reason: 'tickers stay on, motion reduced');
    expect(glass.last, isTrue, reason: 'opaque glass tint');
    expect(identical(key.currentContext, element), isTrue);

    saving.value = false;
    await tester.pump();
    expect(seen.last, (true, false));
    expect(glass.last, isFalse);
  });
}
