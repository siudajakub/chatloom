// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Settings → About: the app's name, version and credits in a glass
/// [NotionAlertDialog] (not Material's `showAboutDialog`). "Licences"
/// opens the open-source licence list.
Future<void> showChatLoomAboutDialog(
  BuildContext context, {
  required String version,
}) {
  final name = AppSettings.applicationName.value;
  const legalese = 'AGPL-3.0-or-later';
  Widget logo(double size) => Image.asset(
    AppConfig.logoAsset,
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
  );
  return showNotionCustomDialog<void>(
    context: context,
    builder: (context) {
      final l10n = L10n.of(context);
      final typography = context.notion.typography;
      return NotionAlertDialog(
        icon: logo(NotionSize.avatarLg),
        title: Text(name, textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.versionWithNumber(version),
              textAlign: TextAlign.center,
              style: typography.footnoteMuted,
            ),
            const SizedBox(height: NotionSpace.md),
            Text(
              AppConfig.upstreamCredit,
              textAlign: TextAlign.center,
              style: typography.calloutMuted,
            ),
            const SizedBox(height: NotionSpace.xs),
            Text(
              legalese,
              textAlign: TextAlign.center,
              style: typography.captionMuted,
            ),
          ],
        ),
        actions: [
          NotionButton.ghost(
            icon: Icons.source_outlined,
            label: '${AppConfig.upstreamName} ${l10n.sourceCode}',
            onPressed: () => launchUrlString(AppConfig.upstreamSourceCodeUrl),
          ),
          NotionButton.ghost(
            label: 'Licences',
            onPressed: () => showLicensePage(
              context: context,
              applicationName: name,
              applicationVersion: version,
              applicationIcon: Padding(
                padding: const EdgeInsets.all(NotionSpace.xs),
                child: logo(NotionSize.avatarLg),
              ),
              applicationLegalese: legalese,
            ),
          ),
          NotionButton.primary(
            label: l10n.close,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
    },
  );
}
