// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/layouts/login_scaffold.dart';
import 'package:material_ui/material_ui.dart';

import 'login.dart';

class LoginView extends StatelessWidget {
  final LoginController controller;

  const LoginView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    var order = 0;
    Widget enter(Widget child) => NotionEntrance(
      index: order++,
      rise: NotionMotion.riseList,
      child: child,
    );

    final homeserver = controller.widget.client.homeserver
        ?.toString()
        .replaceFirst('https://', '');
    final isBeeper =
        controller.widget.client.homeserver?.host.endsWith('beeper.com') ??
        false;
    final title = homeserver == null
        ? 'Sign in with a Matrix ID'
        : isBeeper
        ? 'Sign in to Beeper'
        : L10n.of(context).logInTo(homeserver);

    return LoginScaffold(
      appBar: AppBar(
        leading: controller.loading ? null : const Center(child: BackButton()),
        automaticallyImplyLeading: !controller.loading,
        titleSpacing: !controller.loading ? 0 : null,
        title: Text(title),
      ),
      body: Builder(
        builder: (context) {
          return AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: NotionSpace.xl,
                vertical: NotionSpace.md,
              ),
              children: <Widget>[
                // The logo flies in as a Hero from the intro page.
                Center(
                  child: Hero(
                    tag: 'info-logo',
                    child: ClipOval(
                      child: Image.asset(
                        './assets/logo/mini/logo_mini.png',
                        width: 128,
                        height: 128,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: NotionSpace.xl),
                enter(
                  ErrorShake(
                    error: controller.usernameError,
                    child: NotionTextField(
                      readOnly: controller.loading,
                      autocorrect: false,
                      autofocus: true,
                      onChanged: controller.checkWellKnownWithCoolDown,
                      controller: controller.usernameController,
                      textInputAction: TextInputAction.next,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: controller.loading
                          ? null
                          : [AutofillHints.username],
                      prefixIcon: Icons.account_box_outlined,
                      error: controller.usernameError,
                      label: isBeeper
                          ? 'Username or email'
                          : L10n.of(context).matrixId,
                      hint: isBeeper ? 'username' : '@username:domain',
                    ),
                  ),
                ),
                const SizedBox(height: NotionSpace.md),
                enter(
                  ErrorShake(
                    error: controller.passwordError,
                    child: NotionTextField(
                      readOnly: controller.loading,
                      autocorrect: false,
                      autofillHints: controller.loading
                          ? null
                          : [AutofillHints.password],
                      controller: controller.passwordController,
                      textInputAction: TextInputAction.go,
                      obscureText: !controller.showPassword,
                      onSubmitted: (_) => controller.login(),
                      prefixIcon: Icons.lock_outlined,
                      error: controller.passwordError,
                      // The theme colours the icon for both themes.
                      suffix: IconButton(
                        tooltip: controller.showPassword
                            ? 'Hide password'
                            : 'Show password',
                        onPressed: controller.toggleShowPassword,
                        icon: Icon(
                          controller.showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                      hint: '******',
                      label: L10n.of(context).password,
                    ),
                  ),
                ),
                const SizedBox(height: NotionSpace.lg),
                enter(
                  NotionButton.primary(
                    expand: true,
                    busy: controller.loading,
                    label: L10n.of(context).login,
                    onPressed: controller.login,
                  ),
                ),
                if (homeserver != null) ...[
                  const SizedBox(height: NotionSpace.xs),
                  enter(
                    NotionButton.ghost(
                      expand: true,
                      label: L10n.of(context).passwordForgotten,
                      onPressed: controller.loading
                          ? null
                          : controller.passwordForgotten,
                    ),
                  ),
                ],
                const SizedBox(height: NotionSpace.md),
              ],
            ),
          );
        },
      ),
    );
  }
}
