// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/bridge_capabilities.dart';

/// A person-readable name of a bridge feature (never the enum identifier).
/// Features added later fall back to their identifier until named here.
String bridgeFeatureLabel(BridgeFeature feature) => switch (feature.name) {
  'reply' => 'Replies',
  'reaction' => 'Reactions',
  'edit' => 'Editing messages',
  'delete' => 'Deleting messages',
  'audio' => 'Audio files',
  'voice' => 'Voice messages',
  'upload' => 'Files',
  'image' => 'Photos',
  'video' => 'Videos',
  'gif' => 'GIFs',
  'roundVideo' => 'Round videos',
  'sticker' => 'Stickers',
  'poll' => 'Polls',
  'thread' => 'Threads',
  'disappearing' => 'Disappearing messages',
  'location' => 'Location',
  final other => other,
};

/// Conversation details → "Conversation capabilities": what this chat's
/// network supports, one row per feature, in a glass [NotionDialog].
Future<void> showConversationCapabilitiesDialog(
  BuildContext context, {
  required String Function(BridgeFeature feature) reasonOf,
}) => showNotionCustomDialog<void>(
  context: context,
  builder: (context) => NotionDialog(
    title: 'Conversation capabilities',
    content: SizedBox(
      width: double.infinity,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final feature in BridgeFeature.values)
            NotionListRow(
              title: bridgeFeatureLabel(feature),
              subtitle: reasonOf(feature),
            ),
        ],
      ),
    ),
    actions: [
      NotionButton.ghost(
        label: 'Close',
        onPressed: () => Navigator.pop(context),
      ),
    ],
  ),
);
