// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:material_ui/material_ui.dart';

/// A lock lookup failure cannot be treated as an unset lock.
class StartupLockFailureView extends StatefulWidget {
  final Future<void> Function() retry;
  const StartupLockFailureView({super.key, required this.retry});
  @override
  State<StartupLockFailureView> createState() => _StartupLockFailureViewState();
}

class _StartupLockFailureViewState extends State<StartupLockFailureView> {
  bool _busy = false;
  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await widget.retry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
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
                  'Could not read the app lock. Your data and keys are preserved.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Unlock your device and retry.',
                  textAlign: TextAlign.center,
                ),
                TextButton(
                  onPressed: _busy ? null : _retry,
                  child: Text(_busy ? 'Retrying…' : 'Retry app lock'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ClientStartupView extends StatelessWidget {
  final ClientStartup startup;
  final ({String? pincode, bool useBiometrics}) appLockSettings;
  const ClientStartupView({
    super.key,
    required this.startup,
    required this.appLockSettings,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: startup,
    builder: (context, _) {
      if (startup.clients.isNotEmpty) {
        return FluffyChatApp(
          clients: startup.clients,
          store: startup.store,
          appLockSettings: appLockSettings,
          startup: startup,
        );
      }
      return MaterialApp(
        home: AppLockWidget(
          pincode: appLockSettings.pincode,
          useBiometrics: appLockSettings.useBiometrics,
          // A failed restore must not bypass an existing app lock.
          isLoggedIn: true,
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 40),
                      const SizedBox(height: 16),
                      Text(
                        startup.busy && !startup.hasFailures
                            ? 'Restoring saved accounts…'
                            : 'Could not restore your accounts.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      if (startup.busy && !startup.hasFailures)
                        const CircularProgressIndicator(),
                      const Text(
                        'Your saved accounts, data and keys are preserved. Unlock your device and retry. Keep app data.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ClientStartupNotice(startup: startup),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Account names and error objects are intentionally absent from this surface.
class ClientStartupNotice extends StatelessWidget {
  final ClientStartup startup;
  const ClientStartupNotice({super.key, required this.startup});
  @override
  Widget build(BuildContext context) {
    if (!startup.hasFailures) return const SizedBox.shrink();
    final registry = startup.registryFailure != null;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                registry
                    ? 'Saved account registry could not be read. No data was reset.'
                    : '${startup.failedCount} saved account(s) could not be restored. Data and keys are preserved.',
              ),
              TextButton(
                onPressed: startup.busy
                    ? null
                    : () => unawaited(startup.restore()),
                child: Text(
                  startup.busy ? 'Retrying…' : 'Retry account restore',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
