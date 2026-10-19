# Notion dark v2 design system

The rules for any UI in `client/`. It covers the tokens, the primitives, how
legacy Material widgets map to them, and how the rules are enforced. If a
value or widget you need is missing, add it to `lib/ui/notion/` (with a
golden) instead of writing a one-off in the screen.

Import everything from one barrel:

```dart
import 'package:fluffychat/ui/notion/notion.dart';
```

## Why it looks like this

Personal Chat is a quiet, text-first messenger. The look follows Notion's dark
mode (with glass only on the fixed bars, see Glass): warm near-black page, flat grey surfaces, one neutral text colour, no
elevation, no gradients, small radii. Hierarchy comes from type weight and
muted secondary text, not from colour or shadow. The user's accent
preference changes only `colors.accent`; incoming messages and identity never
depend on it. Light mode uses the same roles with a paper palette, so any
code that reads roles works in both.

## Tokens

All tokens live in `lib/ui/notion/notion_tokens.dart`.

### Colours: `context.notion.colors` (theme-dependent)

| Role | Dark | Use for |
|---|---|---|
| `background` | `#191919` | page, app bar, dialogs, sheets |
| `surface` | `#252525` | cards, menus, chips, input fill, snackbar |
| `selected` | `#2F2F2F` | selected/pressed rows, highest container |
| `border` | `#383838` | dividers, outlines, input borders |
| `text` | `#E8E7E5` | primary text and icons |
| `textSecondary` | `#AAAAA5` | subtitles, labels, metadata |
| `textTertiary` | `#7F7F7B` | placeholders, disabled |
| `cover` | `#33312B` | page cover band |
| `accent` / `onAccent` | = text | user accent (seed), focus |
| `danger` `success` `warning` `info` | red/green/amber/blue | status only, never decoration |
| `scrim` | 60% black | modal barrier |
| `NotionMediaColors.scrim` / `stageScrim` / `onScrim` | 45% / 72% black, white | over video frames only (round pills and glyphs, media stage barrier); fixed in both themes |

Message bubbles use the `ConversationBubbleColors` extension
(`ConversationBubbleColors.of(context)`); it is registered by `NotionTheme`.

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
`row`, `dialog`, `sheet` presets.

### Radius: `NotionRadius.*` (const)

`sm 5` (avatars, icon buttons, chips) · `md 7` (cards, inputs, buttons,
menus, dialogs) · `lg 12` (sheets, large media) · `field 26` (composer field; pill
at one line, soft corners when multiline) · `pill` (badges, toggles).
Use the `smAll` / `mdAll` / `lgAll` / `pillAll` / `sheetTop` `BorderRadius`
constants. `AppConfig.borderRadius` is now `NotionRadius.md`.

### Sizes: `NotionSize.*` (const)

`touchTarget 48`, `headerHeight 56`, `rowMinHeight 52`, icons
`iconSm 16 / icon 20 / iconMd 22 / iconLg 24`, avatars `24 / 40 / 56`,
`dialogMaxWidth 420`, `contentMaxWidth 720`.

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
| `NotionIconButton(icon:, label:, onPressed:)` | header and inline icon actions (label is the tooltip) |
| `NotionButton(label:, onPressed:, variant:)` / `.primary` / `.ghost` / `.destructive` | every text button; `icon:`, `expand:`, `busy:` |
| `NotionDialog` + `showNotionDialog(...)` / `showNotionConfirmDialog(...)` | modal questions and confirmations |
| `NotionSheet` + `showNotionSheet(...)` | bottom sheets and pickers |
| `NotionEmptyState(icon:, title:, message:, action:)` | empty lists, soft errors |
| `NotionCallout(icon:, title:, message:, actionLabel:, onAction:, onDismiss:, tone:)` | inline fixable status (inbox encryption/sync notice, connection retry); `tone` colours only the icon |
| `ConversationBubble(quote:)`, `ConversationReplyQuote`, `ConversationReplyCaption`, `ConversationMetaChip` | message bubbles and Messenger-style replies (`lib/pages/chat/conversation_bubble.dart`, see Message bubbles) |
| `NotionTextField(label:, hint:, helper:, error:, ...)` | text input with the label above |
| `NotionCompactChatHeader`, `NotionInitialAvatar` | chat header, letter avatar |
| `NotionGlassSurface`, `NotionGlassBar`, `NotionGlassScope` | glass chrome only (see Glass) |
| `NotionPressable`, `NotionEntrance`, `NotionSkeleton`, `NotionFadeThrough`, `NotionPop`, ... | motion (see Motion) |

Each primitive has a golden in `test/notion/goldens/primitives/`.

## Glass (direction B: Notion + glass on the bars)

Glass is a translucent tint over a backdrop blur. It is allowed on exactly
three fixed chrome surfaces that content scrolls under:

| Surface | Code |
|---|---|
| Top header (inbox title bar, conversation and merged chat `AppBar`) | `NotionGlassBar` (inbox: in a `PinnedHeaderSliver`; chat: `AppBar(backgroundColor: Colors.transparent, flexibleSpace: NotionGlassBar(...))` with `extendBodyBehindAppBar: true`) |
| Floating bottom dock (inbox) | `NotionGlassSurface(dock: true, borderRadius: NotionGlass.dockRadius, border: ...)` inset from the edges |
| Composer strip (conversation) | `NotionGlassBar` behind the input row, over the timeline |

Never on list rows, message bubbles, cards, chips, dialogs, sheets or menus.

Tokens: `context.notion.glass`:

| Token | Dark | Light |
|---|---|---|
| `tint` (bars) | background at 60% | background at 72% |
| `dockTint` | surface at 58% | surface at 72% |
| `border` (hairline) | white 10% | black 8% |
| `blurSigma` | 18 | 18 |
| `NotionGlass.dockRadius` | pill | pill |

Rules:
- Use `NotionGlassSurface` / `NotionGlassBar`, never a raw `BackdropFilter`
  (the lint reports `backdrop-filter` outside `lib/ui/notion/`).
- Put a `BackdropGroup` around a page with more than one glass bar so the
  bars share one backdrop read (`NotionInboxPage`, `ChatPageWithRoom`).
- Content must scroll under the bar: add `MediaQuery.paddingOf(context).top`
  (or the bar height) to the scroll view's top padding, and the measured
  composer/dock height to its bottom padding.
- The fallback is automatic: when the renderer is not Impeller
  (`ImageFilter.isShaderFilterSupported` is false: Skia, web, tests), when
  high contrast or reduced motion is on, or with
  `--dart-define=PERSONAL_GLASS=false`, the same tint is painted opaque.
  `NotionGlassScope(mode: NotionGlassMode.off)` forces the fallback for a
  subtree (low-end flag); `.on` forces glass (goldens).
- Text on glass uses the normal text roles; never lower its contrast to
  "show off" the blur.

| Instead of | Use |
|---|---|
| `BackdropFilter(filter: ImageFilter.blur(...))` | `NotionGlassSurface` |
| `AppBar(backgroundColor: color.withAlpha(...))` | `flexibleSpace: NotionGlassBar()` + transparent background |
| a translucent `Container` behind the composer | `NotionGlassBar` |
| `Material(elevation: 3)` floating dock | `NotionGlassSurface(dock: true, ...)` |

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
| `short` | 200 ms | fades, badges, small reveals (= `FluffyThemes.animationDuration`) |
| `medium` | 260 ms | entrances, dialogs, size reveals |
| `long` | 320 ms | sheets, page push (`forward`); pop is `reverse` 220 ms |
| `stagger` / `staggerCap` | 28 ms / 10 | per-item delay, never more than 10 steps |
| `loaderGrace` | 250 ms | a loader stays invisible this long |
| `standard` | `Cubic(.2, 0, 0, 1)` | general tweens (= `FluffyThemes.animationCurve`) |
| `emphasized` | `Cubic(.05, .7, .1, 1)` | entrances, page enter |
| `exitFast` | `Cubic(.3, 0, .8, .15)` | exits |
| `snappy` / `smooth` / `bouncy` | `SpringDescription`s | press release and toggles / dialogs and sheets / reward pops only |
| `snappyCurve` / `smoothCurve` / `bouncyCurve` | `NotionSpringCurve` | the springs as curves for tweens and switchers (`.duration` = natural length) |
| `springTo(spring, from, to, velocity:)` | `SpringSimulation` | interruptible `controller.animateWith(...)`, ends exactly on `to` |
| `rise` 8 · `riseList` 10 · `riseSheet` 12 | px | entrance travel |
| `pressButton` .96 · `pressIcon` .90 · `pressRow` .985 | scale | `NotionPressable` |
| `popFrom` .6 · `dialogFrom` .94 · `popoverFrom` .92 | scale | start scales |
| `sheetStyle` / `sheetStyleOf(context)` · `menuStyle` | `AnimationStyle` | `showModalBottomSheet(sheetAnimationStyle:)`, `showMenu`/`PopupMenuButton(popUpAnimationStyle:)` |
| `reduced(context)` | bool | **the** reduced-motion check (Android "Remove animations", iOS Reduce Motion) |
| `of(context, d)` | Duration | `d`, or zero under reduced motion |
| `staggerFor(i)` | Duration | capped stagger delay |

`NotionHaptics.send()` / `.longPress()` (a light impact) are the only haptics:
on send and on a recognised long-press. Screens decide; nothing buzzes by
default.

### Primitives

| Widget | Use for | Example |
|---|---|---|
| `NotionPressable(child:, scale:, bounce:, onTap:, onLongPress:, hapticOnTap:)` | scale-on-press with spring release around any tappable; raw pointers, so it never steals taps; lets go when the finger drags past the touch slop | `NotionPressable(scale: NotionMotion.pressRow, child: InkWell(onTap: open, child: row))` |
| `NotionEntrance(child:, index:, rise:, slide:, scale:, afterRoute:, playKey:)` | one-shot fade + rise, waits for the page push, settles to identity | `NotionEntrance(index: 1, child: header)` |
| `NotionEntranceScope(child:)` | around a list: numbers entrances, plays only the first screenful, rows built later by scrolling never animate | `NotionEntranceScope(child: ListView(children: [for (final r in rows) NotionEntrance(playKey: r.id, child: Row(r))]))` |
| `NotionStaggeredColumn(children:)`, `NotionEntrance.stagger(list)` | a short stack of sections | `NotionStaggeredColumn(children: [title, body, actions])` |
| `NotionFadeThrough(child:)` | same slot, new state (title, filtered list, empty ↔ content); key each state | `NotionFadeThrough(child: Text(label, key: ValueKey(label)))` |
| `NotionMorphSwitcher(child:, bounce:, rotate:)` | glyph/button swaps (mic → send, idle → busy) | `NotionMorphSwitcher(bounce: true, child: Icon(icon, key: ValueKey(icon)))` |
| `NotionAnimatedCount(count:, style:, format:)` | numbers that change: rolls up/down | `NotionAnimatedCount(count: unread, style: NotionType.micro)` |
| `NotionSizeReveal(visible:, child:, axis:)` | single element appearing/disappearing with size + fade (callout, reply preview, typing row) | `NotionSizeReveal(visible: error != null, child: NotionCallout(...))` |
| `NotionPop(child:, trigger:, visible:, bounce:)` | badges, reaction chips, dots: spring in, pulse on `trigger`, pop out | `NotionPop(trigger: count, child: badge)` |
| `NotionShake(trigger:, child:)` | rejected input (wrong PIN) | `NotionShake(trigger: errors, child: field)` |
| `NotionRowHighlight(trigger:, child:)` | one-shot `selected` flash of a row that moved or changed (inbox reorder is not animated) | `NotionRowHighlight(trigger: room.lastEventId, child: row)` |
| `NotionSkeleton(enabled:, child:)`, `.sliver`, `NotionSkeletonRow()`, `NotionSkeleton.keep/ignore/unite` | loading state with the final layout; cross-fades to content | `NotionSkeleton(enabled: loading, child: Column(children: [for (var i = 0; i < 8; i++) const NotionSkeletonRow()]))` |
| `NotionDelayedSpinner()`, `NotionDelayedReveal(child:)` | loaders that only show after `loaderGrace` | `if (busy) const NotionDelayedSpinner()` |
| `NotionTypingDots(size:)`, `NotionPulse(child:, color:)` | loops: typing, live call/recording | `NotionPulse(color: colors.danger, child: callButton)` |
| `showNotionCustomDialog(context:, builder:)`, `NotionDialogRoute`, `NotionDialogTransition` | any dialog: barrier fade, scale .94 → 1 on `smoothCurve`, faster exit | `showNotionCustomDialog(context: context, builder: (_) => NotionDialog(...))` |
| `showNotionPopover(context:, builder:, alignment:)`, `NotionPopoverRoute` | anchored panels/menus that grow from their anchor | `showNotionPopover(context: context, alignment: Alignment.bottomRight, builder: panel)` |
| `AfterRouteTransition(child:)` | heavy content after the push; now fades the child in | as before |

Built in: `NotionButton`, `NotionIconButton`, `NotionListRow` and
`NotionPropertyRow` press with `NotionPressable`; `NotionButton(busy:)`
morphs its glyph; `NotionIconButton(selected:)` tweens its background;
`showNotionDialog` uses the Notion dialog route; `showNotionSheet` uses
`sheetStyleOf` and its title/content rise in; `NotionEmptyState` pops its
icon and staggers its text; tab indicators move elastically.
`FluffyThemes.animationDuration`/`animationCurve` point at `short`/`standard`,
so the ~56 legacy `Animated*` widgets got the new timing for free.
`PulsatingWidget` and `TypingAnimation` are shims over `NotionPulse` and
`NotionTypingDots`.

### Instead of X, use Y (motion)

| Instead of | Use |
|---|---|
| `CircularProgressIndicator` that flashes on fast work | `NotionDelayedSpinner` / `NotionDelayedReveal` |
| a centred spinner while a list loads | `NotionSkeleton` with placeholder rows |
| `AnimatedSwitcher` with the default fade for icons | `NotionMorphSwitcher` |
| a hard cut between filter/tab states | `NotionFadeThrough` |
| `if (x) widget` popping in | `NotionSizeReveal(visible: x)` or `NotionPop(visible: x)` |
| `showDialog`, `showGeneralDialog(transitionDuration: Duration.zero)` | `showNotionCustomDialog`, `showNotionPopover` |
| `showModalBottomSheet` defaults | `showNotionSheet`, or `sheetAnimationStyle: NotionMotion.sheetStyleOf(context)` |
| `duration: Duration(milliseconds: 250)`, `Curves.easeInOut` | `NotionMotion.short`, `NotionMotion.standard` |
| `MediaQuery.of(context).disableAnimations` | `NotionMotion.reduced(context)` |
| `Timer.periodic` + `setState` loops, box-shadow pulses | `NotionTypingDots`, `NotionPulse` |
| `HapticFeedback.*` ad hoc | `NotionHaptics.send()` / `.longPress()` |
| `child.animate()...` (flutter_animate) in a screen | a Notion primitive; add a new one in `lib/ui/notion/` if missing |

### House rules

1. Animate transform and opacity only. Size animation (`NotionSizeReveal`)
   is for single elements, never rows in bulk. No blur animation, never
   animate glass, never put glass inside an animating `Opacity`.
2. Lists: entrances play on a page's first appearance (≤ 10 items, inside a
   `NotionEntranceScope`) or for the one newest message. Scroll-built items
   never animate. No per-item controllers beyond that.
3. Every one-shot animation settles to identity (opacity 1, offset 0,
   scale 1); goldens of resting states stay pixel-identical.
4. Every loop (`NotionTypingDots`, `NotionPulse`, skeleton shimmer, spinners)
   stops under `TickerMode` off and reduced motion. Never leave a skeleton
   enabled in a settled golden; use fixed pumps for loops.
5. No timers for motion. flutter_animate's `Animate` widget, `.animate()`
   and `AnimateList` always schedule a `Future.delayed` (even with zero
   delay) and leave pending timers in tests; `notion_entrance.dart` drives
   its effects with its own controller instead (lint `motion-animate-widget`
   inside `lib/ui/notion/`). Delays come from controller timelines.
6. All motion honours `NotionMotion.reduced(context)`: no wrapper effect or
   zero duration, with an unchanged widget tree.
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
- Add shadows, gradients, coloured surfaces or elevation.
- Use glass anywhere except the header, dock and composer.
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
  timer-based `Animate`).
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
  captures with glass forced on. Glass has `glass-on-*` and
  `glass-fallback-dark` goldens; `motion-dark` shows the motion primitives
  at rest. `test/notion/motion_primitives_test.dart` checks settle-to-
  identity, reduced motion, timers and loops for every motion primitive. Run them in the isolated harness:

  ```sh
  rtk python3 scripts/verify-notion-ui.py --capture-dir /tmp/notion-captures
  rtk python3 scripts/verify-notion-ui.py --update-goldens --capture-dir /tmp/notion-captures
  ```

  Goldens are rendered on the macOS host with the bundled Roboto. A changed
  golden is a visual change: review the PNG diff before you commit it.
