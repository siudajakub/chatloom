# Notion dark v2 design system

The rules for any UI in `client/`. It covers the tokens, the primitives, how
legacy Material widgets map to them, and how the rules are enforced. If a
value or widget you need is missing, add it to `lib/ui/notion/` (with a
golden) instead of writing a one-off in the screen.

Import everything from one barrel:

```dart
import 'package:chatloom/ui/notion/notion.dart';
```

## Why it looks like this

ChatLoom is a text-first messenger. The look follows Notion's dark mode:
warm near-black page, flat grey surfaces, one neutral text colour, no
elevation. Colour comes from one place, the user's accent and colour
intensity (see Colour system): Messenger-blue own bubbles, badges, toggles
and links by default, calmer or louder on request. Since 19 October 2026 every surface speaks the
language of the floating inbox dock (see Glass and Radius): translucent glass
with a hairline on chrome and overlays, pills for controls, generous rounded
corners everywhere. Nothing is square. Hierarchy comes from type weight and
muted secondary text, not from colour or shadow. The accent and intensity
change only the palette roles (`colors.accent`, `context.notion.palette`);
incoming messages, status colours and identity never depend on them. Light mode uses the same roles with a paper palette, so any
code that reads roles works in both.

The logo uses the same language: two glass speech bubbles, Messenger blue
(`#0A7CFF`) over cyan (`#06B6D4`). It never follows the user's accent. Show it
through `AppConfig.logoAsset` (the glass mark) or
`AppConfig.logoSilhouetteAsset` (a white silhouette to tint), never as a
hand-made copy. The rules, files and generator are in
[`docs/brand/BRAND.md`](docs/brand/BRAND.md).

## Tokens

All tokens live in `lib/ui/notion/notion_tokens.dart`.

### Colours: `context.notion.colors` (theme-dependent)

| Role | Dark | Use for |
|---|---|---|
| `background` | `#191919` | page, app bar |
| `surface` | `#252525` | cards, chips, input fill; the dock tone of menus, dialogs, sheets and snackbars |
| `selected` | `#2F2F2F` | selected/pressed rows, highest container |
| `border` | `#383838` | dividers, outlines, input borders |
| `text` | `#E8E7E5` | primary text and icons |
| `textSecondary` | `#AAAAA5` | subtitles, labels, metadata |
| `textTertiary` | `#7F7F7B` | placeholders, disabled |
| `cover` | `#33312B` | page cover band |
| `accent` / `onAccent` | from the palette | accent as a foreground on the page (links, active icons, typing line, cursor, sliders); = text for Graphite. Filled controls use `palette.accentFill` |
| `danger` `success` `warning` `info` | red/green/amber/blue | status only, never decoration |
| `scrim` | 60% black | modal barrier |
| `NotionMediaColors.scrim` / `stageScrim` / `onScrim` | 45% / 72% black, white | over video frames only (round pills and glyphs, media stage barrier); fixed in both themes |

Message bubbles use the `ConversationBubbleColors` extension
(`ConversationBubbleColors.of(context)`); it is registered by `NotionTheme`,
which takes the own side from the palette (`outgoing`, `outgoingText`,
`outgoingGradient`).

### Colour system: `context.notion.palette` (`notion_appearance.dart`)

The user picks an accent preset (`NotionAccent`: blue, the default and
Messenger's, violet, pink, red, orange, green, teal, graphite) and an
intensity (`NotionIntensity`) in Settings → Appearance. `ThemeController`
stores them (`AppSettings.appearanceAccent` / `appearanceIntensity`) and
rebuilds the theme in the same frame; `NotionTheme.build(brightness,
appearance)` resolves a `NotionPalette` once per theme, so widgets only read
roles (no contrast work per build or per scroll frame).

| Intensity | Own bubble | Accent | Letter avatars | Network marks |
|---|---|---|---|---|
| `muted` | grey with a 16 % hint of the hue, grey text | desaturated | grey | monochrome |
| `balanced` (default) | solid accent, a little deeper, white text | the hue | tinted per name | monochrome |
| `vivid` (Messenger) | accent gradient (hue → `gradientEnd`), white text | the hue, saturated | saturated per name, white initials | brand colours |

`graphite` + `muted` is exactly the original grey Notion look.

| Role | Use for |
|---|---|
| `accent` / `onAccent` | foreground accent (also `colors.accent`, `colorScheme.primary`) |
| `accentFill` / `onAccentFill` | filled accent controls: unread badges, send button, switch tracks, checkboxes, primary buttons, FAB, `badgeTheme` |
| `accentTint` | soft opaque accent background: selected tabs, chips, segments, list tiles, navigation indicators |
| `bubble`, `bubbleGradient`, `onBubble` | own bubble fill (gradient in Vivid; `bubble` is the solid stand-in for quotes) and its text; links in own bubbles take `onBubble`, underlined |
| `avatar(name)` | `NotionInitialAvatar` background/initials, stable per name (8 hues) |
| `network(key)` | brand colour of a network mark in Vivid, null otherwise (`NotionNetworkGlyph`) |

Contrast is computed, not hand-picked: `NotionPalette.fillFor` moves a hue's
lightness until white text reaches 4.5:1, `inkOn` until the hue reads on the
page; network marks need 3:1 (graphics). `test/notion/appearance_test.dart`
checks every preset × intensity × brightness. Gradients exist only on Vivid
own bubbles (static per bubble, never scroll-driven); every other surface
stays flat. Status colours (`danger`, `success`, ...) never follow the
accent.

### Message bubbles: `NotionBubble.*` (const)

Bubbles follow Messenger: `outer 18` corners (a one-line bubble reads as a
pill), `joined 4` on the sender side where a bubble joins its group,
`padding` 12 × 8, `groupGap 2`, `seriesGap 14`, `avatar 28` in an
`avatarSlot 36`. Use `ConversationBubble.radiusFor(outgoing:, position:)` for
media inside a bubble.

A reply is drawn Messenger style, never as a stripe inside the bubble:
`ConversationReplyCaption` (reply arrow + "Anna replied to you") above a
`ConversationReplyQuote` pill (callout, at most `quoteMaxLines` 2, optional
thumbnail), passed as `ConversationBubble(quote:)`. The bubble covers the
quote's bottom `quoteOverlap` 12 and wins taps there; the visible quote opens
the original. A reply always starts a new group. Quote colours come from
`ConversationReplyQuote.colorsFor(side:, page:, muted:)`: an opaque blend
halfway from the original's bubble to the chat background, with text that
reaches 4.5:1 (it also covers private chat palettes).

Reactions follow Messenger: one pill per emoji (`NotionReactionChip`, no
square frame) in `NotionReactionOverlap`, which lifts the row over the
bubble's bottom edge by `NotionReactions.overlap` on the sender side. A
ring of the chat background separates the chip from the bubble; own
reactions get a soft tint and hairline. Long-press any message opens
`showConversationMessageMenu` (`lib/pages/chat/conversation_message_menu.dart`):
a scrim, a lifted copy of the bubble at its own place, the
`NotionReactionBar` above (quick reactions of the network, "+" for the full
picker, slide-to-react while still holding) and a `NotionGlassPanel` card of
`NotionGlassMenuRow` actions below. "+" grows the bar in place into the
reaction picker (Telegram): the panel's clip morphs from the pill on
`emphasized` (`medium`), the bar and card recede, the content fades in,
glass blurs once it rests, and its search keeps the panel above the
keyboard. The picker offers exactly what the network takes: a declared
`allowed_reactions` (every Telegram chat) is the whole set, in its order
and spelling, with no skin tones; otherwise every emoji, the chat's quick
reactions on top. A chat whose whole set fits the bar gets no "+", a chat
or message that takes no reaction gets no bar and no double tap. Reaction
keys compare without variation selectors (`normalizeReactionKey`; bridges
spell `👍️`, pickers `👍`) and always go out in the network's spelling. Double tap reacts with the network's
first quick reaction and plays `NotionReactionBurst` at the finger. There is
no multi-selection.

A jump to a message (reply quote, pinned message, notification) flashes its
bubble once (`ConversationFlash`, Telegram's unselect): the bubble's text
colour at `ConversationBubble.flashOpacity` over the fill rises in `quick`,
holds `ConversationMotion.flashHold` (1 s) and fades in `long`; under
reduced motion it appears and disappears without a fade. The highlight
never stays.

Days are separated by a centred `ConversationDayChip` (opaque `surface`
pill, `captionMuted`). While the user scrolls, the same chip floats under
the header with the day of the topmost message; it fades (so it is opaque,
not glass), stays `ConversationMotion.dateHold` (0.5 s) after the list is
idle and hides while that day's own chip is right under it. Tapping either
chip opens `showNotionDatePicker` and jumps to that day's first message
(Telegram). Unread messages
start under a "N unread messages" `ConversationUnreadDivider`; a chat with
unread messages opens with it just under the header (a read marker beyond
the loaded page loads the history around it), and the jump button goes
there first. While the chat has unread mentions an accent "@" pill with a
count sits above the jump button (`ConversationMentionButton`). In-chat
search turns the header into the search field and the composer slot into
the "3 of 17" bar (`lib/pages/chat/conversation_search.dart`); each step
scrolls the open timeline and flashes the hit.

Text on colours you do not control (private chat palettes, chat
backgrounds) goes through `NotionContrast`: `on(bg)` for body text,
`readable(bg, preferred)` for muted text, never a hard-coded black or white.
Over a wallpaper, time, names and reply captions sit in a
`ConversationMetaChip` of the page colour (`metaChipOpacity` .8).

`ColorScheme` is derived from the same roles (`surface` = background,
`onSurfaceVariant` = textSecondary, `error` = danger, and so on), so
`Theme.of(context).colorScheme.*` is also acceptable. Prefer the Notion
names in new code because they say what the colour means.

### Typography: `NotionType.*` (const) or `context.notion.typography.*` (coloured)

| Token | Size / weight | Use for |
|---|---|---|
| `micro` | 11 | badges, dense timestamps |
| `caption` | 12 | metadata, helper text |
| `footnote` | 13 | row subtitles |
| `callout` | 15 | dense body: dialogs, menus, property labels, buttons |
| `body` | 16 | default text, row titles, messages |
| `bodyStrong` | 16 / w600 | emphasis inside body |
| `headline` | 17 / w600 | header bars, dialog and sheet titles |
| `heading` | 20 / w600 | section headings inside a page |
| `title` | 30 / w700 | page title, one per screen |

`typography` adds `captionMuted`, `footnoteMuted`, `calloutMuted` and
`sectionLabel`, coloured with `textSecondary`. `TextTheme` maps onto the same
scale (`bodyLarge` = body, `bodyMedium` = callout, `titleMedium` = headline,
`titleLarge` = heading, `headlineMedium` = title).

### Spacing: `NotionSpace.*` (const)

`xxs 4 · xs 8 · sm 12 · md 16 · lg 20 · xl 24 · xxl 32`. `inset` (20) is the
page gutter; `NotionSpace.page` is the horizontal page padding. Also
`row`, `dialog`, `sheet` presets, and `listGap` (4) / `listItem` (half of it
above and below) between rows with rounded highlights (inbox).

### Radius: `NotionRadius.*` and `NotionShapes.*` (const)

The rounded scale of the dock. The smallest radius in the app is `xs`;
`BorderRadius.zero`, a bare `RoundedRectangleBorder()` or a radius below 6 is
a lint error (`square-corner`).

| Token | Value | Use for |
|---|---|---|
| `xs` | 6 | checkboxes, inline code, thin tracks |
| `sm` | 10 | small thumbnails, tags, media grid tiles, quote thumbnails |
| `md` | 16 | cards, callouts, multi-line inputs, media, `AppConfig.borderRadius` |
| `rowAll` | = md | selected/pressed row highlight (inbox rows, settings categories, menu rows) |
| `lg` | 20 | menus, popovers, snackbars, tooltips, pinned cards |
| `xl` | 28 | dialogs, top corners of bottom sheets (`sheetTop`) |
| `field` | 26 | every text input and the composer (a pill at one line) |
| `pill` | 999 | buttons, chips, icon buttons (a circle), badges, toggles, the dock |
| `avatar` | = pill | avatars are circles (`NotionTokens.avatarRadius`) |

`BorderRadius` constants: `xsAll smAll mdAll lgAll xlAll pillAll avatarAll
rowAll fieldAll sheetTop`. Shapes for `shape:` arguments: `NotionShapes.pill`
(`StadiumBorder`), `.xs .sm .md .lg .xl .row .sheet`. Prefer a bounded radius
(`lg`, `xl`, `field`) over `pill` for anything that can grow past one line: a
radius larger than half the height is drawn as a pill anyway.
Message bubbles keep their own geometry (`NotionBubble`).

### Sizes: `NotionSize.*` (const)

`touchTarget 48`, `headerHeight 56`, `rowMinHeight 52`, icons
`iconSm 16 / icon 20 / iconMd 22 / iconLg 24`, avatars `24 / 40 / 56`,
`dialogMaxWidth 420`, `contentMaxWidth 720`.

Inbox conversation rows default to 75% density: 42 dp avatars, 15 dp
vertical padding and 6 dp between name and preview (a 72 dp row at standard
text scaling, Telegram's height; 96 dp at 100%). Rows sit `NotionSpace.listGap`
(4 dp) apart: each list item keeps `NotionSpace.listItem` (half the gap above
and below) inside its `NotionListMotionItem` and outside the swipe action, so
adjacent unread or selected highlights never touch, reorder offsets include
the gap and the swipe pill matches the highlight. Names and
previews retain 87.5% of their original type size for readability. Settings →
Appearance → Chat list offers a 65–100% row scale, avatars, previews, network
badges, timestamps and unread highlighting. Rows retain a 48 dp minimum tap
target, grow with accessible text sizes, and preserve unread counts and spoken
labels when secondary visuals are hidden. Unread conversations use `palette.accentTint` with contrast-checked
accent names/timestamps, bold names and a count or manual-unread dot.
Selected conversations retain the selected surface; muted conversations keep
neutral surfaces and badges but retain bold unread names. Read state therefore
remains identifiable without relying on colour. Rows grow with text scaling.

### Transitional static API

`NotionTokens.background`, `.text`, `.radius`, `.body` and the other static
members from v1 still compile. They are dark-only constants. Do not use them
in new code; read `context.notion` instead.

## Primitives

| Widget | Use for |
|---|---|
| `NotionScaffold(title:, pageTitle:, onBack:, actions:, children:/body:)` | every page: header, optional large title, centred column with gutter |
| `NotionSectionHeader(title:, trailing:)` | muted label above a group of rows |
| `NotionListRow(leading:, title:, subtitle:, trailing:, onTap:)` | navigation/setting row |
| `NotionPropertyRow(label:, value:, onTap:)` | label → value pair |
| `NotionChoiceRow(title:, subtitle:, selected:, onTap:)` | one option of a single-choice list (history visibility, join rule, permission level): accent check on the selected option, `onTap: null` disables; instead of `RadioListTile`/`DropdownButton` (`notion_choice_row.dart`) |
| `NotionIconButton(icon:, label:, onPressed:)` | header and inline icon actions (label is the tooltip) |
| `NotionButton(label:, onPressed:, variant:)` / `.primary` / `.ghost` / `.destructive` | every text button; `icon:`, `expand:`, `busy:` |
| `NotionDialog` + `showNotionDialog(...)` / `showNotionConfirmDialog(...)` | modal questions and confirmations (glass panel, `xl` corners) |
| `NotionDialogFrame`, `NotionAlertDialog(icon:, title:, content:, actions:)`, `NotionDialogSubmit` | the glass dialog shell, `NotionDialog` with widget slots (the replacement for `AlertDialog.adaptive`, never Cupertino on macOS), Return-to-confirm while nothing inside has focus (`notion_dialog_frame.dart`); the legacy helpers (`showOkCancelAlertDialog`, `showTextInputDialog`, `showFutureLoadingDialog`, `showModalActionPopup`) are built on them |
| `NotionSheet` + `showNotionSheet(...)` | bottom sheets and pickers (glass panel, `sheetTop` corners). On a wide desktop window (macOS/Linux/Windows, width ≥ `NotionSize.sheetDialogMinWidth` 720) the same content opens as a centred glass dialog (`NotionDialogFrame`, ≤ 480 × 720, no drag handle, dialog motion); phones and tablets keep the bottom sheet. `asDialog:` overrides, `notionSheetAsDialog(context)` tells which |
| `NotionEmptyState(icon:, title:, message:, action:)` | empty lists, soft errors |
| `NotionCallout(icon:, title:, message:, actionLabel:, onAction:, onDismiss:, tone:)` | inline fixable status (inbox encryption/sync notice, connection retry); `tone` colours only the icon |
| `NotionStatusPill(label:, tone:)` | read-only status in a row or header (network Connected / Needs attention / Disconnected); `tone` colours only the dot, changes fade through |
| `NotionDeliveryTick(state:, color:, readColor:)` | ticks of an own message beside its time and before the time of an inbox row whose last message is own (Telegram): clock sending, ✓ sent, ✓✓ delivered to the network, ✓✓ in the accent once read. Metadata colour except read; a state change fades once (`NotionLazySwitcher`), no ticker on first build; failures keep their own "Not sent" line (`notion_delivery_tick.dart`) |
| `ConversationBubble(quote:)`, `ConversationReplyQuote`, `ConversationReplyCaption`, `ConversationMetaChip` | message bubbles and Messenger-style replies (`lib/pages/chat/conversation_bubble.dart`, see Message bubbles) |
| `NotionTextField(label:, hint:, helper:, error:, ...)` | text input with the label above |
| `showNotionDatePicker(context:, initialDate:, firstDate:, lastDate:)`, `NotionDatePicker` | a month calendar in a Notion sheet; picking a day closes it and returns the day (jump to date in a conversation) |
| `NotionCompactChatHeader`, `NotionInitialAvatar` | chat header, letter avatar |
| `NotionReactionChip`, `NotionReactionOverlap`, `NotionReactionBar`, `NotionReactionBurst` | reaction pills under a bubble, the long-press reaction pill, the double-tap burst (`notion_reactions.dart`, tokens `NotionReactions.*`) |
| `NotionEmojiPicker(sections:, onSelected:, search:, usage:, selected:, tones:, onTone:, categoryBar:)` + `NotionEmojiSection`, `NotionEmoji`, `NotionEmojiSearch`, `NotionEmojiTones` | every emoji picker (composer tab, reaction picker, settings): a search pill that never moves, a category bar of 48 pt cells that follows the scroll and jumps (far jumps land a screen short and glide), sticky opaque section headers, a fixed-extent grid of 30 pt glyphs (`NotionEmojiSizes`, ≥ 5 columns, glyphs ignore text scale) that press like buttons, own reactions on the bar's accent circle, skin tones on long-press (tap or slide onto a tone; remembered per emoji by the caller). Search is on-device and instant: every word must match, exact > prefix > substring, ties by the user's use, then popularity, then catalogue order; case, Latin diacritics and `:shortcodes:` fold; a pasted emoji finds itself in any spelling or tone; Enter picks the first result; categories and results fade through. No glass inside (it scrolls); data and callbacks only (`notion_emoji_picker.dart`, `notion_emoji_search.dart`). The app's catalogue, shared recents and remembered tones: `ChatLoomEmojiPicker`, `showEmojiPickerSheet` (`lib/personal/emoji/`) |
| `NotionGlassSurface`, `NotionGlassBar`, `NotionGlassScope` | glass chrome and overlays (see Glass) |
| `NotionGlassPanel`, `NotionGlassMenuRow`, `NotionGlassDivider`, `NotionGlassPill` | the dock's language: glass menus, dialogs, sheets, pill buttons (see Glass) |
| `showNotionMenu(context, entries:, anchor:, position:, alignEnd:)` + `NotionMenuEntry(value:, label:, icon:/leading:, subtitle:, enabled:, destructive:, selected:)` / `.divider()`; `NotionMenuButton(icon:, label:, entries:, onSelected:)` | every menu: header ⋯, overflow, row and composer menus. A glass panel of `NotionGlassMenuRow`s that grows from its anchor (the button, or a desktop click `position`), below it near the top of the screen and above it near the bottom; the same panel on phone and desktop; Escape/back/outside tap dismiss. A second step (Mute… → durations, Transcribe again → language) opens a new menu at the same anchor instead of a cascading submenu. Never `PopupMenuButton`/`showMenu`/`MenuAnchor` in new code (`notion_menu.dart`) |
| `NotionLinkPreviewCard(title:, description:, site:, image:, fill:, textColor:, mutedColor:, onTap:)` | a bridged link preview inside a text bubble: opaque card, image on top (1:1 to 16:9), site, title, description; colours from the bubble, no blur, never fetches the URL (`notion_link_preview.dart`) |
| `NotionMediaPlaybackControls`, `NotionMediaActionsButton` | Focused media transport over `stageScrim`: play/pause, time, seek, speed; secondary actions in one menu. Data and callbacks only; `seekControl` accepts a voice waveform instead of the slider. |
| `NotionEditorTopBar`, `NotionEditorDock` + `NotionEditorTool`, `NotionEditorPanel`, `NotionEditorChoices` + `NotionEditorChoice`, `NotionEditorSwatches`, `NotionEditorSlider`, `NotionEditorBadge`, `NotionEditorProgress` | the photo/video editor's chrome on the dark media stage (send preview → Edit): glass pills and the primary Done on top (title fades through per tool), one glass dock of icon + label tools whose cells rise in staggered (selected on `accentTint`), glass `xl` option panels above it (ratio/brush/adjustment chips, brush swatches that spring larger when chosen, labelled sliders), a scrim badge for the trim length and an export panel with progress and Cancel. Data and callbacks only; the engine is `pro_image_editor`/`pro_video_editor`, skinned in `lib/personal/media/editor/media_editor_skin.dart` (`notion_media_editor.dart`) |
| `NotionSwipeAction(startToEnd:, endToStart:, child:)` + `NotionSwipeActionSide(icon:, label:, onCommit:)` | Telegram-style row swipe (inbox: archive / mark read): the row follows the finger over an opaque `accentTint` pill whose icon scales in, arms at 30 % of the width with one `NotionHaptics.selection()`, commits on release and springs back (`snappy`, instant under reduced motion); touch only, never from the back-gesture edges, off under a screen reader (custom semantics actions instead); no controller until the first swipe (`notion_swipe_action.dart`) |
| `NotionContentLoopGate(enabled:, child:)`, `NotionContentLoop.isVisible(box, screen)` | content loops (animated stickers, GIF images, Lottie): a `TickerMode` that is on only while at least half of the child is in its viewport, tickers are on and motion is not reduced; `enabled` carries the caller's "autoplay" policy. `MxcImage` gates animated media itself; `InlineLoopVideo` uses the same visibility rule. Gated children show their first frame without a fade (`notion_content_loop.dart`) |
| `NotionPressable`, `NotionEntrance`, `NotionSkeleton`, `NotionFadeThrough`, `NotionPop`, ... | motion (see Motion) |
| `NotionTapTarget(onTap:, onLongPress:, onSecondaryTap:, behavior:, child:)` | a `GestureDetector` replacement for custom tap targets with pointer affordances (Mac): the click cursor while `onTap` is set, and a right click doing what the long press does. Every long-press-only action needs a right-click equivalent; `NotionPressable(onLongPress:)` gets one too. Non-visual, no golden (`notion_pressable.dart`) |

Each primitive has a golden in `test/notion/goldens/primitives/`.

## Glass: the dock's surface language

Glass is a translucent tint over a backdrop blur, framed by a hairline and
rounded corners. The floating inbox dock is the reference: its tint, hairline,
pill shape and press motion are the standard for every surface. Colours stay
the Notion roles; glass changes only translucency, corners and motion.

### Where blur is allowed

Real blur (`BackdropFilter`) is expensive on the Pixel. It is allowed only on
surfaces that stay still while content moves beneath them:

| Surface | Code |
|---|---|
| Top header (inbox, conversation, merged chat, every `NotionScaffold` list page) | `NotionGlassBar` (inbox in a `PinnedHeaderSliver`; `AppBar(backgroundColor: Colors.transparent, flexibleSpace: NotionGlassBar())` with `extendBodyBehindAppBar: true`) |
| Floating bottom dock (inbox) | `NotionGlassSurface(dock: true, borderRadius: NotionGlass.dockRadius, border: ...)` inset from the edges |
| Composer strip (conversation) | `NotionGlassBar` behind the input row |
| Menus and popovers (network selector, `showNotionMenu`) | `NotionGlassPanel` inside `showNotionPopover` |
| Dialogs | `NotionDialog` (a `NotionGlassPanel` with `NotionGlass.dialogRadius`) |
| Bottom sheets and action sheets | `showNotionSheet`, `showModalActionPopup` (a `NotionGlassPanel` with `NotionGlass.sheetRadius`; on a wide desktop window `showNotionSheet` is a dialog with `NotionGlass.dialogRadius`) |
| Floating pills over content | `NotionGlassPill(blur: true)` |

An overlay (`overlay: true`, the default of `NotionGlassPanel`) keeps one
glass state for as long as it moves, because a `BackdropFilter` inside an
animating `Opacity` reads an empty layer and a scaled one changes its blur
radius (both flash):

- Popovers and menus (`showNotionPopover`) blur from their first to their
  last frame. The route neither fades nor scales; `NotionGlassReveal` grows
  the panel's clip out of the anchor (Telegram's popup: the background
  expands from the anchor, the rows fade in inside it) and collapses it back
  on exit. Only the clip and the opacity of the content above the blur
  animate.
- Bottom sheets blur from their first frame: their slide and drag only
  translate them.
- Dialogs fade and scale, so they blur only once their route has settled and
  paint the opaque tone composited over their barrier while they grow or
  leave; settling changes no colour, only lets the blurred content appear.

Switching a surface's glass state flips `BackdropFilter.enabled` and the
fill in place; the content is never remounted (a remount replayed a
popover's row entrances the moment it settled).

A glass surface is one surface: anything attached to it (a popover pointer,
a tab, a badge that overlaps its edge) either lives inside the same
`NotionGlassSurface` clip or is opaque. A separate translucent shape next to
glass shows unblurred content and a second tint. Menus and popovers have no
pointer (Telegram, Messenger); they grow from their anchor instead.

Never blur inside scrolling content (rows, bubbles, cards, chips, grid
tiles): use the opaque roles plus the hairline, `NotionGlassPanel(blur:
false)` or `NotionGlassPill(blur: false)` (the default). Theme-level Material
overlays (`PopupMenuButton`, `MenuAnchor`, `AlertDialog`, `SnackBar`, legacy
bottom sheets, Material date/time pickers) cannot blur; the theme gives them
the same radius, hairline and the dock's `surface` fill, opaque, with elevation
0 (no shadow).

### Tokens: `context.notion.glass`

| Token | Dark | Light |
|---|---|---|
| `tint` (bars) | background at 60% | background at 72% |
| `dockTint` (dock, pills) | surface at 58% | surface at 72% |
| `overlayTint` (menus, dialogs, sheets) | surface at 84% | surface at 90% |
| `border` (hairline) | white 10% | black 8% |
| `blurSigma` | 18 | 18 |
| `NotionGlass.dockRadius` / `panelRadius` / `dialogRadius` / `sheetRadius` | pill / lg / xl / sheetTop | |
| `NotionGlass.floatingInset` | 16 (dock, snackbars) | |

### Primitives

| Widget | Use for |
|---|---|
| `NotionGlassSurface(tint:, dock:, overlay:, borderRadius:, border:)` | the only blur primitive; `RepaintBoundary` built in |
| `NotionGlassBar(hairlineTop:, hairlineBottom:)` | full-width header and composer strip |
| `NotionGlassPanel(child:, borderRadius:, padding:, overlay:, blur:)` | menus, popovers, dialogs, sheets: tint + hairline + ink-ready `Material` |
| `NotionGlassReveal`, `NotionRevealClip` | the popover entrance: provided by `NotionPopoverRoute`, consumed by the first overlay surface below it (clip grows from the anchor, content fades, blur steady) |
| `NotionGlassMenuRow(leading:, title:, subtitle:, trailing:, selected:, onTap:)` | a 48 pt row in a glass menu with a rounded, inset highlight; `subtitle` is a muted second line |
| `NotionGlassDivider(vertical:)` | the dock's 1 × 36 separator; `vertical: false` is the inset hairline between menu sections |
| `NotionGlassPill(icon:, label:, onPressed:, selected:, blur:)` | a dock-style pill button: content presses inside the ink, the pill never scales |
| `NotionPillTabIndicator(color:)` | the theme's tab indicator: a pill behind the selected tab |

Rules:
- Use the primitives, never a raw `BackdropFilter` (the lint reports
  `backdrop-filter` outside `lib/ui/notion/`).
- Put a `BackdropGroup` around a page with more than one glass bar so the
  bars share one backdrop read (`NotionInboxPage`, `ChatPageWithRoom`).
- Content must scroll under a bar: add `MediaQuery.paddingOf(context).top`
  (or the bar height) to the scroll view's top padding, and the measured
  composer/dock height to its bottom padding. `NotionScaffold(children:)`
  does this itself; `NotionScaffold(body:)` keeps an opaque header.
- Press motion: scale the content inside the ink (`NotionPressable` inside the
  `InkWell`, as in the dock), never the blurred surface.
- The fallback is automatic: when the renderer is not Impeller
  (`ImageFilter.isShaderFilterSupported` is false: Skia, web, tests), when
  high contrast or reduced motion is on, or with
  `--dart-define=PERSONAL_GLASS=false`, the tint is painted opaque over the
  page background (`notionGlassOpaque(context, tint)`), i.e. the exact tone
  the glass shows over an empty page. The same tone is used by `blur: false`
  panels and pills and by overlays while their route animates, so glass and
  fallback never differ in colour.
  `NotionGlassScope(mode: NotionGlassMode.off)` forces the fallback for a
  subtree (low-end flag); `.on` forces glass (goldens). The lite mode
  (Battery Saver / Low Power Mode, see Motion rule 6) sets `off` app-wide.
- Text on glass uses the normal text roles; never lower its contrast to
  "show off" the blur.

| Instead of | Use |
|---|---|
| `BackdropFilter(filter: ImageFilter.blur(...))` | `NotionGlassSurface` / `NotionGlassPanel` |
| `AppBar(backgroundColor: color.withAlpha(...))` | `flexibleSpace: NotionGlassBar()` + transparent background |
| a translucent `Container` behind the composer | `NotionGlassBar` |
| `Material(elevation: 3)` floating dock | `NotionGlassSurface(dock: true, ...)` |
| `Material(color: surface, shape: RoundedRectangleBorder(...))` popover | `NotionGlassPanel` |
| `ListTile` rows with full-bleed highlights in a menu | `NotionGlassMenuRow` |
| a `Container(width: 1, color: divider)` separator | `NotionGlassDivider` |
| a floating `FloatingActionButton.small`/chip over content | `NotionGlassPill` |
| `BorderRadius.zero`, `RoundedRectangleBorder()`, `BorderRadius.circular(4)` | `NotionRadius.*` / `NotionShapes.*` |

## Motion

Motion makes the app feel fast and physical, never busy. Everything lives in
`lib/ui/notion/` and is exported by the barrel; screens never import
`flutter_animate` or `skeletonizer` (the lint reports `motion-import`).

Taste: fast, decelerating, critically damped. Only small "reward" elements
bounce (badges, reactions, the send button, empty-state icons). Rows, pages,
dialogs and sheets never bounce.

### Tokens: `NotionMotion.*` (`notion_motion.dart`)

| Token | Value | Use for |
|---|---|---|
| `instant` | 90 ms | press-down, exits of micro elements |
| `quick` | 140 ms | icon swaps, colour/selection tweens |
| `short` | 200 ms | fades, badges, small reveals (= `ChatLoomThemes.animationDuration`) |
| `medium` | 260 ms | entrances, dialogs, size reveals |
| `long` | 320 ms | sheets, page push (`forward`); pop is `reverse` 220 ms |
| `gestureTravel` · `gestureCommit` | 1.0 · `easeOutQuad` | Android predictive back: the page follows the finger, a release continues from there (see Page motion) |
| `stagger` / `staggerCap` | 28 ms / 10 | per-item delay, never more than 10 steps |
| `loaderGrace` | 250 ms | a loader stays invisible this long |
| `loopCap` · `liveLoopCap` | 30 s · 2 min | longest run of a spinner, shimmer or typing dots · of a live-state `NotionPulse`; then the loop rests on a static frame |
| `standard` | `Cubic(.2, 0, 0, 1)` | general tweens (= `ChatLoomThemes.animationCurve`) |
| `emphasized` | `Cubic(.05, .7, .1, 1)` | entrances, page enter |
| `exitFast` | `Cubic(.3, 0, .8, .15)` | exits |
| `snappy` / `smooth` / `bouncy` | `SpringDescription`s | press release and toggles / dialogs and sheets / reward pops only |
| `snappyCurve` / `smoothCurve` / `bouncyCurve` | `NotionSpringCurve` | the springs as curves for tweens and switchers (`.duration` = natural length) |
| `springTo(spring, from, to, velocity:)` | `SpringSimulation` | interruptible `controller.animateWith(...)`, ends exactly on `to` |
| `rise` 8 · `riseList` 10 · `riseSheet` 12 | px | entrance travel |
| `pressButton` .96 · `pressIcon` .90 · `pressRow` .985 | scale | `NotionPressable` |
| `popFrom` .6 · `dialogFrom` .94 · `popoverFrom` .92 | scale | start scales |
| `refreshFrom` .5 | opacity | a list that changed view or network fades in from here, never from an empty frame |
| `sheetStyle` / `sheetStyleOf(context)` · `menuStyle` / `menuStyleOf(context)` | `AnimationStyle` | `showModalBottomSheet(sheetAnimationStyle:)`, `showMenu`/`PopupMenuButton(popUpAnimationStyle:)`; the `…Of(context)` forms honour reduced motion, use them |
| `reduced(context)` | bool | **the** reduced-motion check (Android "Remove animations", iOS Reduce Motion), also while the app is inactive (`NotionActivity`) |
| `of(context, d)` | Duration | `d`, or zero under reduced motion |
| `staggerFor(i)` | Duration | capped stagger delay |

`NotionHaptics.send()` / `.longPress()` (a light impact) and
`.selection()` (a selection click) are the only haptics: on send, on a
recognised long-press, and once per change of choice while the finger
scrubs (the reaction bar's hovered emoji, swipe-to-reply and inbox
swipe arming). Screens
decide; nothing buzzes by default.

### Primitives

| Widget | Use for | Example |
|---|---|---|
| `NotionPressable(child:, scale:, bounce:, onTap:, onLongPress:, hapticOnTap:)` | scale-on-press with spring release around any tappable; raw pointers, so it never steals taps; lets go when the finger drags past the touch slop | `NotionPressable(scale: NotionMotion.pressRow, child: InkWell(onTap: open, child: row))` |
| `NotionEntrance(child:, index:, rise:, slide:, scale:, afterRoute:, playKey:)` | one-shot fade + rise, waits for the page push, settles to identity | `NotionEntrance(index: 1, child: header)` |
| `NotionEntranceScope(child:)` | around a list: numbers entrances, plays only the first screenful, rows built later by scrolling never animate | `NotionEntranceScope(child: ListView(children: [for (final r in rows) NotionEntrance(playKey: r.id, child: Row(r))]))` |
| `NotionStaggeredColumn(children:)`, `NotionEntrance.stagger(list)` | a short stack of sections | `NotionStaggeredColumn(children: [title, body, actions])` |
| `NotionFadeThrough(child:)` | same slot, new state (title, filtered list, empty ↔ content); key each state | `NotionFadeThrough(child: Text(label, key: ValueKey(label)))` |
| `NotionMorphSwitcher(child:, bounce:, rotate:)` | glyph/button swaps (mic → send, idle → busy) | `NotionMorphSwitcher(bounce: true, child: Icon(icon, key: ValueKey(icon)))` |
| `NotionLazySwitcher(child:, style:, bounce:)` | the same fade / morph swap inside list rows: no controller until the child's key first changes, so rows built by scrolling cost no ticker (inbox rows) | `NotionLazySwitcher(child: Text(time, key: ValueKey(time)))` |
| `NotionAnimatedCount(count:, style:, format:)` | numbers that change: rolls up/down | `NotionAnimatedCount(count: unread, style: NotionType.micro)` |
| `NotionAnimatedSize(child:, duration:)` | a block whose size changes in place (dialog content, a validation error): `AnimatedSize` that snaps in one frame under reduced motion, because a zero duration trips a layout assertion on the next relayout | `NotionAnimatedSize(child: NotionFadeThrough(child: body))` |
| `NotionSizeReveal(visible:, child:, axis:)` | single element appearing/disappearing with size + fade (callout, reply preview, typing row) | `NotionSizeReveal(visible: error != null, child: NotionCallout(...))` |
| `NotionReappear(trigger:, child:, rise:)` | one slot that swaps between kept-alive states where a switcher would mount a second live copy (composer ↔ search bar, recorder ↔ composer): the incoming state rises and fades in on each `trigger` change, never on mount, same element throughout | `NotionReappear(trigger: searching, child: searching ? bar : composer)` |
| `NotionSwipeAction(startToEnd:, endToStart:)`, `NotionSwipeActionSide(dismisses:)` | Telegram row swipe: the row follows the finger, arms with a selection haptic and springs back; a side that `dismisses` (archive in a view the chat leaves) flies off and closes its slot before it commits, and comes back if the row is still there after a short hold. One tree shape at rest and in motion, so a swipe never remounts the row | `NotionSwipeAction(endToStart: NotionSwipeActionSide(icon: Icons.archive_outlined, label: 'Archive', dismisses: true, onCommit: archive), child: row)` |
| `NotionPop(child:, trigger:, visible:, bounce:)` | badges, reaction chips, dots: spring in, pulse on `trigger`, pop out | `NotionPop(trigger: count, child: badge)` |
| `NotionReactionBar(entrance:)`, `NotionReactionBurst(animation:)` | reward motion of reactions, driven by a route or controller animation: the bar springs out of the bubble corner (`barFrom` → 1, bouncy) and its emoji pop in staggered; the burst pops at the finger and floats away | `NotionReactionBar(reactions: r, entrance: route.animation, onSelected: react)` |
| `NotionShake(trigger:, child:)` | rejected input (wrong PIN) | `NotionShake(trigger: errors, child: field)` |
| `NotionRowHighlight(trigger:, child:)` | one-shot `selected` flash of a row that moved or changed (the move itself is `NotionListMotion`) | `NotionRowHighlight(trigger: room.lastEventId, child: row)` |
| `NotionListMotion(order:, epoch:, background:, child:)` + `NotionListMotionItem(index:, child:)` | a lazy list whose order changes (inbox, search results): rows that moved glide from their old place on `snappy` (FLIP: paint offset only, no relayout, velocity kept when the list changes again), new rows fade in `short`, rows below a removed row close the gap; a moving row paints `background` behind itself so it slides under the rows it passes. Scrolling never animates; a new `epoch` (view, network, end of load), reduced motion or tickers off take the new layout as is. Items sit directly in the delegate (`addRepaintBoundaries: false, addSemanticIndexes: false`; the item adds both), so taps follow the drawn row. Non-visual at rest, no golden | `NotionListMotion(order: ids, epoch: (view, network), background: page, child: ListView.builder(addRepaintBoundaries: false, addSemanticIndexes: false, itemBuilder: (c, i) => NotionListMotionItem(key: ValueKey(ids[i]), index: i, child: Row(ids[i]))))` |
| `NotionSkeleton(enabled:, child:)`, `.sliver`, `NotionSkeletonRow()`, `NotionSkeleton.keep/ignore/unite` | loading state with the final layout; cross-fades to content | `NotionSkeleton(enabled: loading, child: Column(children: [for (var i = 0; i < 8; i++) const NotionSkeletonRow()]))` |
| `NotionDelayedSpinner(maxSpin:)`, `NotionDelayedReveal(child:)` | loaders that only show after `loaderGrace`; the spinner freezes on its last frame after `maxSpin` (`loopCap`) | `if (busy) const NotionDelayedSpinner()` |
| `NotionShimmerLines(color:, lines:, maxDuration:, onRest:)` | text that is on its way inside a bubble (transcripts); one `CustomPaint` behind a `RepaintBoundary`, bubble foreground colour, static under reduced motion and after `maxDuration` (`onRest` lets the owner explain a long wait) | `NotionShimmerLines(color: bubbleText, lines: 2)` |
| `NotionTypingDots(size:)`, `NotionPulse(child:, color:, maxDuration:)` | loops: typing (rests after `loopCap`), live call/recording (rests after `liveLoopCap`; toggling `enabled` restarts it) | `NotionPulse(color: colors.danger, child: callButton)` |
| `showNotionCustomDialog(context:, builder:)`, `NotionDialogRoute`, `NotionDialogTransition` | any dialog: barrier fade, scale .94 → 1 on `smoothCurve`, faster exit | `showNotionCustomDialog(context: context, builder: (_) => NotionDialog(...))` |
| `showNotionPopover(context:, builder:, alignment:)`, `NotionPopoverRoute` | anchored panels/menus: the `NotionGlassPanel` in `builder` grows out of `alignment` (the anchor) with its blur on, content fades in; collapses back in `quick`; instant under reduced motion. Content without a glass panel appears without motion | `showNotionPopover(context: context, alignment: Alignment.bottomRight, builder: panel)` |
| `AfterRouteTransition(child:)` | heavy content after the push; now fades the child in | as before |
| `NotionMediaRoute(builder:)`, `NotionMediaHero(tag:, sourceRadius:)`, `NotionDismissDrag`, `NotionDismissTransform`, `NotionMediaBackdrop`, `NotionMediaChrome`, `NotionDoubleTapZoom`, `notionFitMedia(...)` | full-screen media (Telegram): the photo flies out of its thumbnail and back (straight path, corners square off), follows a downward swipe with the backdrop and chrome fading and springs back below the threshold, double tap zooms into the tapped point, a tap toggles the chrome. A thumbnail that opens the viewer is a `Hero(tag:, createRectTween: NotionMediaHero.rectTween)` | `showImageViewer(context, event, heroTag: ('details-media', id), sourceRadius: NotionRadius.smAll)` |

Built in: `NotionButton`, `NotionIconButton`, `NotionListRow` and
`NotionPropertyRow` press with `NotionPressable`; `NotionButton(busy:)`
morphs its glyph; `NotionIconButton(selected:)` tweens its background;
`showNotionDialog` uses the Notion dialog route; `showNotionSheet` uses
`sheetStyleOf` and its title/content rise in; `NotionEmptyState` pops its
icon and staggers its text; tab indicators move elastically.
`ChatLoomThemes.animationDuration`/`animationCurve` point at `short`/`standard`,
so the ~56 legacy `Animated*` widgets got the new timing for free.
Use `NotionPulse` and `NotionTypingDots` directly; the old FluffyChat
`PulsatingWidget`/`TypingAnimation` shims are gone.

### Page motion and predictive back

Pages (`NotionPageTransitionsBuilder`, `notion_motion.dart`) push with an
8 % slide and a quick fade while the page underneath drifts 6 % the other
way under a light scrim; pop mirrors it faster. Two-column panes and reduced
motion are instant (`lib/config/routes.dart`).

Android predictive back is Telegram style: the top page follows the finger
1:1 towards the edge it is dragged to (left-edge swipe → right, right-edge
swipe → left), stays opaque, and the page underneath slides from its
parallax offset back to rest while its scrim lifts. A release past the
system threshold continues from the current position off the screen
(`gestureCommit` over `reverse`); a cancel returns to rest. Nothing jumps:
both pages move monotonically and the page underneath never passes its rest
(`test/notion/predictive_back_test.dart`). Exactly one page route takes the
gesture; a dialog, sheet or popover on top, a `PopScope(canPop: false)` or an
instant route declines it, so nothing moves and the release is an ordinary
back (the sheet closes with its own motion, the `PopScope` callback runs).

### Instead of X, use Y (motion)

| Instead of | Use |
|---|---|
| `CircularProgressIndicator` that flashes on fast work | `NotionDelayedSpinner` / `NotionDelayedReveal` |
| a centred spinner while a list loads | `NotionSkeleton` with placeholder rows |
| `AnimatedSwitcher` with the default fade for icons | `NotionMorphSwitcher` |
| a hard cut between filter/tab states | `NotionFadeThrough` |
| `if (x) widget` popping in | `NotionSizeReveal(visible: x)` or `NotionPop(visible: x)` |
| rows jumping to their new places when a list reorders | `NotionListMotion` + `NotionListMotionItem` |
| `x ? a : b` cutting between states that must stay mounted (focus, recorder) | `NotionReappear(trigger: x, child: x ? a : b)` |
| a list row that vanishes after its swipe action | `NotionSwipeActionSide(dismisses: true)` |
| `showDialog`, `showGeneralDialog(transitionDuration: Duration.zero)` | `showNotionCustomDialog`, `showNotionPopover` |
| `showModalBottomSheet` defaults | `showNotionSheet`, or `sheetAnimationStyle: NotionMotion.sheetStyleOf(context)` |
| `duration: Duration(milliseconds: 250)`, `Curves.easeInOut` | `NotionMotion.short`, `NotionMotion.standard` |
| `MediaQuery.of(context).disableAnimations` | `NotionMotion.reduced(context)` |
| `Timer.periodic` + `setState` loops, box-shadow pulses | `NotionTypingDots`, `NotionPulse` |
| `HapticFeedback.*` ad hoc | `NotionHaptics.send()` / `.longPress()` / `.selection()` |
| `child.animate()...` (flutter_animate) in a screen | a Notion primitive; add a new one in `lib/ui/notion/` if missing |

### House rules

1. Animate transform and opacity only. Size animation (`NotionSizeReveal`)
   is for single elements, never rows in bulk. No blur animation, never
   animate glass, never put glass inside an animating `Opacity` or scale
   (a popover reveals its glass by clip, `NotionGlassReveal`).
2. Lists: entrances play on a page's first appearance (≤ 10 items, inside a
   `NotionEntranceScope`) or for the one newest message. Scroll-built items
   never animate. No per-item controllers beyond that: `NotionPressable`,
   `NotionRowHighlight`, `NotionSizeReveal`, `NotionListMotionItem` and a
   non-playing `NotionEntrance` create theirs on first use; in rows use
   `NotionLazySwitcher` instead of `AnimatedSwitcher`-based switchers. The
   conversation timeline has no first-screen entrance at all: its rows render
   during the page push (Telegram), a list that replaces its loading
   placeholder fades in once as a whole (from `refreshFrom`, `short`), and
   only the one newest message animates its arrival.
3. Every one-shot animation settles to identity (opacity 1, offset 0,
   scale 1); goldens of resting states stay pixel-identical.
4. Every loop (`NotionTypingDots`, `NotionPulse`, skeleton shimmer, spinners)
   stops under `TickerMode` off and reduced motion, and rests on a static
   frame after its cap (`NotionMotion.loopCap`, `liveLoopCap` for live
   states): a wait that never ends (failed media, an offline worker) must
   not draw frames forever. Failed media shows a static fallback, never a
   spinner. Content loops (Lottie stickers, inline GIFs) play only while
   visible, under `TickerMode` on and outside reduced motion
   (`NotionContentLoopGate`). Never leave a
   skeleton enabled in a settled golden; use fixed pumps for loops.
5. No timers for motion. flutter_animate's `Animate` widget, `.animate()`
   and `AnimateList` always schedule a `Future.delayed` (even with zero
   delay) and leave pending timers in tests; `notion_entrance.dart` drives
   its effects with its own controller instead (lint `motion-animate-widget`
   inside `lib/ui/notion/`). Delays come from controller timelines.
6. All motion honours `NotionMotion.reduced(context)`: no wrapper effect or
   zero duration, with an unchanged widget tree.
   `reduced` is also true while the app is not in front of the user
   (`NotionActivity` at the app root: another app has focus, the window is
   occluded, minimised or closed). The same scope turns `TickerMode` off, so
   loops, GIF frames and spinners stop and one-shot motion that starts then
   shows its end state. Sync, sending and platform video keep running;
   scrolling an unfocused macOS window re-enables animation briefly.
   `reduced` is also true in the lite mode: while Android Battery Saver or
   macOS Low Power Mode is on (`PowerSaving`, `NotionActivity(powerSaving:)`,
   Telegram's power saver), content loops (Lottie stickers, inline GIF
   videos) rest on a static frame, one-shot motion and page pushes jump to
   their end, and glass falls back to its opaque tint. Tickers stay on, so
   scrolling and progress remain live; sync, sending, notifications and
   media the user starts are unchanged. Test it with
   `NotionActivity.isPowerSaving(context)`, never a platform call in a screen.
7. No rebuilds per tick: use `*Transition`/`AnimatedBuilder` with a `child`,
   `CustomPaint(repaint:)` for loops; never `setState` on every frame.
8. Never wrap subtrees that hold GlobalKeys or whole pages in a switcher
   (two live copies). Page and pane motion stays in `notion_motion.dart`.
9. Bounce only on reward elements (`NotionPop`, `NotionMorphSwitcher(bounce:
   true)`, `NotionPressable(bounce: true)` on send).

## Instead of X, use Y

| Instead of | Use |
|---|---|
| `Scaffold` + `AppBar` + `ListView` with custom padding | `NotionScaffold` |
| `ListTile` in new Notion screens | `NotionListRow` (existing `ListTile`s are themed by `listTileTheme`) |
| `AlertDialog`, `showDialog` with a hand-built body | `showNotionDialog`, `showNotionConfirmDialog` |
| `showModalBottomSheet` with a hand-built body | `showNotionSheet` |
| `ElevatedButton`, `FilledButton`, `OutlinedButton`, `TextButton` | `NotionButton` with a variant |
| `IconButton` in headers | `NotionIconButton` |
| `TextField` + `InputDecoration(labelText:)` | `NotionTextField` |
| a centred `Column(Icon, Text)` for "nothing here" | `NotionEmptyState` |
| a `Row(Icon, Text, TextButton)` status strip or a red `SnackBar` for a lasting problem | `NotionCallout` (dismissible, persistent) |
| `Text('Section', style: …)` above rows | `NotionSectionHeader` |
| `Color(0xFF…)`, `Colors.grey`, `Colors.red` | `context.notion.colors.*` (`danger` for red) |
| `Colors.white` / `Colors.black` on media | `NotionMediaColors.onScrim` / `NotionMediaColors.scrim` |
| `TextStyle(fontSize: 13)` | `NotionType.footnote` / `context.notion.typography.footnoteMuted` |
| `EdgeInsets.all(10)`, `SizedBox(height: 6)` | `NotionSpace.*` values |
| `BorderRadius.circular(18)` | `NotionRadius.mdAll` |
| `BorderRadius.zero`, `RoundedRectangleBorder()`, `const OutlineInputBorder()` | `NotionRadius.*`, `NotionShapes.*`, or drop the override (the theme is rounded) |
| a square selection highlight on a row | `NotionRadius.rowAll` on the `InkWell`/decoration, or `NotionGlassMenuRow` |
| a reply stripe (`Container(width: 5)` + "Name:") inside a bubble | `ConversationBubble(quote: ConversationReplyQuote(...))` |
| `color: luminance > .179 ? Colors.black87 : Colors.white` | `NotionContrast.on(background)` |
| `AppConfig.borderRadius / 2` | `NotionRadius.sm` |

## Do and don't

Do:
- Build screens from the primitives. Keep presentation widgets as
  data + callbacks (see `docs/notion-ui/SHARED-API.md`).
- Use one `title` per page and one primary button per view.
- Keep touch targets at 48 or more and check 2× text scale at 320 px wide.
- Put new reusable UI into `lib/ui/notion/` with a golden and a line in this
  file.

Don't:
- Add shadows, elevation, or gradients and coloured surfaces outside the
  palette roles (the Vivid bubble gradient and `accentFill`/`accentTint` are
  the only coloured fills).
- Blur anything that scrolls (rows, bubbles, cards, chips, grid tiles) or
  animate a blur; blur only fixed chrome and overlays that keep one glass
  state while they move (see Glass).
- Leave a square corner: every shape takes a `NotionRadius`/`NotionShapes`
  value.
- Use status colours (`danger`, `success`, ...) as decoration.
- Hard-code hex colours, font sizes, paddings or radii in screens.
- Restyle a Material widget inline when the theme already covers it; fix
  `notion_theme.dart` instead.
- Mass-restyle legacy FluffyChat screens as a side effect of a feature
  change. Move a screen to the primitives when you are already changing it.

## Enforcement

- `scripts/check-design-tokens.py` flags raw colours, `Colors.*` (except
  `transparent`), numeric `fontSize`, numeric `EdgeInsets`, numeric
  `circular(...)` radii, `AlertDialog`/`ElevatedButton` and raw
  `BackdropFilter` in `lib/`,
  except in `lib/ui/notion/` and `lib/utils/code_highlight_theme.dart`.
  Motion rules: `motion-import` (flutter_animate/skeletonizer outside
  `lib/ui/notion/`), `motion-blur` (`.blur(`, `BlurEffect`, `ImageFiltered`),
  `motion-duration` (a literal `Duration` in a `duration:` argument),
  `legacy-material-import` (`package:flutter/material.dart`) and, inside
  `lib/ui/notion/` only, `motion-animate-widget` (mounting flutter_animate's
  timer-based `Animate`). `square-corner` runs everywhere, including
  `lib/ui/notion/`: `BorderRadius.zero`, `Radius.zero`, a literal radius below
  6, `RoundedRectangleBorder(...)`/`OutlineInputBorder(...)` without a
  `borderRadius`, `ContinuousRectangleBorder`, `BeveledRectangleBorder`.
  Intentional flush edges (full-bleed bars, an image joined to its caption, a
  pill that is half its track height) end the line with
  `// design-lint: allow <reason>`.
  Existing debt is frozen per file and rule in `scripts/design-baseline.json`.
  - Default (also run by `scripts/verify-personal.py`): report only. Lines
    marked `NEW` are code you added; fix them before you hand off.
  - `--strict` (or `verify-personal.py --design-strict`): fail on growth.
  - After you remove legacy hits, run `--update-baseline` so the count
    cannot grow back.
  - A justified exception: end the line with `// design-lint: allow <reason>`.
- Goldens: `test/notion/design_system_golden_test.dart` (primitives and
  Material component themes, dark and light) and the five main screens in
  `test/notion/capture_production_test.dart` (inbox, conversation, merged
  conversation, chat details, settings) plus scrolled inbox/conversation
  captures with glass forced on. Glass has `glass-on-*`,
  `glass-overlays-*` (panel, menu rows, pills) and `glass-fallback-dark`
  goldens; the golden suite also checks that dialog glass blurs only after
  its route settles (`overlay_glass_motion_test.dart`: popovers and sheets
  keep one blur per frame, nothing remounts) and that no theme shape is square; `motion-dark` shows the motion primitives
  at rest. `test/notion/motion_primitives_test.dart` checks settle-to-
  identity, reduced motion, timers and loops for every motion primitive. Run them in the isolated harness:

  ```sh
  rtk python3 scripts/verify-notion-ui.py --capture-dir /tmp/notion-captures
  rtk python3 scripts/verify-notion-ui.py --update-goldens --capture-dir /tmp/notion-captures
  ```

  Goldens were rendered on the macOS host with the bundled Roboto; the
  19 October glass wave regenerated them on the Linux devbox, where text
  antialiasing differs by about 1–4 % of pixels. Regenerate on the host that
  runs the gate. A changed golden is a visual change: review the PNG diff
  before you commit it.

## Display preferences

`NotionDisplayPreferences` is a theme extension supplied to both app themes
and startup from `ThemeController`. Its local JSON preference is read before
the first frame, validated/clamped on load, and applied without restarting.
It changes presentation only; it does not change account/privacy policies or
message contents. Reset layout and effects restores these choices only.

Appearance also controls message text size (85–140%, composed with the
platform's nonlinear accessibility scaler), message spacing (75–150%),
sender avatars, text-bubble width (60–95%), outer corners (6–28 dp), reduced
motion and glass. `ConversationBubble` applies these to ordinary and merged
timelines and the appearance preview. Large text and media keep their existing
minimum width for readability. Typing uses the same bubble, avatar slot,
private incoming palette and text-line height as an incoming message.
`NotionMotion.reduced` and `notionGlassEnabled` honor the local choices while
retaining platform accessibility and power-saving restrictions.

Chats contains formatted messages, animated image playback, unknown/deleted
message visibility, long-message preview limits (including unlimited), emoji
suggestion language and the desktop details-panel default. Existing privacy,
notifications, recording/download, stickers and per-chat appearance remain
in their respective settings pages.

Wave 8 adds, in the same JSON value: pure black (`trueBlack`, swaps
`NotionColors.dark`/`NotionGlass.dark` for `NotionColors.black`/
`NotionGlass.black` in `NotionTheme.build`; light is unaffected), interface
text size (`uiTextScale` 85–130 %, applied by `NotionDisplayScope` in
`MaterialApp.builder`, composed with the platform scaler and, inside
bubbles, with the message text size), clock format (`clockFormat`,
`NotionDisplayScope` overrides `alwaysUse24HourFormat` and
`DateTimeExtension.use24HourFormat` checks it first), message times
(`messageTimestamps`: last in group, every message, hidden; ticks stay on
the group's last message), delivery ticks, sender names, emoji-only size
(`jumboEmoji`), two-line inbox previews (`inboxPreviewLines`), haptics
(`NotionHaptics.enabled`, set by `ThemeController`) and built-in chat
backgrounds (`wallpaperPreset` + `wallpaperStrength`, drawn by
`NotionPresetWallpaper`: a static diagonal gradient in its own
`RepaintBoundary`, never blurred or animated; the account picture wallpaper
wins when set, and metadata chips switch to wallpaper mode for both).

Colour: `NotionAppearance.custom` (stored as `#RRGGBB` in
`appearanceCustomAccent`) replaces the preset's hue; the palette tunes it
for contrast exactly like a preset, and its Vivid gradient ends 40° further
round the wheel. Presets now include indigo, amber and cyan.

Chats adds link preview cards on/off, the quick reaction bar (a JSON list in
`quickReactions`, filtered per network like the defaults) and the actions of
the two inbox swipe directions (`inboxSwipeLeft`/`Right`: archive,
read/unread, pin/unpin, nothing).

## Composer panel: stickers and GIFs

The Emoji · GIFs · Stickers panel (`lib/personal/stickers/`) is opaque (the
composer glass's fallback tone) and keeps its tabs mounted; a tab switch
fades through without a remount. The sticker tab is one `CustomScrollView`:
the pack strip above it follows the scroll and a tap glides to a pack (a
long way jumps to one screen before it), the search field floats back on any
upward scroll and stays pinned while searching, and section titles stick
(`SliverMainAxisGroup` + `PinnedHeaderSliver`). Headers and rows have fixed
extents, so offsets are exact; the place survives search, tab switches and
reopening, and rows added above the browsed pack never move it
(`correctPixels`, same frame). Animated stickers play only while the grid
rests; cells built during a fast fling wait to load. Search is local and
instant (`StickerSearchIndex`: emoji, words, shortcodes, alt text, pack
titles, ranked); back closes a search before the panel. Empty, no-result
and error states are `NotionEmptyState`; the GIF results load under a
`NotionSkeleton`.
