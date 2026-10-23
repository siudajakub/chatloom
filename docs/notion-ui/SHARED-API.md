# Frozen ownership and shared API

## Manual read action — 2026-10-21

Ordinary and merged conversations show `ConversationReadButton(rooms:)` in
incognito, above the microphone in the measured composer overlay. It uses the
existing `NotionGlassPill` with a double-check icon and a 48 dp touch target.
One tap immediately sends public read receipts for the latest event of each
source; all cutoffs are captured before awaiting. Incognito and the automatic
receipt preference stay unchanged. `PersonalPrivacy.markRead(publicReceipt:
true)` overrides that preference only together with `manual: true`, through the
existing exact room/event transport grant. Pending taps are disabled; failures
allow retry. The jump-to-latest control sits above this action.

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
- `compact_composer.dart`: `CompactComposer(input:, source:, addAction?, primaryAction:, sourceWidth: 0, contextPreview?, actions?, actionsEnabled:, collapseOnText?, onExpandedChanged?, collapseToken?, inputOverlay?)`; caller owns the controller/editor/focus. Only the source slot moves across breakpoints. `ConversationSourceChip(network:, label?, locked:, onPressed?, available:, compact: true, hint:)` never changes routing. `conversationComposerMaxLines` caps the remaining viewport at 1–4 lines. See the 2026-10-17 composer section below.
- `conversation_source_picker.dart`: options carry the full `ConversationRef`, display title/subtitle, availability/reason. `showConversationSourcePicker` returns `ConversationRef?`; cancel is null. The controller must revalidate its frozen account/group/reply/source after await. Routes and tap regions preserve active editor composition.
- `conversation_message_actions.dart`: the shared SDK reaction adapter is used by double tap, menu and reaction chips. `strict:false` preserves ordinary unverified policy, `strict:true` preserves merged policy. Never bypass it with direct SDK mutation. It guards unresolved source-event intentions, synced add evidence and originating-timeline/redaction removal evidence. Client-lifetime bookkeeping is not a durable reaction outbox or exactly-once guarantee.

Actual SDK content/media, reply routing, drafts/outbox/schedule and manual transcript remain owned by existing controllers. UI builders cannot send or infer a source from network labels. Full-graph fixtures run through `run-personal-app-tests.py`; the isolated presentation harness explicitly excludes SDK suites and hashes its copied sources.

## Chat visibility and network preferences — 2026-10-16

`ConversationClassifier` reads existing bridge/member state and provides canonical display network, group/DM and technical-room classification. It never changes `PersonalClient.networkOf`, persisted `ConversationRef`, capabilities or send routing. Bridge aliases share one filter; unsupported bridged identities use Other, ordinary rooms use Matrix. Explicit network groups cannot participate in private DM projections even when stale m.direct metadata remains.

`NetworkPreferences` uses `network-policy:<canonical network>` through the existing encrypted metadata replica. Telegram defaults to `ChatPlacement.groups`; other networks default to inbox. `ConversationMetadata` adds optional placement and notification mode plus independent ignored state. Existing muted/lowPriority retain mentions/reply behavior. Ignores preserve all prior fields and force absolute silence. Source notification exceptions remain source-bound for merged people.

`NetworkPreferences.showInGroups` independently controls inclusion in the Groups view (Settings → Networks → network → Show in Groups). It defaults to false for Telegram, true for other networks, including when older metadata has no such field. Explicit booleans survive private sync. It does not change placement, pinning, direct chats or notifications; pinning does not bypass the Groups visibility filter.

`InboxProjection.placementFor` and `notificationModeFor` supply effective policy. `InboxFilter.ignored` and `.technical` are explicit categories; All networks never bypasses visibility. `personalNotificationEligible(..., notificationMode:)` is shared by foreground/background notification adapters. Unknown background failures cannot synthesize a notification that bypasses private rules.

`ChatPreferencesPage(personal:, room?:)` is account-bound and native-only for writes. `canEditChatPreferences` allows durable coalesced changes while earlier metadata awaits ACK, but blocks conflicts, unavailable encrypted sync and web writes. Pending is not an ACK. The dock/page/selector have optional selectedView/onViewSelected/onManageNetworks callbacks so existing presenter fixtures remain compatible. The settings route is `/rooms/settings/networks`.

## Compact voice playback — 2026-10-16

`NotionAudioFileBlock` is the compact inline transport used by the real SDK audio renderer in both ordinary and merged messages. It has no expand callback, fullscreen action or sheet. Existing `duration`, `progress`, `onPlay`, `onDownload` and optional `speedAction` remain compatible. New inputs: `seekDuration`, bounded normalized `waveform`, `foregroundColor`, `onSeekBack`, `onSeekForward`, `speed` and `onSpeed`.

The standard Flutter slider paints the real MSC1767 amplitude envelope with `NotionWaveformTrackShape`; absent or malformed samples render a flat track. `notionVoiceWaveform` validates numeric, finite nonnegative samples, caps the input at 1024 values and downsamples to at most 40 peaks. Rendering interpolates the supplied envelope. It does not download or decode audio to draw it. Seek displays a local time preview and invokes `onSeek` once on release; keyboard and adjustable semantics use the same callback. A loading/source change clears pending preview. The caller must revalidate ownership before seeking or changing speed.

`AudioPlayerWidget` retains Matrix decryption, MediaAccess leases, iOS Ogg conversion and the shared playback coordinator. It clamps ±10 seconds to the actual decoder duration and listens to position, duration, state and speed streams. Unknown duration and loading disable seeking. Repeated pending play taps are ignored; assigning a new native player rebuilds the stream subscriptions immediately. Removing a row during download invalidates its pending reservation. Transcription remains the existing explicit user action; save remains independent from play. No new background playback service or account access is added.

Playback banners retain their messenger before disposal and check messenger/player lifetime before showing or changing transport. They do not look up ancestors through a disposed row or Matrix context.


## Profile content — 2026-10-16

`NotionConversationContentPage(initialMedia: true)` exposes exactly Media / Files / Links. `initialMedia: false` is separate local message search. One `ConversationContentController` owns source cursors/errors and all projections; scope keys include client/account/room/event. `NotionConversationDetailsData.label` remains a compatibility-only field and is not rendered. UI label mutation/filter entry points are removed; journal data is retained. See [implementation and limits](../personal/profile-content-2026-10-16.md).

## Design system — 2026-10-17

[`DESIGN.md`](../../DESIGN.md) is the source of truth for tokens and primitives. The barrel now also exports `notion_tokens.dart` (`NotionTokens` ThemeExtension with dark/light `NotionColors` and coloured `NotionTypography`, `context.notion`, const `NotionSpace`/`NotionRadius`/`NotionSize`/`NotionType`) and `notion_primitives.dart` (`NotionScaffold`, `NotionSectionHeader`, `NotionButton`, `NotionDialog`/`showNotionDialog`/`showNotionConfirmDialog`, `NotionSheet`/`showNotionSheet`, `NotionEmptyState`, `NotionTextField`). The v1 static `NotionTokens.*` members above remain as dark-only transitional constants. `NotionTheme` registers `NotionTokens` and `ConversationBubbleColors` and themes list tiles, checkbox/radio, icon buttons, tabs, navigation bar/rail/drawer, tooltip, badge, menus, segmented buttons, FAB, slider and search bar. `AppConfig.borderRadius` equals `NotionRadius.md`. `scripts/check-design-tokens.py` reports raw design values against `scripts/design-baseline.json`; goldens live in `test/notion/goldens/`.


## Composer actions and voice hold — 2026-10-17

No bottom sheet behind "+". With `actions:` the composer renders its own 48dp "+" (tooltip "More message actions" / "Hide message actions", `Semantics(expanded:)`, rotates to ×) and an always-present tray slot between "+" and the field: `[+][tray][field][primary]`. The tray width animates 0 → n×48 (160 ms easeOutCubic; icons fade and slide 8dp; reduced motion opens instantly without slide), so the field narrows instead of being replaced; the editor's ancestors and child index never change (IME/composition survive open/close and `inputOverlay`). Collapsed trays ignore pointers and semantics. Slots fit by width (editor keeps ≥32dp while open); the remainder moves into a "More actions" popup. The tray collapses on "+", on the first non-empty text of `collapseOnText`, after an action is used (`collapseOnUse`), and on any `collapseToken` change (room, sending account/source, reply, edit, voice hold). `addAction` remains for legacy callers.

`composer_action_tray.dart`: `ComposerAction(icon:, label:, onPressed?, anchor?, collapseOnUse: true, selected:)`. `anchor` is a `(context, used)` builder for an action that owns its popup (attachments); call `used()` after it ran. Anchored actions go first; the overflow menu only calls `onPressed`. Action callbacks must never pop routes.

Ordinary and merged chat (`chat_input_row.dart`): Attach (attachment popup, includes "Record a round video silently" when `canRecordRoundSilently`), Emoji, "Send from another account" (ordinary chat, multi-account, `showMenu`). Recording (wave 3, 21.10): there is no voice ↔ round mode. While the editor is empty, not editing and recording is possible, the mic is the primary action and, when `roundAvailability.canRecord` (Android + Telegram), a `RoundRecordButton` sits beside it in `CompactComposer(secondaryAction:)`: `[+][tray][field][round][mic]`. Hold either to record (voice starts on touch, round after 150 ms); a quick tap records nothing and shows the button's own tooltip hint (no snackbar). The round slot grows/shrinks (`NotionSizeReveal`, horizontal, `short`) when text appears, during a voice hold, or when availability changes; it takes room only from the editor and never moves the source chip out of line. Without round video only the mic shows; in a Telegram chat its tap hint names `roundAvailability.reason`. Send later/Schedule is only in the conversation three-dots menu (`conversationQuickActions` `'schedule'`).

Source chip: compact by default — monochrome network glyph plus lock/chevron, 48–56dp wide, min 48×48, text-scale independent; full description only in Tooltip and Semantics with the unchanged labels ("Replying via X", "X, choose sending source", "Sending via X", "X, source unavailable"). `ConversationSourceHint.choose` shows a hub glyph with a status dot, `.unavailable` mutes the glyph. `sourceWidth` defaults to 0 (no 130dp floor). `compact: false` keeps the old text chip.

`voice_record_button.dart`: `VoiceRecordButton(hold:, onStart:, onSend:, onCancel:, recorded?, enabled:)` and `VoiceRecordHoldOverlay(hold:, duration:)` share a `VoiceRecordHold` (phases idle/starting/holding/locked/released/canceled). Press starts recording; release after ≥800 ms (recorder clock via `recorded`) sends, shorter discards; 80dp toward the start edge cancels (RTL mirrored); 80dp up locks into the recorder's hands-free row; a tap (<250 ms, no movement) or the semantics tap starts hands-free. Release/cancel while the recorder is still starting discards once it starts. While capturing, `ChatInputRow` keeps the composer mounted (the pointer stays alive) and shows the overlay over the field; otherwise `RecordingInputRow` takes over. Start/send/cancel haptics belong to `RecordingViewModel`; the button only clicks on lock. Merged chat still opens the source conversation for voice.

## Motion, deferred page work and rounds — 2026-10-17

`lib/ui/notion/notion_motion.dart`: `NotionMotion` (push 280 ms `easeOutCubic`, pop 240 ms, `reduced(context)`, `routeSettled(context)`, `afterRouteSettled(context, callback)`), `NotionPageTransitionsBuilder` (incoming slides from 8 % and fades in; the page underneath drifts −6 % under a 0.35 scrim so no frame is empty; reduced motion = short fade; zero-duration routes are instant without a tree change) and `AfterRouteTransition(child:, placeholder:)`. `NotionTheme` maps every platform to it (Cupertino on iOS). go_router pages use one `_AppPage` type: instant in column mode, with reduced motion and for the outer shell; the settings shell animates on phones. `AppRoutes.defaultPageBuilder(..., memo:)` memoises the page child per page key so hidden pages are not rebuilt on every navigation. Android predictive back drives the frontmost Notion route.

Heavy page content belongs behind `AfterRouteTransition` or `NotionMotion.afterRouteSettled`, never in `initState`. Pages that need the private client call `PersonalPageLoad.request(context, personal)` (`lib/personal/ui/notion_settings_load.dart`): it loads after the route settled and skips a ready client loaded through it in the last 30 s.

Rounds: `RoundVideoView` is a fixed-size circle (`clamp(min(width*0.6, 240), 160, 240)`), full-diameter `ClipOval`, `RoundProgressPainter` ring, duration pill bottom-left, `statusOverlay` bottom-right, `RoundSideAction` column towards the screen centre, `below:` slot for the transcript. `ConversationBubble(chromeless: true)` renders rounds without fill/clip/padding with a circular selection ring. `RoundStageController.shared` presents the playing round enlarged over a dimmed backdrop (root navigator popup route); shrinking keeps the same `VideoPlayerController`; owners call `release(controller)` before disposing it. Pass `enlargeOnPlay: false` where the round is already shown large.

Transcription: `NotionTranscribeSplitButton` (label segment + language segment with Automatic/Polish/English/Armenian `MenuAnchor`; busy state shows a spinner and a cancel segment). `TranscriptPanel(event:, foregroundColor:)` never calls `PersonalClient.load()`; it rebuilds only when its own job, the auto-pending flag or the default language changes.

### Composer update after UX review — 2026-10-17

Attach menu order: Image, Video, File | Take a photo, Record a video (mobile) | Location (mobile), Poll | Record a round video silently (last, only when available). Trays: Attach · Emoji (+ "Send from another account" in an ordinary multi-account chat); round video is a button beside the mic, not a tray action, and "Record a round video silently" is inside the Attach popup when `silent_send` is allowed (no bare mute icon). When the open tray would leave the editor under 120dp, the inline source chip and its divider shrink to 0 with the tray animation (clipped, no taps, excluded from semantics); the editor keeps its ancestors and child index. The overflow is a themed `MenuAnchor` with 48dp `MenuItemButton`s and a `NotionIconButton` "More actions" trigger. While the mic is held, an `OverlayPortal` draws a 36×72 lock pill (lock over chevron-up, follows `lockProgress`) above the mic and a 1.6× mic fill (`VoiceRecordLayout`). `RecordingDot` lives in `voice_record_button.dart`. All recording clocks use `m:ss` (`notionAudioTime`). `NotionSendButton(tooltip:)` defaults to "Send message"; the voice row uses "Send voice message". Composer field radius is `NotionRadius.field`/`fieldAll` (26).

## Undecryptable messages and encryption health — 2026-10-18

`NotionCallout(icon:, title:, message?, tone:, actionLabel?, onAction?, actionBusy:, secondaryLabel?, onSecondary?, onDismiss?, dismissLabel:)` in `lib/ui/notion/notion_callout.dart`: flat `surface` block, `tone` (neutral/warning/danger) colours only the icon, 48 pt dismiss in the top-right corner. Goldens `primitives/callout-{dark,light}.png`.

`WaitingMessageView(stage:, textColor:, onRetry?, onVerify?)` (`lib/pages/chat/events/waiting_message_view.dart`) is the bubble body for an undecryptable event; `stage` is `KeyRecoveryStage?` (`lib/personal/encryption/key_recovery_stage.dart`: backup, devices, keyReceived, failed, verifySession, permanent; `null` = preparing). `UndecryptableMessage(event, textColor:)` binds it to `UndecryptableMessages.of(client)` and is returned by `MessageContent` for every non-redacted `m.room.encrypted` event, so ordinary and merged chats render the same bubble. `Message` routes such events through the normal bubble path; `isCollapsedState` and conversation grouping treat them as messages.

`UndecryptableChatHint(count:, onFix:)` (`lib/pages/chat/undecryptable_chat_hint.dart`, height `heightFor(textScaler)`) sits in the chat `AppBar.bottom`; count with `UndecryptableMessages.settledCount(events)`, fix with `showUndecryptableFixSheet(context, client:, events:)`.

`InboxHealthNotice(items:, onFix:, onDismiss:, onDetails?, busy?)` and `InboxHealthDetails(items:, onFix:, busy?)` (`lib/personal/ui/inbox_health_notice.dart`) take `InboxHealthItem(icon:, title:, message:, actionLabel:, tone:)`. `InboxHealthStatus(client:)` (`lib/pages/chat_list/inbox_health_status.dart`) owns an `E2eeHealthController` and fills the inbox `status` slot. Goldens `screens/undecryptable-390.png`, `screens/inbox-health-390.png`.

## Motion system — 2026-10-19

Supersedes the timing in "Motion, deferred page work and rounds": push is now `NotionMotion.long` (320 ms, `emphasized`), pop `reverse` (220 ms, `easeInCubic`), the pushed page fades in over the first 35 % (`pageFadeWindow`), reduced motion keeps a plain short fade. Predictive back, `routeSettled`, instant routes and `AfterRouteTransition` keep their contracts; `AfterRouteTransition` now fades its child in (140 ms) when it waited for a push. `FluffyThemes.animationDuration`/`animationCurve` = `NotionMotion.short`/`standard`.

Frozen API (all from `package:fluffychat/ui/notion/notion.dart`; full table and examples in DESIGN.md "Motion"):

- Tokens: `NotionMotion.{instant, quick, short, medium, long, forward, reverse, stagger, staggerCap, loaderGrace, highlight, standard, emphasized, exitFast, enter, exit, snappy, smooth, bouncy, snappyCurve, smoothCurve, bouncyCurve, springTolerance, rise, riseList, riseSheet, pressButton, pressIcon, pressRow, popFrom, dialogFrom, popoverFrom, sheetStyle, menuStyle}`, `NotionMotion.reduced(context)`, `.of(context, d)`, `.staggerFor(i)`, `.springTo(spring, from, to, velocity:)`, `.whenRouteSettled(context, action)`; `NotionSpringCurve(spring)`; `NotionHaptics.{light, send, longPress}()`.
- `NotionPressable(child:, scale:, enabled:, bounce:, onTap:, onLongPress:, hapticOnTap:, alignment:)` — `notion_pressable.dart`.
- `NotionEntrance(child:, index:, rise:, slide:, scale:, duration:, afterRoute: true, playKey:, enabled:, alignment:)`, `NotionEntrance.stagger(children)`, `NotionEntranceScope(child:)`, `NotionStaggeredColumn(children:)`, `NotionShake(trigger:, child:, distance:)` — `notion_entrance.dart` (only file importing flutter_animate; effects driven by owned controllers, the `Animate` widget is never mounted).
- `NotionFadeThrough(child:, duration:, alignment:)`, `NotionMorphSwitcher(child:, bounce:, rotate:)`, `NotionAnimatedCount(count:, style:, format:)`, `NotionSizeReveal(visible:, child:, axis:, alignment:, duration:, revealOnMount:)`, `NotionPop(child:, trigger:, visible:, from:, playOnMount:, bounce:, afterRoute:)`, `NotionRowHighlight(trigger:, child:, color:, borderRadius:)`, `NotionDelayedReveal(child:, delay:, placeholder:)`, `NotionDelayedSpinner(size:, strokeWidth:, color:, delay:)` — `notion_switchers.dart`.
- `NotionSkeleton(child:, enabled:)`, `NotionSkeleton.sliver(...)`, `NotionSkeleton.keep/ignore/unite(child)`, `NotionSkeletonRow(avatar:, avatarSize:, lines:)` — `notion_skeleton.dart` (only file importing skeletonizer).
- `NotionTypingDots(size:, color:)`, `NotionPulse(child:, color:, enabled:, spread:, borderRadius:)` — `notion_loops.dart`; `TypingAnimation` and `PulsatingWidget` are shims.
- `showNotionCustomDialog<T>(context:, builder:, barrierDismissible:, barrierColor:, useRootNavigator:, useSafeArea:, routeSettings:)`, `NotionDialogRoute`, `NotionDialogTransition(animation:, child:, from:, alignment:)`, `showNotionPopover<T>(context:, builder:, alignment:, barrierDismissible:, barrierColor:, useRootNavigator:, routeSettings:)`, `NotionPopoverRoute` — `notion_modal_routes.dart`. `showNotionDialog` routes through `showNotionCustomDialog`; `showNotionSheet` uses `NotionMotion.sheetStyleOf(context)`.

Owners applying motion: conversation (A) — newest-message reveal, send morph (`NotionMorphSwitcher(bounce: true)` + `NotionPressable(bounce: true, hapticOnTap: true)`), `NotionTypingDots` in `NotionSizeReveal`, delayed history loaders, `ConversationMotion.reduced` delegating to `NotionMotion.reduced`; inbox (B) — `NotionSkeleton` rows, `NotionEntranceScope` first-screen stagger, `NotionFadeThrough` on filter change, `NotionPop` + `NotionAnimatedCount` badges, `NotionRowHighlight` for moved rows, `showNotionPopover` for the network selector; settings/dialogs (C) — adaptive dialog/sheet helpers through `showNotionCustomDialog`/`sheetStyleOf`/`menuStyle`, delayed-reveal `future_loading_dialog`; onboarding/hub (D) — `NotionStaggeredColumn` on intro/sign-in, skeletons, `NotionPulse` for calls.

## Transcript folding and focused playback — 2026-10-21

`TranscriptPanel` measures the result at its rendered width, text scale,
locale and direction. Up to five lines stay visible; longer results show
three lines with Show more / Show less. Copy always uses the full result.
Expansion resets when the result is replaced.

`NotionMediaPlaybackControls` is a presentation-only transport with position,
duration, playing, speed and callbacks. It owns no decoder or media lease.
`NotionMediaActionsButton` groups secondary `NotionMediaAction`s in a sheet;
it dismisses the sheet before invoking the selected action.
Voice, video and round playback retain their existing media ownership and
playback coordination. Focused playback uses `NotionMediaColors.stageScrim`.
Device playback remains a separate acceptance check.

## Glass and rounded surfaces — 2026-10-19

The floating dock's language is now the standard surface (DESIGN.md "Glass" and "Radius"). Additive API from `package:fluffychat/ui/notion/notion.dart`; existing signatures are unchanged.

- Radius scale (values changed, names kept): `NotionRadius.{xs 6, sm 10, md 16, lg 20, xl 28, field 26, pill, avatar = pill}` with `xsAll, smAll, mdAll, lgAll, xlAll, pillAll, avatarAll, rowAll, fieldAll, sheetTop`; `NotionTokens.avatarRadius` = pill (avatars are circles); `AppConfig.borderRadius` = 16. Shapes: `NotionShapes.{pill, xs, sm, md, lg, xl, row, sheet}`.
- Glass tokens: `context.notion.glass.{tint, dockTint, overlayTint, border, blurSigma}`, `NotionGlass.{dockRadius, panelRadius, dialogRadius, sheetRadius, floatingInset}`; `NotionTokens.copyWith(glass:)` now keeps the glass tokens.
- `NotionGlassSurface(..., overlay:, repaintBoundary: true)` — `overlay` uses `overlayTint` and blurs only while its route is settled.
- `NotionGlassPanel(child:, borderRadius:, padding:, tint:, overlay: true, blur: true)`, `NotionGlassMenuRow(title:, leading:, trailing:, selected:, onTap:, style:, semanticsLabel:)`, `NotionGlassDivider(vertical: true)`, `NotionGlassPill(icon:, label:, onPressed:, tooltip:, selected:, blur: false, trailing:)` — `notion_glass.dart`; `NotionPillTabIndicator(color:, inset:)` — `notion_theme.dart`.
- Behaviour changes: `NotionDialog`, `showNotionSheet` and `showModalActionPopup` present glass panels; `NotionScaffold(children:)` scrolls under a glass header; the network selector is a glass panel with `NotionGlassMenuRow`s. Theme: buttons, chips, icon buttons, FAB, segmented buttons, search bars and navigation indicators are pills; inputs use `fieldAll`; menus/snackbars `lg` + hairline; dialogs `xl`; sheets `sheetTop` (xl); dialogs and sheets use the dock's `surface` fill; tabs show a pill indicator without the divider.


## Conversation activity — 2026-10-23

`lib/personal/ui/conversation_activity_widgets.dart` supplies
`ConversationActivityBuilder(client:, rooms:, builder:)`,
`ConversationActivityStatus(client:, rooms:, activity:, sourceLabels:)` and
`ConversationActivityAvatar(activity:, child:)`. The builder owns and disposes
its model; its narrow updates do not rebuild timeline message rows. Typing is
received from every selected room and deduplicated by Matrix user for display;
source labels retain every originating network. Problems take precedence over
activity. `NotionCompactChatHeader` now preserves child status semantics.

`ConversationActivity` uses the existing sync streams with one-shot expiry.
`ConversationActivityReceipts` records session receipt times once per client,
pinned before initialization by ClientManager/ClientStartup; PersonalClient is
an idempotent fallback owner. No polling, HTTP presence requests or additional
persistent store. Online has a conservative five-minute freshness limit.
Native Matrix presence is eligible by default; bridged puppet presence is
excluded without independently verified native provenance. Unknown is hidden,
never synthesized as offline. Legacy profile presence uses the same policy.

Implementation and verification: `docs/personal/conversation-activity-implementation-2026-10-23.md`.
