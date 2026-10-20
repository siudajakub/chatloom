import 'dart:async';

import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/privacy_transport.dart';
import 'package:chatloom/widgets/chatloom_app.dart';
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
        ChatLoomApp.router.routerDelegate.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      unawaited(ErrorReporter(context).reportUnhandled(error, stackTrace));
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

  /// Only one error dialog is ever open: a widget that throws on every
  /// frame must not stack modals until nothing on screen takes touches.
  static BuildContext? _dialogHost;
  static BuildContext? _dialogContext;
  static String? _lastUnhandledCode;
  static DateTime? _lastUnhandledAt;

  /// An uncaught error repeating its diagnostic within this window is
  /// logged but not shown again.
  @visibleForTesting
  static Duration unhandledRepeatWindow = const Duration(seconds: 30);

  @visibleForTesting
  static void debugReset() {
    _dialogHost = null;
    _dialogContext = null;
    _lastUnhandledCode = null;
    _lastUnhandledAt = null;
  }

  Future<void> onErrorCallback(Object error, [StackTrace? stackTrace]) =>
      _report(error, stackTrace, unhandled: false);

  /// Uncaught framework and zone errors: same dialog as an action failure,
  /// but a repeat of the last one is not shown again within
  /// [unhandledRepeatWindow].
  @visibleForTesting
  Future<void> reportUnhandled(Object error, [StackTrace? stackTrace]) =>
      _report(error, stackTrace, unhandled: true);

  Future<void> _report(
    Object error,
    StackTrace? stackTrace, {
    required bool unhandled,
  }) async {
    final phase = message == 'Unable to load timeline'
        ? PersonalFailurePhase.timelineLoad
        : PersonalFailurePhase.action;
    final diagnostic = PersonalDiagnostic.from(error, phase);
    Logs().e('operation_failed', diagnostic.code);
    if (error is PrivacySuppressed || isPersonalNetworkFailure(error)) return;
    final c =
        context ??
        ChatLoomApp.router.routerDelegate.navigatorKey.currentContext;
    if (c == null || !c.mounted) return;
    // The open dialog itself, not the page that opened it: a root dialog
    // outlives its host page. Before its first build, the host stands in.
    if ((_dialogContext?.mounted ?? false) ||
        (_dialogContext == null && (_dialogHost?.mounted ?? false))) {
      return;
    }
    if (unhandled) {
      final now = DateTime.now();
      final last = _lastUnhandledAt;
      if (_lastUnhandledCode == diagnostic.code &&
          last != null &&
          now.difference(last) < unhandledRepeatWindow) {
        return;
      }
      _lastUnhandledCode = diagnostic.code;
      _lastUnhandledAt = now;
    }
    final report = diagnostic.report(stackTrace);
    _dialogHost = c;
    _dialogContext = null;
    try {
      await _showDialog(c, error, report);
    } finally {
      if (identical(_dialogHost, c)) {
        _dialogHost = null;
        _dialogContext = null;
      }
    }
  }

  Future<void> _showDialog(BuildContext c, Object error, String report) =>
      showDialog<void>(
        context: c,
        builder: (context) {
          _dialogContext = context;
          return AlertDialog(
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
          );
        },
      );
}
