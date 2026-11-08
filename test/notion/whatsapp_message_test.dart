// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion_contrast.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/ui/notion/notion_tokens.dart';
import 'package:chatloom/ui/notion/notion_whatsapp_message.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _actions = [
  NotionMessageUrlAction(
    label: 'View post',
    url: 'https://example.org/post?source=message#details',
  ),
  NotionMessageUrlAction(
    label: 'See the full event details and registration information',
    url: 'https://events.example.org/register',
  ),
];
const _options = [
  NotionPollOption(
    id: 'river',
    label: 'Riverside café',
    votes: 3,
    selected: true,
  ),
  NotionPollOption(id: 'garden', label: 'Library garden', votes: 0),
  NotionPollOption(id: 'later', label: 'Another day'),
];
const _status = 'Vote in WhatsApp · Results from available votes';

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: true,
    ),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(NotionSpace.md),
      children: [child],
    ),
  ),
);

NotionWhatsAppActions _urlActions({
  ValueChanged<String>? onOpen,
  ValueChanged<String>? onCopy,
}) => NotionWhatsAppActions(
  actions: _actions,
  onOpen: onOpen ?? (_) {},
  onCopy: onCopy ?? (_) {},
);

const _poll = NotionReadOnlyPoll(
  question: 'Where shall we meet on Friday?',
  options: _options,
  status: _status,
);

void main() {
  setUpAll(() async {
    final fonts = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
    }
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'open and copy pass the original URL through separate callbacks',
    (tester) async {
      final opened = <String>[];
      final copied = <String>[];
      await tester.pumpWidget(
        _app(_urlActions(onOpen: opened.add, onCopy: copied.add)),
      );
      expect(find.text('example.org'), findsOneWidget);
      expect(find.text('events.example.org'), findsOneWidget);
      expect(find.byTooltip('Copy link'), findsNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('whatsapp-open-0')));
      expect(opened, [_actions[0].url]);
      expect(copied, isEmpty);
      await tester.tap(find.byKey(const ValueKey('whatsapp-copy-1')));
      expect(opened, [_actions[0].url]);
      expect(copied, [_actions[1].url]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('each open and copy target is at least 48 dp', (tester) async {
    await tester.pumpWidget(_app(_urlActions()));
    for (var index = 0; index < _actions.length; index++) {
      for (final action in ['open', 'copy']) {
        final size = tester.getSize(
          find.byKey(ValueKey('whatsapp-$action-$index')),
        );
        expect(size.width, greaterThanOrEqualTo(NotionSize.touchTarget));
        expect(size.height, greaterThanOrEqualTo(NotionSize.touchTarget));
      }
    }
  });

  testWidgets('keyboard traversal activates open and copy independently', (
    tester,
  ) async {
    final opened = <String>[];
    final copied = <String>[];
    await tester.pumpWidget(
      _app(_urlActions(onOpen: opened.add, onCopy: copied.add)),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, [_actions[0].url]);
    expect(copied, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(opened, [_actions[0].url]);
    expect(copied, [_actions[0].url]);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, [_actions[0].url, _actions[1].url]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen readers get the destination and separate copy action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final opened = <String>[];
      final copied = <String>[];
      await tester.pumpWidget(
        _app(_urlActions(onOpen: opened.add, onCopy: copied.add)),
      );
      final open = tester.getSemantics(
        find.bySemanticsLabel('View post, example.org'),
      );
      final copy = tester.getSemantics(
        find.bySemanticsLabel('Copy link to example.org'),
      );
      expect(open.flagsCollection.isButton, isTrue);
      expect(open.hint, 'Open link in browser');
      expect(copy.flagsCollection.isButton, isTrue);
      open.owner!.performAction(open.id, SemanticsAction.tap);
      copy.owner!.performAction(copy.id, SemanticsAction.tap);
      expect(opened, [_actions[0].url]);
      expect(copied, [_actions[0].url]);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('empty URL actions add no controls', (tester) async {
    await tester.pumpWidget(
      _app(
        NotionWhatsAppActions(
          actions: const [],
          onOpen: (_) => fail('No open action exists'),
          onCopy: (_) => fail('No copy action exists'),
        ),
      ),
    );
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('CTA text reaches AA contrast against the supplied bubble', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      late Color background;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              background = context.notion.colors.selected;
              return NotionWhatsAppActions(
                actions: [_actions.first],
                backgroundColor: background,
                onOpen: (_) {},
                onCopy: (_) {},
              );
            },
          ),
          brightness: brightness,
        ),
      );
      final text = tester.widget<Text>(find.text('View post'));
      expect(
        NotionContrast.ratio(text.style!.color!, background),
        greaterThanOrEqualTo(NotionContrast.minimum),
      );
    }
  });

  testWidgets('320 dp 200 percent RTL golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('whatsapp-narrow-golden'),
        child: _app(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _urlActions(),
              const SizedBox(height: NotionSpace.xl),
              _poll,
            ],
          ),
          direction: TextDirection.rtl,
          textScale: 2,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('whatsapp-narrow-golden')),
      matchesGoldenFile('goldens/primitives/whatsapp-message-320-200-rtl.png'),
    );
  });

  testWidgets('custom bubble foregrounds also colour domains and poll status', (
    tester,
  ) async {
    late Color foreground;
    late Color link;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            foreground = context.notion.palette.onBubble;
            link = context.notion.colors.textSecondary;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NotionWhatsAppActions(
                  actions: [_actions.first],
                  onOpen: (_) {},
                  onCopy: (_) {},
                  textColor: foreground,
                  linkColor: link,
                ),
                NotionReadOnlyPoll(
                  question: _poll.question,
                  options: _options,
                  status: _status,
                  textColor: foreground,
                  linkColor: link,
                ),
              ],
            );
          },
        ),
      ),
    );
    for (final label in ['example.org', _status, _poll.question]) {
      expect(tester.widget<Text>(find.text(label)).style!.color, foreground);
    }
    expect(tester.widget<Text>(find.text('View post')).style!.color, link);
    expect(tester.widget<Icon>(find.byIcon(Icons.check_rounded)).color, link);
    expect(tester.takeException(), isNull);
  });

  testWidgets('poll shows known counts and leaves unknown counts absent', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_poll));
    expect(find.text('3'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    final unknown = find.byKey(const ValueKey('whatsapp-poll-option-later'));
    expect(
      find.descendant(of: unknown, matching: find.byType(Text)),
      findsOneWidget,
    );
    expect(find.text(_status), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Radio<Object>), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    await tester.tap(find.text('Library garden'));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('poll semantics announce selection and have no vote action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_app(_poll));
      for (final option in _options) {
        final node = tester.getSemantics(
          find.byKey(ValueKey('whatsapp-poll-option-${option.id}')),
        );
        expect(node.label, option.label);
        expect(node.value, option.votes?.toString() ?? '');
        expect(node.flagsCollection.isReadOnly, isTrue);
        expect(
          node.flagsCollection.isSelected.toBoolOrNull() ?? false,
          option.selected,
        );
        expect(node.flagsCollection.isButton, isFalse);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  for (final brightness in Brightness.values) {
    for (final direction in TextDirection.values) {
      testWidgets(
        '320 dp and 200% text reflow in ${brightness.name}, ${direction.name}',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 700));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const longLabel =
              'Read the complete announcement and check the meeting details';
          const longQuestion =
              'Which meeting place works best for everyone this Friday evening?';
          await tester.pumpWidget(
            _app(
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NotionWhatsAppActions(
                    actions: const [
                      NotionMessageUrlAction(
                        label: longLabel,
                        url:
                            'https://a-long-event-name.example.org/announcement',
                      ),
                      NotionMessageUrlAction(
                        label: 'تفاصيل اللقاء والتسجيل في فعالية يوم الجمعة',
                        url: 'https://events.example.org/register',
                      ),
                    ],
                    onOpen: (_) {},
                    onCopy: (_) {},
                  ),
                  const SizedBox(height: NotionSpace.xl),
                  const NotionReadOnlyPoll(
                    question: longQuestion,
                    options: [
                      NotionPollOption(
                        id: 'long',
                        label: 'A quiet café with a garden near the river',
                        votes: 12,
                        selected: true,
                      ),
                      NotionPollOption(
                        id: 'rtl',
                        label: 'الحديقة القريبة من المكتبة العامة',
                        votes: 0,
                      ),
                    ],
                    status: _status,
                  ),
                ],
              ),
              brightness: brightness,
              direction: direction,
              textScale: 2,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final label = tester.widget<Text>(find.text(longLabel));
          expect(label.maxLines, isNull);
          expect(label.overflow, isNot(TextOverflow.ellipsis));
          expect(tester.getSize(find.text(longLabel)).height, greaterThan(60));
          expect(
            tester.getSize(find.byKey(const ValueKey('whatsapp-copy-0'))),
            const Size.square(NotionSize.touchTarget),
          );
          await tester.ensureVisible(find.text(_status));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(longQuestion), findsOneWidget);
        },
      );
    }

    testWidgets(
      'WhatsApp actions and read-only poll golden ${brightness.name}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 680);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('whatsapp-golden'),
            child: _app(
              Builder(
                builder: (context) {
                  final tokens = context.notion;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.colors.surface,
                          borderRadius: NotionRadius.mdAll,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(NotionSpace.sm),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'See you at the community meetup on Friday.',
                                style: tokens.typography.body,
                              ),
                              const SizedBox(height: NotionSpace.sm),
                              _urlActions(),
                              const SizedBox(height: NotionSpace.xl),
                              _poll,
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: NotionSpace.md),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.palette.bubble,
                          borderRadius: NotionRadius.mdAll,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(NotionSpace.sm),
                          child: NotionWhatsAppActions(
                            actions: [_actions[0]],
                            textColor: tokens.palette.onBubble,
                            linkColor: tokens.palette.onBubble,
                            backgroundColor: tokens.palette.bubble,
                            onOpen: (_) {},
                            onCopy: (_) {},
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              brightness: brightness,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const Key('whatsapp-golden')),
          matchesGoldenFile(
            'goldens/primitives/whatsapp-message-${brightness.name}.png',
          ),
        );
      },
    );
  }
}
