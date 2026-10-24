// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// One row of a composer menu, or a divider when [label] is null.
class ComposerMenuEntry<T> {
  final T? value;
  final IconData? icon;
  final String? label;

  const ComposerMenuEntry(T this.value, IconData this.icon, String this.label);
  const ComposerMenuEntry.divider() : value = null, icon = null, label = null;

  bool get isDivider => label == null;
}

/// A glass menu that grows out of a composer button ("+" or the send
/// button) and sits just above it, like the attach and send menus in
/// Telegram and Messenger. [alignEnd] lines the panel up with the anchor's
/// end edge (the send button) instead of its start edge (the "+").
///
/// A thin wrapper over [showNotionMenu] (rows keyed `composer-menu-<label>`).
/// Returns the chosen value, or null when dismissed (outside tap, Escape,
/// back).
Future<T?> showComposerMenu<T>(
  BuildContext anchorContext, {
  required List<ComposerMenuEntry<T>> entries,
  bool alignEnd = false,
  String? semanticLabel,
}) => showNotionMenu<T>(
  anchorContext,
  alignEnd: alignEnd,
  semanticLabel: semanticLabel,
  keyPrefix: 'composer-menu',
  entries: [
    for (final entry in entries)
      if (entry.isDivider)
        const NotionMenuEntry.divider()
      else
        NotionMenuEntry<T>(
          value: entry.value as T,
          label: entry.label!,
          icon: entry.icon,
        ),
  ],
);
