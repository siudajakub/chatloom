// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Startup surfaces render with the stored Notion theme on their first frame,
/// so the hand-off to [FluffyChatApp] does not flash an unthemed Material app.
class _StartupApp extends StatelessWidget {
  final SharedPreferences store;
  final Widget home;
  const _StartupApp({required this.store, required this.home});

  @override
  Widget build(BuildContext context) => ThemeBuilder(
    preferences: store,
    builder: (context, themeMode, primaryColor) => MaterialApp(
      themeMode: themeMode,
      theme: FluffyThemes.buildTheme(context, Brightness.light, primaryColor),
      darkTheme: FluffyThemes.buildTheme(
        context,
        Brightness.dark,
        primaryColor,
      ),
      home: home,
    ),
  );
}

/// A lock lookup failure cannot be treated as an unset lock.
class StartupLockFailureView extends StatefulWidget {
  final Future<void> Function() retry;
  final SharedPreferences store;
  const StartupLockFailureView({
    super.key,
    required this.retry,
    required this.store,
  });
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
  Widget build(BuildContext context) => _StartupApp(
    store: widget.store,
    home: Scaffold(
      body: SafeArea(
        child: NotionEmptyState(
          icon: Icons.lock_outline,
          title:
              'Could not read the app lock. Your data and keys are preserved.',
          message: 'Unlock your device and retry.',
          action: NotionButton(
            label: _busy ? 'Retrying…' : 'Retry app lock',
            busy: _busy,
            onPressed: _retry,
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
      final restoring = startup.busy && !startup.hasFailures;
      return _StartupApp(
        store: startup.store,
        home: AppLockWidget(
          pincode: appLockSettings.pincode,
          useBiometrics: appLockSettings.useBiometrics,
          // A failed restore must not bypass an existing app lock.
          isLoggedIn: true,
          // Skeleton → failure surface fade through; never a hard cut.
          child: NotionFadeThrough(
            child: restoring
                ? const ClientStartupSkeleton(key: ValueKey('restoring'))
                : Scaffold(
                    key: const ValueKey('failed'),
                    body: SafeArea(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            const NotionEmptyState(
                              icon: Icons.lock_outline,
                              title: 'Could not restore your accounts.',
                              message:
                                  'Your saved accounts, data and keys are preserved. Unlock your device and retry. Keep app data.',
                            ),
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

/// Inbox-shaped placeholder while saved accounts open: the same header,
/// gutter and row geometry as the inbox, without content. The bars shimmer
/// slowly (a static fill under reduced motion); the header stays real.
class ClientStartupSkeleton extends StatelessWidget {
  const ClientStartupSkeleton({super.key});

  static const label = 'Restoring saved accounts…';

  // Name and preview widths per row, as fractions of the text column.
  static const _widths = [
    (0.42, 0.78),
    (0.55, 0.64),
    (0.36, 0.85),
    (0.48, 0.7),
    (0.6, 0.58),
    (0.4, 0.8),
    (0.52, 0.66),
    (0.45, 0.74),
    (0.38, 0.82),
    (0.5, 0.6),
    (0.44, 0.72),
    (0.57, 0.68),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Semantics(
          liveRegion: true,
          label: label,
          child: ExcludeSemantics(
            child: NotionSkeleton(
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  NotionSpace.inset,
                  NotionSpace.xs,
                  NotionSpace.inset,
                  0,
                ),
                children: [
                  NotionSkeleton.keep(
                    SizedBox(
                      height: NotionSize.touchTarget,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text('Chats', style: tokens.typography.title),
                      ),
                    ),
                  ),
                  NotionSkeleton.keep(
                    Padding(
                      padding: const EdgeInsets.only(
                        top: NotionSpace.xxs,
                        bottom: NotionSpace.md,
                      ),
                      child: Text(
                        label,
                        style: tokens.typography.footnoteMuted,
                      ),
                    ),
                  ),
                  for (final (name, preview) in _widths)
                    _SkeletonRow(name: name, preview: preview),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  final double name;
  final double preview;
  const _SkeletonRow({required this.name, required this.preview});

  @override
  Widget build(BuildContext context) {
    final fill = context.notion.colors.surface;
    // Each bar is one shimmering bone.
    Widget bone(Widget child) => NotionSkeleton.unite(child);
    Widget bar(double width, double height) => FractionallySizedBox(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: width,
      child: bone(
        Container(
          height: height,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: NotionRadius.smAll,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
      child: Row(
        children: [
          bone(
            Container(
              width: NotionSize.avatar,
              height: NotionSize.avatar,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: NotionRadius.smAll,
              ),
            ),
          ),
          const SizedBox(width: NotionSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(name, NotionSize.iconSm),
                const SizedBox(height: NotionSpace.xs),
                bar(preview, NotionSpace.sm),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
          padding: const EdgeInsets.symmetric(
            horizontal: NotionSpace.md,
            vertical: NotionSpace.xs,
          ),
          child: Wrap(
            spacing: NotionSpace.sm,
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
                child: NotionFadeThrough(
                  alignment: Alignment.center,
                  child: Text(
                    startup.busy ? 'Retrying…' : 'Retry account restore',
                    key: ValueKey(startup.busy),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
