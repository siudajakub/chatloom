// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden references for the Notion design-system primitives (DESIGN.md).
// Run and update through scripts/verify-notion-ui.py so fonts match.
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _boundary = Key('golden');
void _noop() {}

Future<void> _golden(
  WidgetTester tester,
  String name,
  Widget child, {
  Size size = const Size(390, 520),
  Brightness brightness = Brightness.dark,
  bool reducedMotion = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        theme: NotionTheme.build(brightness),
        builder: reducedMotion
            ? (context, app) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: app!,
              )
            : null,
        home: child,
      ),
    ),
  );
  // Fixed frames instead of pumpAndSettle: the busy button spins forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull, reason: name);
  await expectLater(
    find.byKey(_boundary),
    matchesGoldenFile('goldens/primitives/$name.png'),
  );
}

Widget _page(List<Widget> children) => Scaffold(
  body: SafeArea(
    child: ListView(padding: NotionSpace.page, children: children),
  ),
);

/// Messenger-like bubbles: grouped corners, pills, replies with a quote.
Widget _bubbles({Color? page, Color? incoming, Color? outgoing}) => Builder(
  builder: (context) {
    final bubble = ConversationBubbleColors.of(context);
    final background = page ?? context.notion.colors.background;
    final metadata = NotionContrast.readable(
      background,
      context.notion.colors.textSecondary,
    );
    Color fillOf(bool out) =>
        (out ? outgoing : incoming) ??
        (out ? bubble.outgoing : bubble.incoming);
    Color textOn(bool out) {
      final custom = out ? outgoing : incoming;
      return custom == null ? bubble.text : NotionContrast.on(custom);
    }

    ConversationReplyQuote quote(
      String text, {
      required bool outgoing,
      required bool originalOwn,
      required String caption,
    }) {
      final colors = ConversationReplyQuote.colorsFor(
        side: fillOf(originalOwn),
        page: background,
        muted: bubble.metadata,
      );
      return ConversationReplyQuote(
        text: text,
        fill: colors.fill,
        textColor: colors.text,
        outgoing: outgoing,
        caption: ConversationReplyCaption(label: caption, color: metadata),
        onTap: _noop,
      );
    }

    Widget msg(
      String text, {
      required bool out,
      ConversationGroupPosition position = ConversationGroupPosition.single,
      Widget? quote,
    }) => ConversationBubble(
      outgoing: out,
      groupPosition: position,
      backgroundColor: (out ? outgoing : incoming),
      avatar: const NotionInitialAvatar(name: 'Anna', size: 28),
      quote: quote,
      body: Text(text, style: TextStyle(color: textOn(out))),
    );

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
          children: [
            msg(
              'jestem w pracy',
              out: false,
              position: ConversationGroupPosition.first,
            ),
            msg(
              'wracam koło 18',
              out: false,
              position: ConversationGroupPosition.last,
            ),
            msg(
              'ojoj',
              out: true,
              position: ConversationGroupPosition.first,
              quote: quote(
                'jestem w pracy',
                outgoing: true,
                originalOwn: false,
                caption: 'Replied to Anna',
              ),
            ),
            msg('szkoda', out: true, position: ConversationGroupPosition.last),
            msg(
              'spokojnie, wieczorem zrobimy kolację i obejrzymy ten film, '
              'o którym mówiłeś',
              out: false,
              quote: quote(
                'szkoda',
                outgoing: false,
                originalOwn: true,
                caption: 'Anna replied to you',
              ),
            ),
            msg(
              'ok',
              out: true,
              quote: quote(
                'Original message unavailable',
                outgoing: true,
                originalOwn: false,
                caption: 'You replied',
              ),
            ),
          ],
        ),
      ),
    );
  },
);

Widget _buttons() => _page([
  const NotionSectionHeader(title: 'Buttons'),
  for (final variant in NotionButtonVariant.values)
    Padding(
      padding: const EdgeInsets.only(bottom: NotionSpace.xs),
      child: Wrap(
        spacing: NotionSpace.xs,
        children: [
          NotionButton(label: variant.name, variant: variant, onPressed: _noop),
          NotionButton(
            label: 'Icon',
            icon: Icons.add,
            variant: variant,
            onPressed: _noop,
          ),
          NotionButton(label: 'Off', variant: variant, onPressed: null),
        ],
      ),
    ),
  const NotionButton.primary(label: 'Saving', onPressed: _noop, busy: true),
  const SizedBox(height: NotionSpace.xs),
  const NotionButton.primary(label: 'Continue', onPressed: _noop, expand: true),
]);

Widget _rows() => _page([
  const NotionSectionHeader(title: 'Conversation'),
  const NotionListRow(
    leading: Icon(Icons.notifications_none_outlined),
    title: 'Notifications',
    subtitle: 'Mentions only',
    onTap: _noop,
  ),
  const NotionListRow(
    leading: Icon(Icons.push_pin_outlined),
    title: 'Pinned',
    trailing: Text('Yes'),
  ),
  const Divider(),
  const NotionSectionHeader(
    title: 'Properties',
    trailing: NotionIconButton(icon: Icons.add, label: 'Add', onPressed: _noop),
  ),
  const NotionPropertyRow(label: 'Network', value: Text('Signal')),
  const NotionPropertyRow(label: 'Label', value: Text('Family'), onTap: _noop),
  const SizedBox(height: NotionSpace.md),
  const NotionCompactChatHeader(
    avatar: NotionInitialAvatar(name: 'Anna', size: 32),
    name: 'Anna Nowak',
    onDetails: _noop,
  ),
]);

Widget _scaffold() => NotionScaffold(
  title: 'Network',
  pageTitle: 'Signal',
  onBack: _noop,
  actions: const [
    NotionIconButton(icon: Icons.more_horiz, label: 'More', onPressed: _noop),
  ],
  children: const [
    Text('Bridged account and sync state.'),
    NotionSectionHeader(title: 'Account'),
    NotionListRow(title: 'Connected', subtitle: 'Since Monday', onTap: _noop),
  ],
);

Widget _dialog() => const Scaffold(
  body: Center(
    child: NotionDialog(
      title: 'Leave conversation?',
      message: 'You will stop receiving messages from this chat.',
      actions: [
        NotionButton.ghost(label: 'Cancel', onPressed: _noop),
        NotionButton.destructive(label: 'Leave', onPressed: _noop),
      ],
    ),
  ),
);

Widget _sheet() => const Scaffold(
  body: Align(
    alignment: Alignment.bottomCenter,
    // As showNotionSheet presents it: a glass panel (opaque here, no route).
    child: NotionGlassPanel(
      borderRadius: NotionGlass.sheetRadius,
      child: NotionSheet(
        title: 'Send from',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NotionListRow(title: 'Signal', subtitle: '+48 ••• 21'),
            NotionListRow(title: 'WhatsApp', subtitle: 'Unavailable'),
          ],
        ),
      ),
    ),
  ),
);

Widget _empty() => const Scaffold(
  body: NotionEmptyState(
    icon: Icons.inbox_outlined,
    title: 'No conversations',
    message: 'Chats from connected networks appear here.',
    action: NotionButton(label: 'Manage networks', onPressed: _noop),
  ),
);

Widget _fields() => _page([
  const SizedBox(height: NotionSpace.md),
  const NotionTextField(label: 'Display name', hint: 'Your name'),
  const SizedBox(height: NotionSpace.md),
  const NotionTextField(
    label: 'Homeserver',
    hint: 'matrix.org',
    prefixIcon: Icons.dns_outlined,
    helper: 'Only change this if you host your own server.',
  ),
  const SizedBox(height: NotionSpace.md),
  const NotionTextField(label: 'Password', obscureText: true, error: 'Wrong'),
  const SizedBox(height: NotionSpace.md),
  const NotionTextField(hint: 'Search messages', prefixIcon: Icons.search),
]);

Widget _callouts() => _page([
  const SizedBox(height: NotionSpace.md),
  const NotionCallout(
    icon: Icons.key_outlined,
    tone: NotionCalloutTone.warning,
    title: 'Connect this device to key backup',
    message: 'Enter your recovery key to unlock older messages.',
    actionLabel: 'Connect',
    onAction: _noop,
    secondaryLabel: '2 more',
    onSecondary: _noop,
    onDismiss: _noop,
  ),
  const SizedBox(height: NotionSpace.sm),
  const NotionCallout(
    icon: Icons.cloud_off_outlined,
    title: 'Waiting for network',
    message: 'Showing loaded chats.',
    actionLabel: 'Retry',
    onAction: _noop,
    actionBusy: true,
  ),
  const SizedBox(height: NotionSpace.sm),
  const NotionCallout(
    icon: Icons.lock_open_outlined,
    tone: NotionCalloutTone.danger,
    title: 'Encryption is off on this device',
  ),
]);

/// Resting states of the motion primitives (reduced motion: the skeleton is
/// a static fill, the typing dots are still).
Widget _motion() => _page([
  const NotionSectionHeader(title: 'Loading'),
  const NotionSkeleton(
    child: Column(
      children: [
        NotionSkeletonRow(),
        NotionSkeletonRow(lines: 1),
        NotionSkeletonRow(avatar: false),
      ],
    ),
  ),
  const NotionSectionHeader(title: 'Live'),
  const Row(
    children: [
      NotionTypingDots(),
      SizedBox(width: NotionSpace.md),
      NotionDelayedSpinner(delay: Duration.zero),
      SizedBox(width: NotionSpace.md),
      NotionPop(child: Badge(label: NotionAnimatedCount(count: 12))),
      SizedBox(width: NotionSpace.md),
      NotionPulse(
        child: SizedBox.square(
          dimension: NotionSize.avatarSm,
          child: Icon(Icons.call, size: NotionSize.iconSm),
        ),
      ),
    ],
  ),
  const SizedBox(height: NotionSpace.md),
  const NotionSizeReveal(
    visible: true,
    child: NotionCallout(
      icon: Icons.sync_problem_outlined,
      title: 'Revealed callout',
    ),
  ),
  const NotionEntrance(child: NotionListRow(title: 'Entered row')),
  NotionRowHighlight(
    trigger: 0,
    child: const NotionListRow(title: 'Highlight at rest', onTap: _noop),
  ),
]);

/// Plain Material widgets must already look Notion via component themes.
Widget _material() => DefaultTabController(
  length: 3,
  child: Scaffold(
    appBar: AppBar(
      title: const Text('Material defaults'),
      bottom: const TabBar(
        tabs: [
          Tab(text: 'Media'),
          Tab(text: 'Files'),
          Tab(text: 'Links'),
        ],
      ),
    ),
    body: ListView(
      children: [
        const ListTile(
          leading: Icon(Icons.person_outline),
          title: Text('ListTile'),
          subtitle: Text('Subtitle'),
          trailing: Badge(label: Text('3')),
        ),
        CheckboxListTile(
          value: true,
          onChanged: (_) {},
          title: const Text('Checkbox'),
        ),
        RadioGroup<int>(
          groupValue: 1,
          onChanged: (_) {},
          child: const RadioListTile<int>(value: 1, title: Text('Radio')),
        ),
        SwitchListTile(
          value: true,
          onChanged: (_) {},
          title: const Text('Switch'),
        ),
        Padding(
          padding: NotionSpace.page,
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Day')),
              ButtonSegment(value: 1, label: Text('Week')),
            ],
            selected: const {1},
            onSelectionChanged: (_) {},
          ),
        ),
        Slider(value: .4, onChanged: (_) {}),
        const Padding(
          padding: NotionSpace.page,
          child: SearchBar(hintText: 'Search', leading: Icon(Icons.search)),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: _noop,
      child: const Icon(Icons.edit_outlined),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: 0,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.chat_outlined), label: 'Chats'),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          label: 'Settings',
        ),
      ],
    ),
  ),
);

/// Glass chrome over scrolled content, forced on or off.
Widget _glass(NotionGlassMode mode) => NotionGlassScope(
  mode: mode,
  child: Builder(
    builder: (context) => Scaffold(
      body: BackdropGroup(
        child: Stack(
          children: [
            ListView(
              padding: EdgeInsets.zero,
              children: [
                for (var i = 0; i < 12; i++)
                  NotionListRow(
                    leading: NotionInitialAvatar(name: 'Row $i', size: 24),
                    title: 'Conversation number $i',
                    subtitle: 'Text passes under the glass bars',
                  ),
              ],
            ),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: NotionGlassBar(
                hairlineBottom: true,
                child: SizedBox(
                  height: NotionSize.headerHeight,
                  child: Padding(
                    padding: NotionSpace.page,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Header', style: NotionType.headline),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: NotionSpace.md,
              right: NotionSpace.md,
              bottom: NotionSpace.sm,
              child: NotionGlassSurface(
                dock: true,
                borderRadius: NotionGlass.dockRadius,
                border: Border.all(color: context.notion.glass.border),
                child: const SizedBox(
                  height: 56,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Icon(Icons.settings_outlined),
                      Text('Search'),
                      Text('All networks'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// The dock's language on overlays: a glass menu panel and glass pills over
/// scrolled content, forced on.
Widget _glassOverlays() => NotionGlassScope(
  mode: NotionGlassMode.on,
  child: Scaffold(
    body: Stack(
      children: [
        ListView(
          padding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < 10; i++)
              NotionListRow(
                leading: NotionInitialAvatar(name: 'Row $i', size: 24),
                title: 'Conversation number $i',
                subtitle: 'Content behind the glass overlays',
              ),
          ],
        ),
        Positioned(
          right: NotionSpace.md,
          bottom: 96,
          width: 220,
          child: NotionGlassPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: NotionSpace.xxs + 2),
                NotionGlassMenuRow(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: 'Main list',
                  selected: true,
                  trailing: const Icon(Icons.check, size: NotionSize.icon),
                  onTap: _noop,
                ),
                const NotionGlassMenuRow(
                  leading: Icon(Icons.group_outlined),
                  title: 'Groups',
                  onTap: _noop,
                ),
                const NotionGlassDivider(vertical: false),
                const NotionGlassMenuRow(
                  leading: Icon(Icons.tune),
                  title: 'Manage networks',
                  onTap: _noop,
                ),
                const SizedBox(height: NotionSpace.xxs + 2),
              ],
            ),
          ),
        ),
        const Positioned(
          left: NotionSpace.md,
          right: NotionSpace.md,
          bottom: NotionSpace.md,
          child: Row(
            children: [
              NotionGlassPill(
                icon: Icons.settings_outlined,
                tooltip: 'Settings',
                blur: true,
                onPressed: _noop,
              ),
              SizedBox(width: NotionSpace.xs),
              NotionGlassPill(
                icon: Icons.search,
                label: 'Search',
                blur: true,
                onPressed: _noop,
              ),
              SizedBox(width: NotionSpace.xs),
              Expanded(
                child: NotionGlassPill(
                  icon: Icons.hub_outlined,
                  label: 'All networks',
                  selected: true,
                  trailing: Icon(Icons.keyboard_arrow_down, size: 21),
                  onPressed: _noop,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  ),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('tokens are registered on both themes', (tester) async {
    for (final brightness in Brightness.values) {
      final theme = NotionTheme.build(brightness);
      final tokens = theme.extension<NotionTokens>()!;
      expect(theme.scaffoldBackgroundColor, tokens.colors.background);
      expect(theme.colorScheme.error, tokens.colors.danger);
    }
    expect(
      NotionTheme.build(
        Brightness.dark,
      ).extension<NotionTokens>()!.colors.background,
      NotionTokens.background,
    );
  });

  testWidgets(
    'buttons',
    (tester) => _golden(tester, 'buttons-dark', _buttons()),
  );
  testWidgets(
    'bubbles and replies',
    (tester) => _golden(tester, 'bubbles-replies-dark', _bubbles()),
  );
  testWidgets(
    'bubbles and replies light',
    (tester) => _golden(
      tester,
      'bubbles-replies-light',
      _bubbles(),
      brightness: Brightness.light,
    ),
  );
  testWidgets(
    'bubbles and replies on a private palette',
    (tester) => _golden(
      tester,
      'bubbles-replies-palette-dark',
      _bubbles(
        page: const Color(0xFFF0F2F4),
        incoming: const Color(0xFFDBE6F5),
        outgoing: const Color(0xFFDFEBDB),
      ),
    ),
  );
  testWidgets(
    'buttons light',
    (tester) => _golden(
      tester,
      'buttons-light',
      _buttons(),
      brightness: Brightness.light,
    ),
  );
  testWidgets(
    'rows and section headers',
    (tester) => _golden(tester, 'rows-dark', _rows()),
  );
  testWidgets(
    'scaffold',
    (tester) => _golden(tester, 'scaffold-dark', _scaffold()),
  );
  testWidgets(
    'dialog',
    (tester) =>
        _golden(tester, 'dialog-dark', _dialog(), size: const Size(390, 360)),
  );
  testWidgets(
    'sheet',
    (tester) =>
        _golden(tester, 'sheet-dark', _sheet(), size: const Size(390, 360)),
  );
  testWidgets(
    'empty state',
    (tester) => _golden(
      tester,
      'empty-state-dark',
      _empty(),
      size: const Size(390, 360),
    ),
  );
  testWidgets(
    'text fields',
    (tester) => _golden(tester, 'text-fields-dark', _fields()),
  );
  testWidgets(
    'callouts',
    (tester) => _golden(
      tester,
      'callout-dark',
      _callouts(),
      size: const Size(390, 420),
    ),
  );
  testWidgets(
    'callouts light',
    (tester) => _golden(
      tester,
      'callout-light',
      _callouts(),
      size: const Size(390, 420),
      brightness: Brightness.light,
    ),
  );
  testWidgets(
    'motion primitives at rest',
    (tester) => _golden(tester, 'motion-dark', _motion(), reducedMotion: true),
  );
  testWidgets(
    'material component themes',
    (tester) => _golden(
      tester,
      'material-dark',
      _material(),
      size: const Size(390, 700),
    ),
  );
  testWidgets(
    'material component themes light',
    (tester) => _golden(
      tester,
      'material-light',
      _material(),
      size: const Size(390, 700),
      brightness: Brightness.light,
    ),
  );
  testWidgets(
    'glass on',
    (tester) => _golden(
      tester,
      'glass-on-dark',
      _glass(NotionGlassMode.on),
      size: const Size(390, 420),
    ),
  );
  testWidgets(
    'glass on light',
    (tester) => _golden(
      tester,
      'glass-on-light',
      _glass(NotionGlassMode.on),
      size: const Size(390, 420),
      brightness: Brightness.light,
    ),
  );
  testWidgets(
    'glass fallback',
    (tester) => _golden(
      tester,
      'glass-fallback-dark',
      _glass(NotionGlassMode.off),
      size: const Size(390, 420),
    ),
  );
  testWidgets(
    'glass overlays',
    (tester) => _golden(tester, 'glass-overlays-dark', _glassOverlays()),
  );
  testWidgets(
    'glass overlays light',
    (tester) => _golden(
      tester,
      'glass-overlays-light',
      _glassOverlays(),
      brightness: Brightness.light,
    ),
  );
  testWidgets('overlay glass blurs only once its route settled', (
    tester,
  ) async {
    await tester.pumpWidget(
      NotionGlassScope(
        mode: NotionGlassMode.on,
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showNotionDialog<void>(
                  context: context,
                  title: 'Glass dialog',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    Finder blur() => find.descendant(
      of: find.byType(NotionDialog),
      matching: find.byType(BackdropFilter),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(NotionDialog), findsOneWidget);
    expect(blur(), findsNothing, reason: 'no blur while the dialog grows');
    await tester.pumpAndSettle();
    expect(blur(), findsOneWidget, reason: 'blur once settled');
    Navigator.of(tester.element(find.byType(NotionDialog))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(blur(), findsNothing, reason: 'no blur while it leaves');
    await tester.pumpAndSettle();
    expect(find.byType(NotionDialog), findsNothing);
  });
  testWidgets('nothing in the theme is square', (tester) async {
    for (final brightness in Brightness.values) {
      final theme = NotionTheme.build(brightness);
      bool rounded(ShapeBorder? shape) =>
          shape is StadiumBorder ||
          shape is CircleBorder ||
          (shape is RoundedRectangleBorder &&
              shape.borderRadius != BorderRadius.zero);
      expect(rounded(theme.cardTheme.shape), isTrue);
      expect(rounded(theme.dialogTheme.shape), isTrue);
      expect(rounded(theme.popupMenuTheme.shape), isTrue);
      expect(rounded(theme.snackBarTheme.shape), isTrue);
      expect(rounded(theme.listTileTheme.shape), isTrue);
      expect(rounded(theme.chipTheme.shape), isTrue);
      expect(rounded(theme.floatingActionButtonTheme.shape), isTrue);
      expect(rounded(theme.navigationBarTheme.indicatorShape), isTrue);
      expect(rounded(theme.checkboxTheme.shape), isTrue);
      for (final style in [
        theme.filledButtonTheme.style,
        theme.outlinedButtonTheme.style,
        theme.textButtonTheme.style,
        theme.elevatedButtonTheme.style,
        theme.iconButtonTheme.style,
      ]) {
        expect(style!.shape!.resolve({}), isA<StadiumBorder>());
      }
      final input = theme.inputDecorationTheme.enabledBorder;
      expect(
        (input! as OutlineInputBorder).borderRadius,
        NotionRadius.fieldAll,
      );
    }
  });
  testWidgets('glass auto falls back without Impeller', (tester) async {
    late bool enabled;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          enabled = notionGlassEnabled(context);
          return const SizedBox();
        },
      ),
    );
    expect(enabled, isFalse);
  });
}
