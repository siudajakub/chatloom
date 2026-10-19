// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'notion_settings_body.dart';

/// Presents saved preferences separately from Incognito's effective policy.
class NotionPrivacyPreferences extends StatelessWidget {
  final bool incognito, pending, typing, receipts;
  final String? error;
  final ValueChanged<bool>? onIncognito, onTyping, onReceipts;
  const NotionPrivacyPreferences({
    super.key,
    required this.incognito,
    required this.typing,
    required this.receipts,
    this.pending = false,
    this.error,
    this.onIncognito,
    this.onTyping,
    this.onReceipts,
  });

  @override
  Widget build(BuildContext context) => Column(
    children: [
      NotionSettingsToggle(
        title: 'Incognito mode',
        subtitle:
            'Suppress automatic typing, read receipts and presence on this device. Replies may still mark messages read on their source network.',
        value: incognito,
        onChanged: pending ? null : onIncognito,
      ),
      NotionSizeReveal(
        visible: error != null,
        child: Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: NotionFadeThrough(
              child: Text(error ?? '', key: ValueKey(error)),
            ),
          ),
        ),
      ),
      NotionSettingsToggle(
        title: 'Send typing notifications',
        subtitle: incognito
            ? 'Suppressed by Incognito. Your saved preference is kept.'
            : 'Share when you are typing.',
        value: typing,
        onChanged: incognito || pending ? null : onTyping,
      ),
      NotionSettingsToggle(
        title: 'Send read receipts',
        subtitle: incognito
            ? 'Automatic receipts are suppressed by Incognito. Your saved preference is kept.'
            : 'Share read markers allowed by your device privacy policy.',
        value: receipts,
        onChanged: incognito || pending ? null : onReceipts,
      ),
    ],
  );
}
