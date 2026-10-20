// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:material_ui/material_ui.dart';
import 'package:particles_network/particles_network.dart';

class LoginScaffold extends StatelessWidget {
  final Widget body;
  final AppBar? appBar;
  final Widget? bottomNavigationBar;

  const LoginScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomNavigationBar,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobileMode = !ChatLoomThemes.isColumnModeByWidth(
          constraints.maxWidth,
        );
        if (isMobileMode) {
          return Scaffold(
            key: const Key('LoginScaffold'),
            appBar: appBar,
            body: SafeArea(child: body),
            bottomNavigationBar: bottomNavigationBar,
          );
        }
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.surfaceContainerLow,
                theme.colorScheme.surfaceContainer,
                theme.colorScheme.surfaceContainerHighest,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            children: [
              if (!NotionMotion.reduced(context))
                ParticleNetwork(
                  maxSpeed: 0.25,
                  particleColor: theme.colorScheme.primary,
                  lineColor: theme.colorScheme.secondary,
                ),
              Column(
                children: [
                  const SizedBox(height: 16),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        // The card settles in once; its pages animate inside.
                        child: NotionEntrance(
                          afterRoute: false,
                          rise: NotionMotion.riseSheet,
                          scale: NotionMotion.dialogFrom,
                          duration: NotionMotion.long,
                          child: Material(
                            borderRadius: BorderRadius.circular(
                              AppConfig.borderRadius,
                            ),
                            clipBehavior: Clip.hardEdge,
                            elevation:
                                theme.appBarTheme.scrolledUnderElevation ?? 4,
                            shadowColor: theme.appBarTheme.shadowColor,
                            child: ConstrainedBox(
                              constraints: isMobileMode
                                  ? const BoxConstraints()
                                  : const BoxConstraints(
                                      maxWidth: 480,
                                      maxHeight: 640,
                                    ),
                              child: Scaffold(
                                key: const Key('LoginScaffold'),
                                appBar: appBar,
                                body: SafeArea(child: body),
                                bottomNavigationBar: bottomNavigationBar,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const _PrivacyButtons(mainAxisAlignment: .center),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PrivacyButtons extends StatelessWidget {
  final MainAxisAlignment mainAxisAlignment;
  const _PrivacyButtons({required this.mainAxisAlignment});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shadowTextStyle = TextStyle(color: theme.colorScheme.secondary);
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisAlignment: mainAxisAlignment,
          children: [
            // ChatLoom has no website, help desk or privacy page of its own;
            // upstream FluffyChat links would be misleading here.
            TextButton(
              onPressed: () => PlatformInfos.showDialog(context),
              child: Text(L10n.of(context).about, style: shadowTextStyle),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shakes [child] each time a new, non-null [error] arrives (a rejected
/// password, a wrong recovery key); clearing the error does not shake.
class ErrorShake extends StatefulWidget {
  final Object? error;
  final Widget child;
  const ErrorShake({super.key, required this.error, required this.child});

  @override
  State<ErrorShake> createState() => _ErrorShakeState();
}

class _ErrorShakeState extends State<ErrorShake> {
  int _errors = 0;

  @override
  void didUpdateWidget(ErrorShake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null && widget.error != oldWidget.error) _errors++;
  }

  @override
  Widget build(BuildContext context) =>
      NotionShake(trigger: _errors, child: widget.child);
}
