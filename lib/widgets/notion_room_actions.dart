// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_search.dart'
    show ConversationSearchScope;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart'
    show NotionConversationContentPage;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Source-room actions shared by the unified conversation overflow menu.
/// Leaving a chat is in Chat details (with its own confirmation).
Future<void> performNotionRoomAction(
  BuildContext context,
  Room room,
  String action,
) async {
  switch (action) {
    case 'details':
      context.go('${chatLocation(context, room.id)}/details');
    case 'search':
      // The open conversation's own search mode; elsewhere the Notion
      // content search (the FluffyChat search page is gone).
      if (ConversationSearchScope.maybeOpen(context)) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => NotionConversationContentPage(
            rooms: [room],
            name: InboxProjection(
              PersonalClient.of(room.client),
            ).displayName(room),
          ),
        ),
      );
    case 'encryption':
      context.go('${chatLocation(context, room.id)}/encryption');
  }
}
