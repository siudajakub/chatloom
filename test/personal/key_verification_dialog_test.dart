// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/key_verification/key_verification_dialog.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

class _Client extends Fake implements Client {
  @override
  Future<Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) async => Profile(userId: userId);

  @override
  String? getDirectChatFromUserId(String userId) => null;
}

/// A verification whose remote side the test drives.
class _Request extends Fake implements KeyVerification {
  _Request({required this.state, this.startedVerification = false});

  @override
  KeyVerificationState state;
  @override
  bool startedVerification;
  @override
  void Function()? onUpdate;
  @override
  String? canceledCode;
  @override
  String? canceledReason;
  @override
  final Client client = _Client();
  @override
  final String userId = '@fixture:example.invalid';
  @override
  List<String> get sasTypes => const ['emoji'];

  final sentCancels = <String>[];

  /// The other device sends `m.key.verification.cancel` (as an older
  /// ChatLoom/FluffyChat does with the SDK default code).
  void remoteCancel(String code) {
    canceledCode = code;
    canceledReason = code;
    state = KeyVerificationState.error;
    onUpdate?.call();
  }

  @override
  Future<void> cancel([String code = 'm.unknown', bool quiet = false]) async {
    sentCancels.add(code);
    canceledCode = code;
    state = KeyVerificationState.error;
    onUpdate?.call();
  }

  @override
  Future<void> rejectVerification() => cancel('m.user');

  /// Accepts that fail before one succeeds (the server is unreachable).
  int acceptFailures = 0;

  @override
  Future<void> acceptVerification() async {
    if (acceptFailures > 0) {
      acceptFailures--;
      throw MatrixException.fromJson({
        'errcode': 'M_UNKNOWN',
        'error': 'M_UNKNOWN',
      });
    }
    state = KeyVerificationState.waitingSas;
    onUpdate?.call();
  }
}

/// Waiting states spin forever, so a fixed time instead of pumpAndSettle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester, _Request request) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: const Scaffold(body: Text('Home')),
    ),
  );
  // Localizations load asynchronously before the first real frame.
  await _settle(tester);
  unawaited(
    KeyVerificationDialog(request: request).show(navigator.currentContext!),
  );
  await _settle(tester);
}

void main() {
  testWidgets(
    'an unanswered incoming request cancelled by the other device goes away',
    (tester) async {
      final request = _Request(state: KeyVerificationState.askAccept);
      await _open(tester, request);
      expect(find.byType(KeyVerificationDialog), findsOneWidget);

      request.remoteCancel('m.unknown');
      await _settle(tester);
      expect(find.byType(KeyVerificationDialog), findsNothing);
      expect(find.textContaining('m.unknown'), findsNothing);
      expect(find.textContaining('Error'), findsNothing);
      // Nothing is sent back for a request that already ended.
      expect(request.sentCancels, isEmpty);
      expect(find.text('Home'), findsOneWidget);
    },
  );

  testWidgets('another own device answering also closes it', (tester) async {
    final request = _Request(state: KeyVerificationState.askAccept);
    await _open(tester, request);
    request.remoteCancel('m.accepted');
    await _settle(tester);
    expect(find.byType(KeyVerificationDialog), findsNothing);
  });

  testWidgets('a verification the user started explains why it stopped', (
    tester,
  ) async {
    final request = _Request(
      state: KeyVerificationState.waitingAccept,
      startedVerification: true,
    );
    await _open(tester, request);
    request.remoteCancel('m.unknown');
    await _settle(tester);
    expect(find.byType(KeyVerificationDialog), findsOneWidget);
    expect(find.text('Verification stopped'), findsOneWidget);
    expect(find.text('Verification was cancelled.'), findsOneWidget);
    expect(find.textContaining('m.unknown'), findsNothing);
    expect(find.textContaining('null'), findsNothing);
  });

  testWidgets('an accepted request that fails shows the human reason', (
    tester,
  ) async {
    final request = _Request(state: KeyVerificationState.askAccept);
    await _open(tester, request);
    await tester.tap(find.text(L10n.of(_context(tester)).accept));
    await _settle(tester);
    request.remoteCancel('m.mismatched_sas');
    await _settle(tester);
    expect(find.byType(KeyVerificationDialog), findsOneWidget);
    expect(
      find.textContaining('The security codes didn’t match'),
      findsOneWidget,
    );
  });

  testWidgets('Cancel tells the other device the user cancelled', (
    tester,
  ) async {
    final request = _Request(
      state: KeyVerificationState.waitingAccept,
      startedVerification: true,
    );
    await _open(tester, request);
    await tester.tap(find.text(L10n.of(_context(tester)).cancel));
    await _settle(tester);
    expect(request.sentCancels, ['m.user']);
  });

  testWidgets('a step that cannot reach the server explains and retries', (
    tester,
  ) async {
    final request = _Request(state: KeyVerificationState.askAccept)
      ..acceptFailures = 1;
    await _open(tester, request);
    await tester.tap(find.text(L10n.of(_context(tester)).accept));
    await _settle(tester);
    // Before wave 4 this reached the global dialog; now the step reports.
    expect(find.text('Could not complete this action'), findsOneWidget);
    expect(find.textContaining('M_UNKNOWN'), findsNothing);
    await tester.tap(find.text('Try again'));
    await _settle(tester);
    expect(find.text('Could not complete this action'), findsNothing);
    expect(request.state, KeyVerificationState.waitingSas);
  });

  testWidgets('Reject closes the dialog exactly once', (tester) async {
    final request = _Request(state: KeyVerificationState.askAccept);
    await _open(tester, request);
    await tester.tap(find.text(L10n.of(_context(tester)).reject));
    await _settle(tester);
    expect(request.sentCancels, ['m.user']);
    expect(find.byType(KeyVerificationDialog), findsNothing);
    // The page under the dialog is still there (no double pop).
    expect(find.text('Home'), findsOneWidget);
  });
}

BuildContext _context(WidgetTester tester) =>
    tester.element(find.byType(KeyVerificationDialog));
