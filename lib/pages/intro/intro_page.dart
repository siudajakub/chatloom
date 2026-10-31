// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/intro/flows/restore_backup_flow.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/layouts/login_scaffold.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// The first screen: ChatLoom brings the Beeper networks together, so the
/// primary action signs in to Beeper directly. Any other Matrix homeserver
/// stays available as "Use another server" (the server picker), and the
/// header's "More" sheet keeps the Matrix ID login and backup restore.
/// Creating an account is not offered here: Beeper registration over the
/// Matrix API is unverified (the server picker still offers it where a
/// server supports it).
class IntroPage extends StatelessWidget {
  final bool isLoading, hasPresetHomeserver;
  final String? loggingInToHomeserver, welcomeText;
  final VoidCallback login;

  /// The Beeper sign-in is checking the server (inline spinner).
  final bool loginBusy;

  /// Another account is already signed in ("Add account" title).
  final bool addMultiAccount;

  const IntroPage({
    required this.isLoading,
    required this.loggingInToHomeserver,
    super.key,
    required this.hasPresetHomeserver,
    required this.welcomeText,
    required this.login,
    this.loginBusy = false,
    this.addMultiAccount = false,
  });

  static const title = 'All your chats in one place';
  static const description =
      'Sign in with your Beeper account to bring WhatsApp, Telegram, '
      'Instagram, Messenger and Slack together.';

  Future<void> _loginWithMatrixId(BuildContext context) async {
    final client = await Matrix.of(context).getLoginClient();
    if (!context.mounted) return;
    context.go('${GoRouterState.of(context).uri.path}/login', extra: client);
  }

  Future<void> _more(BuildContext context) => showNotionSheet<void>(
    context: context,
    title: 'More options',
    builder: (sheetContext) {
      void run(void Function() action) {
        Navigator.of(sheetContext).pop();
        action();
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!hasPresetHomeserver)
            NotionListRow(
              key: const Key('intro_matrix_id_login'),
              leading: const Icon(
                Icons.alternate_email_outlined,
                size: NotionSize.iconMd,
              ),
              title: 'Sign in with a Matrix ID',
              subtitle: 'For an account on any Matrix server',
              onTap: () => run(() => _loginWithMatrixId(context)),
            ),
          NotionListRow(
            leading: const Icon(
              Icons.import_export_outlined,
              size: NotionSize.iconMd,
            ),
            title: L10n.of(context).hydrate,
            onTap: isLoading
                ? null
                : () => run(() => restoreBackupFlow(context)),
          ),
          NotionListRow(
            leading: const Icon(Icons.info_outlined, size: NotionSize.iconMd),
            title: L10n.of(context).about,
            onTap: () => run(() => PlatformInfos.showDialog(context)),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final loggingInToHomeserver = this.loggingInToHomeserver;

    return LoginScaffold(
      appBar: AppBar(
        centerTitle: true,
        title: addMultiAccount
            ? Text(L10n.of(context).addAccount)
            : Text(AppSettings.applicationName.value),
        actions: [
          NotionIconButton(
            key: const Key('intro_more'),
            icon: Icons.more_horiz,
            label: 'More options',
            onPressed: () => _more(context),
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
                                  child: Image.asset(
                                    AppConfig.logoAsset,
                                    width: 128,
                                    height: 128,
                                    filterQuality: FilterQuality.medium,
                                  ),
                                ),
                              ),
                            ),
                            NotionEntrance(
                              index: 2,
                              child: Text(
                                title,
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
                                  welcomeText ?? description,
                                  textAlign: TextAlign.center,
                                  style: context.notion.typography.callout
                                      .copyWith(
                                        color:
                                            context.notion.colors.textSecondary,
                                      ),
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
                                  NotionButton.primary(
                                    key: const Key('intro_sign_in'),
                                    label: hasPresetHomeserver
                                        ? L10n.of(context).signIn
                                        : 'Sign in with Beeper',
                                    expand: true,
                                    busy: loginBusy,
                                    onPressed: loginBusy ? null : login,
                                  ),
                                  if (!hasPresetHomeserver)
                                    NotionButton.ghost(
                                      key: const Key('intro_other_server'),
                                      label: 'Use another server',
                                      expand: true,
                                      onPressed: loginBusy
                                          ? null
                                          : () => context.go(
                                              '${GoRouterState.of(context).uri.path}/sign_in',
                                            ),
                                    ),
                                ]),
                              ),
                            ),
                            const SizedBox(height: NotionSpace.xxl),
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
