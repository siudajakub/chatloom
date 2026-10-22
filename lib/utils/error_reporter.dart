import 'dart:async';

import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/privacy_transport.dart';
import 'package:chatloom/widgets/chatloom_app.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ErrorReporter {
  static String startupPhase = 'bindings';

  /// Set once the GUI runs (`startGui`). From then on, an uncaught error
  /// without a navigator (startup surface, app lock) is logged only: the
  /// fatal start screen would replace a working app (and its lock) with a
  /// dead one.
  static bool guiStarted = false;

  final BuildContext? context;
  final String? message;

  /// Offered as "Try again" when the failure [isRetryableError].
  final FutureOr<void> Function()? onRetry;

  /// The dialog's sentence for this failure; defaults to [humanErrorText].
  final ErrorAction action;

  const ErrorReporter(this.context, [this.message])
    : onRetry = null,
      action = ErrorAction.generic;

  /// A user action that can be repeated from the error dialog.
  const ErrorReporter.action(
    this.context, {
    this.message,
    this.onRetry,
    this.action = ErrorAction.generic,
  });
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
    // An uncaught server or connection failure comes from work nobody is
    // waiting for (sync, receipts, typing, pushers, key backup): log only.
    // Startup storage/crypto failures are never of this kind.
    if (isServerOrConnectionError(error)) return;
    final context =
        ChatLoomApp.router.routerDelegate.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      unawaited(ErrorReporter(context).reportUnhandled(error, stackTrace));
      return;
    }
    if (guiStarted) return;
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
    if (error is PrivacySuppressed) return;
    // Offline is shown by the connection banner; only an action that can be
    // repeated from here explains it.
    if (isPersonalNetworkFailure(error) && onRetry == null) return;
    if (unhandled && isServerOrConnectionError(error)) return;
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
          final retry = onRetry;
          return AlertDialog(
            title: const Text('Could not complete this action'),
            // A sentence, never the errcode or the diagnostic code; the
            // safe report stays one tap away for support.
            content: Text(humanErrorText(error, action: action)),
            actions: [
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: report)),
                child: const Text('Copy safe report'),
              ),
              if (retry != null && isRetryableError(error))
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    // A failed retry reports like the first attempt.
                    unawaited(
                      Future.sync(retry).then(
                        (_) {},
                        onError: (Object e, StackTrace s) =>
                            _report(e, s, unhandled: false),
                      ),
                    );
                  },
                  child: const Text('Try again'),
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
