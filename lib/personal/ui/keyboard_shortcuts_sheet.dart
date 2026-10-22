// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:material_ui/material_ui.dart';

/// ⌘/ on the Mac: every keyboard shortcut in one glass sheet.
Future<void> showKeyboardShortcutsSheet(BuildContext context) =>
    showNotionSheet<void>(
      context: context,
      title: 'Keyboard shortcuts',
      builder: (context) => const KeyboardShortcutsList(),
    );

class KeyboardShortcutsList extends StatelessWidget {
  const KeyboardShortcutsList({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in macShortcutHelp)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(entry.action, style: NotionType.callout),
                  ),
                  const SizedBox(width: NotionSpace.md),
                  Text(
                    entry.keys,
                    style: NotionType.callout.copyWith(
                      color: colors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
