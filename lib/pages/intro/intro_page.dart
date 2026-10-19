// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/intro/flows/restore_backup_flow.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/layouts/login_scaffold.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher_string.dart';

class IntroPage extends StatelessWidget {
  final bool isLoading, hasPresetHomeserver;
  final String? loggingInToHomeserver, welcomeText;
  final VoidCallback login;

  const IntroPage({
    required this.isLoading,
    required this.loggingInToHomeserver,
    super.key,
    required this.hasPresetHomeserver,
    required this.welcomeText,
    required this.login,
  });

  @override
  Widget build(BuildContext context) {
    final addMultiAccount = Matrix.of(
      context,
    ).widget.clients.any((client) => client.isLogged());
    final loggingInToHomeserver = this.loggingInToHomeserver;

    return LoginScaffold(
      appBar: AppBar(
        centerTitle: true,
        title: addMultiAccount
            ? Text(L10n.of(context).addAccount)
            : Text(AppSettings.applicationName.value),
        actions: [
          PopupMenuButton(
            useRootNavigator: true,
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: isLoading ? null : () => restoreBackupFlow(context),
                child: Row(
                  mainAxisSize: .min,
                  spacing: 12,
                  children: [
                    const Icon(Icons.import_export_outlined),
                    Expanded(
                      child: Text(
                        L10n.of(context).hydrate,
                        maxLines: 1,
                        overflow: .ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                onTap: () => launchUrlString(AppSettings.privacyPolicy.value),
                child: Row(
                  mainAxisSize: .min,
                  spacing: 12,
                  children: [
                    const Icon(Icons.privacy_tip_outlined),
                    Text(L10n.of(context).privacy),
                  ],
                ),
              ),
              PopupMenuItem(
                onTap: () => PlatformInfos.showDialog(context),
                child: Row(
                  mainAxisSize: .min,
                  spacing: 12,
                  children: [
                    const Icon(Icons.info_outlined),
                    Text(L10n.of(context).about),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: NotionFadeThrough(
        alignment: Alignment.center,
        child: isLoading
            ? Center(
                key: const ValueKey('loading'),
                child: Column(
                  mainAxisAlignment: .center,
                  spacing: NotionSpace.md,
                  children: [
                    const NotionDelayedSpinner(size: NotionSize.touchTarget),
                    if (loggingInToHomeserver != null)
                      NotionDelayedReveal(
                        child: Text(
                          L10n.of(context).logInTo(loggingInToHomeserver),
                        ),
                      ),
                  ],
                ),
              )
            : LayoutBuilder(
                key: const ValueKey('intro'),
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Column(
                          children: [
                            NotionEntrance(
                              rise: 0,
                              scale: NotionMotion.popFrom,
                              duration: NotionMotion.long,
                              child: Container(
                                alignment: Alignment.center,
                                padding: const EdgeInsets.all(32.0),
                                child: Hero(
                                  tag: 'info-logo',
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(128),
                                    child: Image.asset(
                                      './assets/logo/mini/logo_mini.png',
                                      width: 128,
                                      height: 128,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            NotionEntrance(
                              index: 2,
                              child: Text(
                                L10n.of(context).appSubtitle,
                                textAlign: TextAlign.center,
                                style: context.notion.typography.heading,
                              ),
                            ),
                            const SizedBox(height: NotionSpace.xs),
                            NotionEntrance(
                              index: 3,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: NotionSpace.xl,
                                ),
                                child: Text(
                                  welcomeText ??
                                      L10n.of(context).appDescription,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: NotionSpace.xxl,
                              ),
                              child: Column(
                                mainAxisSize: .min,
                                crossAxisAlignment: .stretch,
                                spacing: NotionSpace.md,
                                children: _staggerFrom(4, [
                                  if (!hasPresetHomeserver)
                                    NotionButton(
                                      label: L10n.of(context).createNewAccount,
                                      expand: true,
                                      onPressed: () => context.go(
                                        '${GoRouterState.of(context).uri.path}/sign_up',
                                      ),
                                    ),
                                  NotionButton.primary(
                                    label: L10n.of(context).signIn,
                                    expand: true,
                                    onPressed: login,
                                  ),
                                  if (!hasPresetHomeserver)
                                    NotionButton(
                                      variant: NotionButtonVariant.ghost,
                                      label: L10n.of(context).loginWithMatrixId,
                                      expand: true,
                                      onPressed: () async {
                                        final client = await Matrix.of(
                                          context,
                                        ).getLoginClient();
                                        if (!context.mounted) return;
                                        context.go(
                                          '${GoRouterState.of(context).uri.path}/login',
                                          extra: client,
                                        );
                                      },
                                    ),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 36),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// Entrances that continue a stagger started above them.
List<Widget> _staggerFrom(int first, List<Widget> children) => [
  for (var i = 0; i < children.length; i++)
    NotionEntrance(
      index: first + i,
      rise: NotionMotion.riseList,
      child: children[i],
    ),
];
