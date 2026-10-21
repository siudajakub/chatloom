// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

MatrixException _unknown() => MatrixException(
  http.Response('{"errcode":"M_UNKNOWN","error":"M_UNKNOWN"}', 500),
);

void main() {
  setUp(ErrorReporter.debugReset);

  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const Text('Fixture ready');
            },
          ),
        ),
      ),
    );
    return context;
  }

  testWidgets('an error repeating every frame opens one dialog, not a stack', (
    tester,
  ) async {
    final context = await host(tester);
    for (var i = 0; i < 5; i++) {
      unawaited(ErrorReporter(context).reportUnhandled(StateError('frame')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    // The same uncaught error right after closing stays in the log only.
    unawaited(ErrorReporter(context).reportUnhandled(StateError('frame')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Fixture ready'), findsOneWidget);
  });

  testWidgets('an explicit action failure still reports after a repeat', (
    tester,
  ) async {
    final context = await host(tester);
    unawaited(ErrorReporter(context).reportUnhandled(StateError('frame')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    unawaited(ErrorReporter(context).onErrorCallback(StateError('action')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // While it is open, another failure does not stack a second modal.
    unawaited(ErrorReporter(context).onErrorCallback(StateError('again')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('a dialog lost with its tree does not block the next one', (
    tester,
  ) async {
    final first = await host(tester);
    unawaited(ErrorReporter(first).onErrorCallback(StateError('one')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    final second = await host(tester);
    unawaited(ErrorReporter(second).onErrorCallback(StateError('two')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('a root dialog that outlives its host page still blocks', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('Home')),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) {
          page = context;
          return const Text('Page');
        },
      ),
    );
    await tester.pumpAndSettle();
    unawaited(ErrorReporter(page).onErrorCallback(StateError('one')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // The page under the root dialog goes away; the dialog stays.
    navigator.currentState!.removeRoute(ModalRoute.of(page)!);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final home = navigator.currentContext!;
    unawaited(ErrorReporter(home).onErrorCallback(StateError('two')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('an uncaught Matrix error is logged, never a modal', (
    tester,
  ) async {
    final context = await host(tester);
    unawaited(ErrorReporter(context).reportUnhandled(_unknown()));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    // The zone/framework entry point keeps the shell, too.
    ErrorReporter.onFlutterError(_unknown());
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Fixture ready'), findsOneWidget);
    expect(find.textContaining('Could not start the app'), findsNothing);
  });

  testWidgets('a failed action explains itself without the errcode', (
    tester,
  ) async {
    final context = await host(tester);
    unawaited(ErrorReporter(context).onErrorCallback(_unknown()));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Something went wrong. Try again.'), findsOneWidget);
    expect(find.textContaining('M_UNKNOWN'), findsNothing);
    expect(find.textContaining('matrix_m_unknown'), findsNothing);
    expect(find.text('Copy safe report'), findsOneWidget);
    // No retry callback: no retry button.
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a retryable action offers Try again once', (tester) async {
    final context = await host(tester);
    var retries = 0;
    unawaited(
      ErrorReporter.action(
        context,
        action: ErrorAction.send,
        onRetry: () => retries++,
      ).onErrorCallback(_unknown()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t send. Try again.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a final failure offers no retry', (tester) async {
    final context = await host(tester);
    unawaited(
      ErrorReporter.action(context, onRetry: () {}).onErrorCallback(
        MatrixException(http.Response('{"errcode":"M_FORBIDDEN"}', 403)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('You don’t have permission to do that.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
