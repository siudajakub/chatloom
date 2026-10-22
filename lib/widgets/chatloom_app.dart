// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/routes.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/ui/keyboard_shortcuts_sheet.dart';
import 'package:chatloom/ui/notion/notion_activity.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/client_startup.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/custom_scroll_behaviour.dart';
import 'matrix.dart';

class ChatLoomApp extends StatelessWidget {
  final Widget? testWidget;
  final List<Client> clients;
  final ({String? pincode, bool useBiometrics}) appLockSettings;
  final SharedPreferences store;
  final ClientStartup? startup;

  /// The app lock shared with the startup surface; without it the app's
  /// [AppLockWidget] builds its own from [appLockSettings].
  final AppLockController? appLock;

  const ChatLoomApp({
    super.key,
    this.testWidget,
    required this.clients,
    required this.store,
    required this.appLockSettings,
    this.startup,
    this.appLock,
  });

  /// getInitialLink may rereturn the value multiple times if this view is
  /// opened multiple times for example if the user logs out after they logged
  /// in with qr code or magic link.
  static bool gotInitialLink = false;

  // Router must be outside of build method so that hot reload does not reset
  // the current path.
  static final GoRouter router = GoRouter(
    routes: AppRoutes.routes,
    debugLogDiagnostics: kDebugMode,
    redirect: (context, state) {
      // Workaround for content sharings passed to go router:
      if ({
        'content',
        'sharemedia-im.fluffychat.app',
      }.contains(state.uri.scheme)) {
        Logs().d('Ignore content sharing handling in go router', state.uri);
        return '/';
      }

      // Pass deep links to app:
      if (state.uri.toString().startsWith(AppConfig.deepLinkPrefix)) {
        return '/rooms/newprivatechat#${state.uri}';
      }
      return null;
    },
  );

  @override
  Widget build(BuildContext context) {
    return ThemeBuilder(
      preferences: store,
      builder: (context, themeMode, appearance) => MaterialApp.router(
        title: AppSettings.applicationName.value,
        themeMode: themeMode,
        theme: ChatLoomThemes.buildTheme(context, Brightness.light, appearance),
        darkTheme: ChatLoomThemes.buildTheme(
          context,
          Brightness.dark,
          appearance,
        ),
        scrollBehavior: CustomScrollBehavior(),
        localizationsDelegates: [
          ...L10n.localizationsDelegates,
          ...GlobalMaterialLocalizations.delegates,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        locale: AppConfig.appLocale,
        supportedLocales: const [AppConfig.appLocale],
        routerConfig: router,
        // Decorative animation pauses while the app is not in front of the
        // user (PF-08); sync and sending are unaffected.
        builder: (context, child) => NotionActivity(
          windowVisible: PlatformInfos.isMacOS
              ? MacDesktopWindow.visible
              : null,
          child: AppLockWidget(
            controller: appLock,
            pincode: appLockSettings.pincode,
            useBiometrics: appLockSettings.useBiometrics,
            isLoggedIn: clients.any((client) => client.isLogged()),
            // Need a navigator above the Matrix widget for
            // displaying dialogs
            child: MacDesktopIntegration(
              onSettings: () {
                if (clients.any((client) => client.isLogged())) {
                  router.go('/rooms/settings');
                }
              },
              onShortcutsHelp: () {
                final navigator =
                    router.routerDelegate.navigatorKey.currentContext;
                if (navigator != null) showKeyboardShortcutsSheet(navigator);
              },
              onWake: () {
                for (final client in clients.where(
                  (client) => client.isLogged(),
                )) {
                  client.restartSync().catchError((Object _) {});
                }
              },
              child: Matrix(
                clients: clients,
                store: store,
                child: Column(
                  children: [
                    if (startup != null) ClientStartupNotice(startup: startup!),
                    Expanded(
                      child: testWidget ?? child ?? const SizedBox.shrink(),
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
}
