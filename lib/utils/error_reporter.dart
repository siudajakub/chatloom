import 'dart:async';

import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/storage/storage_failure.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ErrorReporter {
  static String startupPhase = 'bindings';

  final BuildContext? context;
  final String? message;
  const ErrorReporter(this.context, [this.message]);
  static const Set<String> ingoredTypes = {
    'IOException',
    'ClientException',
    'SocketException',
    'TlsException',
    'HandshakeException',
    'PrivacySuppressed',
  };
  static void onFlutterError(Object error, [StackTrace? stackTrace]) {
    final code = error is StorageFailure
        ? error.code.name
        : error.runtimeType.toString();
    debugPrint('personal_startup_error phase=$startupPhase code=$code');
    final frames = RegExp(
      r'#\d+\s+[^\s]+\s+\(package:[^)]*\)',
    ).allMatches(stackTrace?.toString() ?? '').take(8);
    for (final frame in frames) {
      debugPrint('personal_startup_frame ${frame.group(0)}');
    }
    Logs().e('application_error', error.runtimeType.toString());
    if (error.runtimeType.toString() == 'PrivacySuppressed') return;
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
    Logs().e('operation_failed', error.runtimeType.toString());
    if (ingoredTypes.contains(error.runtimeType.toString())) return;
    final c =
        context ??
        FluffyChatApp.router.routerDelegate.navigatorKey.currentContext;
    if (c == null || !c.mounted) return;
    // Release web runtime names are minified. Never include raw exception text,
    // which can contain message content, IDs, URLs or credentials.
    const knownStates = <String, String>{
      'No element': 'empty_result',
      'Too many elements': 'ambiguous_result',
      'A signed-in account is required': 'account_unavailable',
      'Private client is closed': 'client_closed',
      'Encrypted outbox unavailable': 'outbox_unavailable',
      'Private encrypted sync is not connected': 'private_sync_disconnected',
      'Journal synchronization is incomplete': 'journal_incomplete',
      'Invalid encrypted journal': 'journal_invalid',
      'Unsafe journal membership': 'journal_membership_untrusted',
      'Journal history pagination stalled': 'journal_history_stalled',
      'Journal history exceeds safe pagination limit': 'journal_history_limit',
    };
    final code = error.toString() == 'Null check operator used on a null value'
        ? 'missing_value'
        : error is TypeError
        ? 'invalid_data_type'
        : error is StateError
        ? knownStates[error.message] ?? 'invalid_state'
        : 'operation_failed';
    final frames =
        RegExp(
              r'(?:main\.dart\.js(?:_\d+\.part\.js)?|[A-Za-z_]\w*\.dart):\d+(?::\d+)?',
            )
            .allMatches(stackTrace?.toString() ?? '')
            .map((match) => match.group(0)!)
            .toSet()
            .take(8)
            .join('\n');
    final phase = message == 'Unable to load timeline'
        ? ' [timeline_load]'
        : '';
    final report =
        'Personal Chat: $code (${error.runtimeType})$phase'
        '${frames.isEmpty ? '' : '\n$frames'}';
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
            child: const Text('Kopiuj bezpieczny raport'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zamknij'),
          ),
        ],
      ),
    );
  }
}
