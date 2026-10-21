// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One inbox owns search, including while the composer in the other column
/// has focus. A replaced inbox cannot unregister its successor's callback.
abstract final class MacDesktopCommands {
  static Object? _owner;
  static VoidCallback? _search;

  static void bindSearch(Object owner, VoidCallback search) {
    _owner = owner;
    _search = search;
  }

  static void unbindSearch(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _search = null;
  }

  static void search() {
    if (PersonalPrivacy.surfaceUnlocked) _search?.call();
  }
}

class MacDesktopIntegration extends StatefulWidget {
  final Widget child;
  final VoidCallback onSettings;
  final VoidCallback onWake;
  const MacDesktopIntegration({
    super.key,
    required this.child,
    required this.onSettings,
    required this.onWake,
  });

  @override
  State<MacDesktopIntegration> createState() => _MacDesktopIntegrationState();
}

class _MacDesktopIntegrationState extends State<MacDesktopIntegration> {
  static const _channel = MethodChannel('pl.personal.chat/desktop');
  static Object? _owner;

  void _settings() {
    if (PersonalPrivacy.surfaceUnlocked) widget.onSettings();
  }

  @override
  void initState() {
    super.initState();
    if (!PlatformInfos.isMacOS) return;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'search':
          MacDesktopCommands.search();
        case 'settings':
          _settings();
        case 'wake':
          widget.onWake();
      }
    });
  }

  @override
  void dispose() {
    if (identical(_owner, this)) {
      _owner = null;
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformInfos.isMacOS
      ? CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                MacDesktopCommands.search,
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                MacDesktopCommands.search,
            const SingleActivator(LogicalKeyboardKey.comma, meta: true):
                _settings,
          },
          child: widget.child,
        )
      : widget.child;
}
