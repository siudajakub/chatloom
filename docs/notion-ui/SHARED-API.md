# Frozen ownership and shared API

2026-10-13. Write only this isolated checkout. Root coordinator owns `lib/ui/notion/`, theme/router/app/locale/avatar/hub/organization/assets registration/preview/evidence and every Flutter job. A owns inbox paths and inbox/network/search tests; B owns conversation presentation and merged/media/transcript paths and tests; C owns details/settings presentation and corresponding tests. Protected functional files remain unchanged except reviewed presentation hunks.

Import `package:fluffychat/ui/notion/notion.dart`: `NotionTokens` (background/surface/selected/border/text/secondary/cover, inset/radius/avatarRadius/headerHeight/touchTarget, title/heading/body/caption), `NotionIconButton(icon:, label:, onPressed:)`, `NotionPropertyRow(label:, value:, onTap:)`, `NotionListRow(leading:, title:, subtitle:, trailing:, onTap:)`, `NotionCompactChatHeader(avatar:, name:, onDetails:)`.

Details: `NotionConversationDetailsData` and `NotionConversationDetailsActions` exported by the barrel. C implements `NotionChatDetailsPage(data:, actions:)` in `lib/personal/ui/notion_chat_details_page.dart`. C also exports `showNotionMergedChatDetails(BuildContext context, {required PersonalClient personal, required PersonGroup group})` from `notion_chat_details_adapter.dart`, which B calls from merged identity header. Adapter must listen to live metadata and separate person actions from individual source actions.

`lib/ui/notion/metadata_actions.dart` provides `NotionMetadataActions.canEdit(personal, entity)` and `setPinned(personal, entity, pinned)` using existing ordered private metadata and pending guards. Do not add another data store. Private organization edits/appearance/archive may use existing OrganizationPage callbacks until individually adapted.

Production components must expose data/callback constructors for actual-widget fixtures; root will assemble capture tests. Agents do not run Flutter jobs or format other owners' paths. Submit component/test export details and shared requests promptly.

Roboto Regular/Medium/Bold is now bundled from the installed Flutter SDK with its license under assets/notion/fonts/. This keeps the approved neutral typography consistent without runtime requests. Existing explicit accent preferences remain honored; default is neutral dark. Root owns final integration edits after all three agents froze source.
