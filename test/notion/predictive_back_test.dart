// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/routes.dart';
import 'package:chatloom/ui/notion/notion_motion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _back(
  WidgetTester tester,
  String method, [
  double? progress,
  int edge = 0,
]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  'flutter/backgesture',
  const StandardMethodCodec().encodeMethodCall(
    MethodCall(
      method,
      progress == null
          ? null
          : <String, Object?>{
              'touchOffset': <double>[edge == 0 ? 5 : 385, 300],
              'progress': progress,
              'swipeEdge': edge,
            },
    ),
  ),
  (_) {},
);

/// Visual state of the Notion page transition directly around [finder].
({double dx, double opacity, bool cover}) _frame(
  WidgetTester tester,
  Finder finder,
) {
  final transition = find
      .ancestor(of: finder, matching: find.byType(NotionPageTransition))
      .first;
  FractionalTranslation? translation;
  Opacity? opacity;
  DecoratedBox? box;
  void visit(Element e) {
    final w = e.widget;
    if (translation == null && w is FractionalTranslation) translation = w;
    if (opacity == null && w is Opacity) opacity = w;
    if (box == null && w is DecoratedBox) {
      box = w;
      return;
    }
    e.visitChildElements(visit);
  }

  tester.element(transition).visitChildElements(visit);
  final color = (box!.decoration as BoxDecoration).color;
  return (
    dx: translation!.translation.dx,
    opacity: opacity!.opacity,
    cover: color != null && color.a > 0,
  );
}

Future<GoRouter> _mount(
  WidgetTester tester, {
  Widget chat = const Scaffold(body: Text('Chat fixture')),
  bool disableAnimations = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Page page(BuildContext c, GoRouterState s, Widget child) =>
      AppRoutes.defaultPageBuilder(c, s, child);
  final router = GoRouter(
    initialLocation: '/rooms',
    routes: [
      // Like the app: an instant outer shell hosting the inbox navigator.
      ShellRoute(
        pageBuilder: AppRoutes.noTransitionPageBuilder,
        routes: [
          GoRoute(
            path: '/rooms',
            pageBuilder: (c, s) =>
                page(c, s, const Scaffold(body: Text('Inbox fixture'))),
            routes: [
              GoRoute(path: 'chat', pageBuilder: (c, s) => page(c, s, chat)),
            ],
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      theme: NotionTheme.build(Brightness.dark),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
    ),
  );
  await tester.pumpAndSettle();
  router.go('/rooms/chat');
  await tester.pumpAndSettle();
  return router;
}

const _frameTime = Duration(milliseconds: 16);
final _chat = find.text('Chat fixture');
final _inbox = find.text('Inbox fixture', skipOffstage: false);

/// Drags to [progress] in steps of .05 from [edge], one frame per step.
Future<void> _drag(WidgetTester tester, double progress, {int edge = 0}) async {
  await _back(tester, 'startBackGesture', 0, edge);
  await tester.pump(_frameTime);
  for (var p = .05; p <= progress + 1e-9; p += .05) {
    await _back(tester, 'updateBackGestureProgress', p, edge);
    await tester.pump(_frameTime);
  }
}

/// Pumps frames until the chat page is gone (or [max] frames) and returns
/// the top/under translations of every frame.
Future<List<(double, double)>> _frames(
  WidgetTester tester, {
  int max = 40,
}) async {
  final frames = <(double, double)>[];
  for (var i = 0; i < max; i++) {
    await tester.pump(_frameTime);
    if (_chat.evaluate().isEmpty) break;
    frames.add((_frame(tester, _chat).dx, _frame(tester, _inbox).dx));
  }
  return frames;
}

void main() {
  testWidgets('the page follows the finger, the page below slides back', (
    tester,
  ) async {
    await _mount(tester);
    await _drag(tester, .3);
    final top = _frame(tester, _chat);
    final under = _frame(tester, _inbox);
    expect(top.dx, closeTo(.3, 1e-6));
    expect(top.opacity, 1);
    expect(under.dx, closeTo(NotionMotion.parallaxOffset * .7, 1e-6));
    expect(under.cover, isTrue);
    await _back(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a committed gesture continues without any jump', (tester) async {
    final router = await _mount(tester);
    await _drag(tester, .3);
    final released = _frame(tester, _chat).dx;
    final releasedUnder = _frame(tester, _inbox).dx;
    await _back(tester, 'commitBackGesture');
    final frames = await _frames(tester);
    expect(frames, isNotEmpty);
    var lastTop = released;
    var lastUnder = releasedUnder;
    for (final (top, under) in frames) {
      // Monotonic: the top page only moves out, the page below only towards
      // its rest, and never past it (it used to overshoot by 9 % of the
      // width and snap back when the pop finished).
      expect(top, greaterThanOrEqualTo(lastTop - 1e-9));
      expect(under, greaterThanOrEqualTo(lastUnder - 1e-9));
      expect(under, lessThanOrEqualTo(1e-9));
      // Continuous: no frame moves more than a fifth of the width.
      expect(top - lastTop, lessThan(.2));
      expect(under - lastUnder, lessThan(.02));
      lastTop = top;
      lastUnder = under;
    }
    // The first frame after release starts where the finger left the page.
    expect(frames.first.$1 - released, lessThan(.12));
    expect(lastTop, greaterThan(.9), reason: 'the page leaves the screen');
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/rooms');
    final rest = _frame(tester, find.text('Inbox fixture'));
    expect(rest.dx, 0);
    expect(rest.cover, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a gesture from the right edge follows the finger leftwards', (
    tester,
  ) async {
    final router = await _mount(tester);
    await _drag(tester, .25, edge: 1);
    expect(_frame(tester, _chat).dx, closeTo(-.25, 1e-6));
    expect(_frame(tester, _inbox).dx, greaterThan(0));
    await _back(tester, 'commitBackGesture');
    final frames = await _frames(tester);
    var last = -.25;
    for (final (top, under) in frames) {
      expect(top, lessThanOrEqualTo(last + 1e-9));
      expect(under, greaterThanOrEqualTo(-1e-9));
      last = top;
    }
    expect(last, lessThan(-.9));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/rooms');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled gesture springs back to rest', (tester) async {
    final router = await _mount(tester);
    await _drag(tester, .4);
    // Android animates the progress back before it cancels; cancel early to
    // exercise the framework's own return.
    await _back(tester, 'cancelBackGesture');
    var last = _frame(tester, _chat).dx;
    for (var i = 0; i < 30; i++) {
      await tester.pump(_frameTime);
      final dx = _frame(tester, _chat).dx;
      expect(dx, lessThanOrEqualTo(last + 1e-9));
      expect(last - dx, lessThan(.2));
      last = dx;
    }
    await tester.pumpAndSettle();
    expect(_frame(tester, _chat).dx, 0);
    expect(_frame(tester, _chat).opacity, 1);
    expect(router.state.uri.path, '/rooms/chat');
    // The next gesture starts clean.
    await _drag(tester, .1);
    expect(_frame(tester, _chat).dx, closeTo(.1, 1e-6));
    await _back(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/rooms');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a vetoing PopScope gets no animation and its callback', (
    tester,
  ) async {
    var invoked = 0;
    final router = await _mount(
      tester,
      chat: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) invoked++;
        },
        child: const Scaffold(body: Text('Chat fixture')),
      ),
    );
    await _drag(tester, .3);
    expect(_frame(tester, _chat).dx, 0);
    expect(ModalRoute.of(tester.element(_chat))!.animation!.value, 1);
    await _back(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(invoked, 1);
    expect(router.state.uri.path, '/rooms/chat');
    expect(_frame(tester, _chat).dx, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back over a sheet closes only the sheet', (tester) async {
    final router = await _mount(tester);
    unawaited(
      showModalBottomSheet<void>(
        context: tester.element(_chat),
        builder: (_) => const SizedBox(height: 200, child: Text('Sheet')),
      ),
    );
    await tester.pumpAndSettle();
    await _drag(tester, .3);
    expect(_frame(tester, _chat).dx, 0);
    await _back(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('Sheet'), findsNothing);
    expect(router.state.uri.path, '/rooms/chat');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: no movement, release pops at once', (
    tester,
  ) async {
    final router = await _mount(tester, disableAnimations: true);
    await _drag(tester, .3);
    expect(_frame(tester, _chat).dx, 0);
    await _back(tester, 'commitBackGesture');
    await tester.pump();
    await tester.pump();
    expect(router.state.uri.path, '/rooms');
    expect(_chat, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
