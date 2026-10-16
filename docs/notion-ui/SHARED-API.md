# Frozen ownership and shared API

2026-10-13. Write only this isolated checkout. Root coordinator owns `lib/ui/notion/`, theme/router/app/locale/avatar/hub/organization/assets registration/preview/evidence and every Flutter job. A owns inbox paths and inbox/network/search tests; B owns conversation presentation and merged/media/transcript paths and tests; C owns details/settings presentation and corresponding tests. Protected functional files remain unchanged except reviewed presentation hunks.

Import `package:fluffychat/ui/notion/notion.dart`: `NotionTokens` (background/surface/selected/border/text/secondary/cover, inset/radius/avatarRadius/headerHeight/touchTarget, title/heading/body/caption), `NotionIconButton(icon:, label:, onPressed:)`, `NotionPropertyRow(label:, value:, onTap:)`, `NotionListRow(leading:, title:, subtitle:, trailing:, onTap:)`, `NotionCompactChatHeader(avatar:, name:, onDetails:)`.

Details: `NotionConversationDetailsData` and `NotionConversationDetailsActions` exported by the barrel. C implements `NotionChatDetailsPage(data:, actions:)` in `lib/personal/ui/notion_chat_details_page.dart`. C also exports `showNotionMergedChatDetails(BuildContext context, {required PersonalClient personal, required PersonGroup group})` from `notion_chat_details_adapter.dart`, which B calls from merged identity header. Adapter must listen to live metadata and separate person actions from individual source actions.

`lib/ui/notion/metadata_actions.dart` provides `NotionMetadataActions.canEdit(personal, entity)` and `setPinned(personal, entity, pinned)` using existing ordered private metadata and pending guards. Do not add another data store. Private organization edits/appearance/archive may use existing OrganizationPage callbacks until individually adapted.

Production components must expose data/callback constructors for actual-widget fixtures; root will assemble capture tests. Agents do not run Flutter jobs or format other owners' paths. Submit component/test export details and shared requests promptly.

Roboto Regular/Medium/Bold is now bundled from the installed Flutter SDK with its license under assets/notion/fonts/. This keeps the approved neutral typography consistent without runtime requests. Existing explicit accent preferences remain honored; default is neutral dark. Root owns final integration edits after all three agents froze source.

## Conversation API — 2026-10-16

The production ordinary and merged timelines use these presentation-only contracts (direct imports; no shared barrel change):

- `conversation_grouping.dart`: `ConversationGroupingItem(accountId, sourceId, senderId, outgoing, timestamp, threadId?, deliveryState, boundary)` and `conversationGroupPosition(item:, older:, newer:)`. Neighbours are chronological; ordinary reverse-list names must be translated by the adapter. Matrix sent/synced share the sent presentation state.
- `conversation_bubble.dart`: `ConversationBubble(body:, outgoing:, groupPosition:, avatar?, heading?, footer?, reactions?, media:, selected:, backgroundColor?, surfaceBuilder?)`. `surfaceBuilder` wraps the complete fill outside clipping; gestures must not wrap only its text child. Avatar/heading/metadata stay outside that transform. `ConversationBubbleColors` is a theme extension with light/dark defaults.
- `conversation_message_gestures.dart`: `ConversationMessageGestures(child:, identity:, onReply?, onLike?, enabled:, swipeRightToLeft:, quickLikeEnabled:, interactiveContent:, likeEmoji:)`. `onLike` returns true only for a newly accepted intent, not delivery. Selection and interactive content disable quick mutations; mouse double click belongs to selection. `ConversationMotion.reduced` observes both accessibility flags through the motion widgets.
- `compact_composer.dart`: `CompactComposer(input:, source:, addAction:, primaryAction:, sourceWidth:, contextPreview?)`; caller owns the controller/editor/focus. Only the source slot moves across breakpoints. `ConversationSourceChip(network:, label?, locked:, onPressed?, available:)` never changes routing. `conversationComposerMaxLines` caps the remaining viewport at 1–4 lines.
- `conversation_source_picker.dart`: options carry the full `ConversationRef`, display title/subtitle, availability/reason. `showConversationSourcePicker` returns `ConversationRef?`; cancel is null. The controller must revalidate its frozen account/group/reply/source after await. Routes and tap regions preserve active editor composition.
- `conversation_message_actions.dart`: the shared SDK reaction adapter is used by double tap, menu and reaction chips. `strict:false` preserves ordinary unverified policy, `strict:true` preserves merged policy. Never bypass it with direct SDK mutation. It guards unresolved source-event intentions, synced add evidence and originating-timeline/redaction removal evidence. Client-lifetime bookkeeping is not a durable reaction outbox or exactly-once guarantee.

Actual SDK content/media, reply routing, drafts/outbox/schedule and manual transcript remain owned by existing controllers. UI builders cannot send or infer a source from network labels. Full-graph fixtures run through `run-personal-app-tests.py`; the isolated presentation harness explicitly excludes SDK suites and hashes its copied sources.

## Chat visibility and network preferences — 2026-10-16

`ConversationClassifier` reads existing bridge/member state and provides canonical display network, group/DM and technical-room classification. It never changes `PersonalClient.networkOf`, persisted `ConversationRef`, capabilities or send routing. Bridge aliases share one filter; unsupported bridged identities use Other, ordinary rooms use Matrix. Explicit network groups cannot participate in private DM projections even when stale m.direct metadata remains.

`NetworkPreferences` uses `network-policy:<canonical network>` through the existing encrypted metadata replica. Telegram defaults to `ChatPlacement.groups`; other networks default to inbox. `ConversationMetadata` adds optional placement and notification mode plus independent ignored state. Existing muted/lowPriority retain mentions/reply behavior. Ignores preserve all prior fields and force absolute silence. Source notification exceptions remain source-bound for merged people.

`InboxProjection.placementFor` and `notificationModeFor` supply effective policy. `InboxFilter.ignored` and `.technical` are explicit categories; All networks never bypasses visibility. `personalNotificationEligible(..., notificationMode:)` is shared by foreground/background notification adapters. Unknown background failures cannot synthesize a notification that bypasses private rules.

`ChatPreferencesPage(personal:, room?:)` is account-bound and native-only for writes. `canEditChatPreferences` allows durable coalesced changes while earlier metadata awaits ACK, but blocks conflicts, unavailable encrypted sync and web writes. Pending is not an ACK. The dock/page/selector have optional selectedView/onViewSelected/onManageNetworks callbacks so existing presenter fixtures remain compatible. The settings route is `/rooms/settings/networks`.

## Compact voice playback — 2026-10-16

`NotionAudioFileBlock` is the compact inline transport used by the real SDK audio renderer in both ordinary and merged messages. It has no expand callback, fullscreen action or sheet. Existing `duration`, `progress`, `onPlay`, `onDownload` and optional `speedAction` remain compatible. New inputs: `seekDuration`, bounded normalized `waveform`, `foregroundColor`, `onSeekBack`, `onSeekForward`, `speed` and `onSpeed`.

The standard Flutter slider paints the real MSC1767 amplitude envelope with `NotionWaveformTrackShape`; absent or malformed samples render a flat track. `notionVoiceWaveform` validates numeric, finite nonnegative samples, caps the input at 1024 values and downsamples to at most 40 peaks. Rendering interpolates the supplied envelope. It does not download or decode audio to draw it. Seek displays a local time preview and invokes `onSeek` once on release; keyboard and adjustable semantics use the same callback. A loading/source change clears pending preview. The caller must revalidate ownership before seeking or changing speed.

`AudioPlayerWidget` retains Matrix decryption, MediaAccess leases, iOS Ogg conversion and the shared playback coordinator. It clamps ±10 seconds to the actual decoder duration and listens to position, duration, state and speed streams. Unknown duration and loading disable seeking. Repeated pending play taps are ignored; assigning a new native player rebuilds the stream subscriptions immediately. Removing a row during download invalidates its pending reservation. Transcription remains the existing explicit user action; save remains independent from play. No new background playback service or account access is added.

Playback banners retain their messenger before disposal and check messenger/player lifetime before showing or changing transport. They do not look up ancestors through a disposed row or Matrix context.


## Profile content — 2026-10-16

`NotionConversationContentPage(initialMedia: true)` exposes exactly Media / Files / Links. `initialMedia: false` is separate local message search. One `ConversationContentController` owns source cursors/errors and all projections; scope keys include client/account/room/event. `NotionConversationDetailsData.label` remains a compatibility-only field and is not rendered. UI label mutation/filter entry points are removed; journal data is retained. See [implementation and limits](../personal/profile-content-2026-10-16.md).
