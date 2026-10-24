// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/intro/intro_page.dart';
import 'package:chatloom/pages/sign_in/view_model/model/public_homeserver_data.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/oidc_session_json_extension.dart';
import 'package:chatloom/utils/sign_in_flows/check_homeserver.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix_api_lite/utils/logs.dart';
import 'package:matrix/msc_extensions/msc_2964_oidc_login_flow/msc_2964_oidc_login_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/universal_html.dart' as web;

class IntroPagePresenter extends StatefulWidget {
  const IntroPagePresenter({super.key});

  @override
  State<IntroPagePresenter> createState() => _IntroPagePresenterState();
}

class _IntroPagePresenterState extends State<IntroPagePresenter> {
  bool isLoading = kIsWeb;
  bool loginBusy = false;
  String? loggingInToHomeserver;

  @override
  void initState() {
    super.initState();

    if (kIsWeb) _finishOidcLogin();
  }

  Future<void> _finishOidcLogin() async {
    final store = await SharedPreferences.getInstance();
    final storedHomeserverString = store.getString(
      OidcSessionJsonExtension.homeserverStoreKey,
    );
    final homeserverUrl = storedHomeserverString == null
        ? null
        : Uri.tryParse(storedHomeserverString);

    final oidcSessionString = store.getString(
      OidcSessionJsonExtension.storeKey,
    );
    final session = oidcSessionString == null
        ? null
        : OidcSessionJsonExtension.fromJson(jsonDecode(oidcSessionString));

    await store.remove(OidcSessionJsonExtension.storeKey);
    await store.remove(OidcSessionJsonExtension.homeserverStoreKey);
    if (!mounted) return;

    if (homeserverUrl == null || session == null) {
      setState(() {
        isLoading = false;
      });

      return;
    }
    setState(() {
      loggingInToHomeserver = homeserverUrl.origin;
    });

    try {
      final returnUrl = Uri.parse(web.window.location.href);
      final queryParameters = returnUrl.hasFragment
          ? Uri.parse(returnUrl.fragment).queryParameters
          : returnUrl.queryParameters;
      final code = queryParameters['code'] as String;
      final state = queryParameters['state'] as String;

      final client = await Matrix.of(context).getLoginClient();
      await client.checkHomeserver(homeserverUrl);
      await client.oidcLogin(session: session, code: code, state: state);
      if (!mounted) return;
      context.go('/backup');
    } catch (e, s) {
      Logs().w('Unable to login via OIDC', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  /// "Sign in with Beeper": straight to the built-in default homeserver
  /// (matrix.beeper.com, or a preset/managed one), without the server
  /// picker. "Use another server" on the intro page keeps the picker.
  Future<void> _login() async {
    final presetHomeserver = AppSettings.presetHomeserver.value;
    final homeserver = presetHomeserver.isNotEmpty
        ? presetHomeserver
        : AppSettings.defaultHomeserver.defaultValue;
    try {
      await connectToHomeserverFlow(
        PublicHomeserverData(name: homeserver),
        context,
        (snapshot) {
          if (!mounted) return;
          setState(
            () =>
                loginBusy = snapshot.connectionState == ConnectionState.waiting,
          );
        },
        false,
      );
    } finally {
      // A declined consent dialog returns without a final state.
      if (mounted && loginBusy) setState(() => loginBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IntroPage(
      isLoading: isLoading,
      loggingInToHomeserver: loggingInToHomeserver,
      hasPresetHomeserver: AppSettings.presetHomeserver.value.isNotEmpty,
      welcomeText: AppSettings.welcomeText.value.isEmpty
          ? null
          : AppSettings.welcomeText.value,
      login: _login,
      loginBusy: loginBusy,
      addMultiAccount: Matrix.of(
        context,
      ).widget.clients.any((client) => client.isLogged()),
    );
  }
}
