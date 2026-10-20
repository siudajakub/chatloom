// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/privacy_transport.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

class _OpaqueType {}

class _RenamedClientException extends http.ClientException {
  _RenamedClientException() : super('synthetic private network details');
  @override
  Type get runtimeType => _OpaqueType;
}

class _RenamedPrivacySuppressed extends PrivacySuppressed {
  const _RenamedPrivacySuppressed();
  @override
  Type get runtimeType => _OpaqueType;
}

void main() {
  test('network diagnostics use the actual exception type after renaming', () {
    final error = _RenamedClientException();
    expect(error, isA<http.ClientException>());
    expect(error.runtimeType.toString(), isNot('ClientException'));
    expect(
      PersonalDiagnostic.from(error, PersonalFailurePhase.action).code,
      'network_unavailable',
    );
    expect(
      privateSyncFailure(error, PersonalFailurePhase.journalReplay),
      PrivateSyncFailure.offline,
    );
  });

  test('privacy suppression retains its fixed diagnostic after renaming', () {
    const error = _RenamedPrivacySuppressed();
    expect(error, isA<PrivacySuppressed>());
    expect(error.runtimeType.toString(), isNot('PrivacySuppressed'));
    expect(
      PersonalDiagnostic.from(error, PersonalFailurePhase.action).code,
      'privacy_suppressed',
    );
  });

  for (final entry in <String, Object>{
    'network': _RenamedClientException(),
    'privacy': const _RenamedPrivacySuppressed(),
  }.entries) {
    testWidgets('renamed ${entry.key} failure does not open an action modal', (
      tester,
    ) async {
      late BuildContext reportContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                reportContext = context;
                return const Text('Fixture ready');
              },
            ),
          ),
        ),
      );
      var completed = false;
      unawaited(
        ErrorReporter(
          reportContext,
        ).onErrorCallback(entry.value).then((_) => completed = true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(completed, isTrue);
      expect(find.text('Fixture ready'), findsOneWidget);
    });
  }

  testWidgets(
    'global renamed privacy suppression preserves the mounted shell',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Fixture shell stays mounted')),
        ),
      );
      ErrorReporter.onFlutterError(const _RenamedPrivacySuppressed());
      await tester.pumpAndSettle();
      expect(find.text('Fixture shell stays mounted'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text('Could not start the app. Your data and keys are preserved.'),
        findsNothing,
      );
    },
  );

  for (final error in <Object>[
    StateError('synthetic private operation details'),
    const FileSystemException(
      'synthetic private storage details',
      '/fictional/private/path',
    ),
  ]) {
    testWidgets('${error.runtimeType} still opens a safe actionable error', (
      tester,
    ) async {
      late BuildContext reportContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                reportContext = context;
                return const Text('Fixture ready');
              },
            ),
          ),
        ),
      );
      var completed = false;
      unawaited(
        ErrorReporter(
          reportContext,
        ).onErrorCallback(error).then((_) => completed = true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Could not complete this action'), findsOneWidget);
      expect(find.text('Copy safe report'), findsOneWidget);
      expect(completed, isFalse);
      expect(find.text('synthetic private operation details'), findsNothing);
      expect(find.text('synthetic private storage details'), findsNothing);
      expect(find.textContaining('/fictional/private/path'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(completed, isTrue);
    });
  }
}
