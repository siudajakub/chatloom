import 'dart:async';

import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/diagnostics.dart';
import 'package:fluffychat/personal/privacy_transport.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ErrorReporter {
  static String startupPhase = 'bindings';

  final BuildContext? context;
  final String? message;
  const ErrorReporter(this.context, [this.message]);
  static void onFlutterError(Object error, [StackTrace? stackTrace]) {
    final phase = switch (startupPhase) {
      'bindings' => PersonalFailurePhase.bindings,
      'settings' => PersonalFailurePhase.settings,
      'crypto' => PersonalFailurePhase.crypto,
      'background_clients' => PersonalFailurePhase.backgroundClients,
      'clients' => PersonalFailurePhase.clients,
      'gui' => PersonalFailurePhase.gui,
      _ => PersonalFailurePhase.action,
    };
    final diagnostic = PersonalDiagnostic.from(error, phase);
    debugPrint(diagnostic.report(stackTrace));
    Logs().e('application_error', diagnostic.code);
    if (error is PrivacySuppressed) return;
    final context =
        FluffyChatApp.router.routerDelegate.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      unawaited(ErrorReporter(context).onErrorCallback(error, stackTrace));
      return;
    }
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 40),
                    const SizedBox(height: 16),
                    const Text(
                      'Could not start the app. Your data and keys are preserved.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Unlock your device and reopen the app. Keep app data to preserve your drafts and keys.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> onErrorCallback(Object error, [StackTrace? stackTrace]) async {
    final phase = message == 'Unable to load timeline'
        ? PersonalFailurePhase.timelineLoad
        : PersonalFailurePhase.action;
    final diagnostic = PersonalDiagnostic.from(error, phase);
    Logs().e('operation_failed', diagnostic.code);
    if (error is PrivacySuppressed || isPersonalNetworkFailure(error)) return;
    final c =
        context ??
        FluffyChatApp.router.routerDelegate.navigatorKey.currentContext;
    if (c == null || !c.mounted) return;
    final report = diagnostic.report(stackTrace);
    await showDialog<void>(
      context: c,
      builder: (context) => AlertDialog(
        title: const Text('Could not complete this action'),
        content: Text(
          error is PersonalCapabilityUnavailable ? error.reason : report,
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            child: const Text('Copy safe report'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
