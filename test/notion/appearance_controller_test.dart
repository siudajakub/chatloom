// SPDX-License-Identifier: AGPL-3.0-or-later
// Appearance settings: stored choices, migration of the old colour seed,
// live re-theming without restart, and the page itself.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/settings_style/settings_style.dart';
import 'package:chatloom/personal/ui/chat_appearance_dialog.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show ChatTheme;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Account extends Client {
  _Account() : super('fictional appearance account', database: _NoDatabase());
  @override
  String? get userID => '@appearance-fixture:example.invalid';
  @override
  bool isLogged() => true;
}

class _Matrix extends MatrixState {
  final Client active;
  final SharedPreferences preferences;
  _Matrix(this.active, this.preferences);
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [active], store: preferences);
}

/// Scrolls [finder] to the middle of the page: at the top edge it would sit
/// under the glass header and a tap would miss it.
Future<void> _reveal(WidgetTester tester, Finder finder) =>
    Scrollable.ensureVisible(tester.element(finder), alignment: .5);

const _captureKey = Key('appearance-capture');

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['CONVERSATION_CAPTURE_DIR'];
  if (output == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    final roboto = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await roboto.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  group('ThemeBuilder', () {
    test('reads stored choices and migrates the old colour seed', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        ThemeBuilder.readAppearance(await SharedPreferences.getInstance()),
        NotionAppearance.standard,
      );
      SharedPreferences.setMockInitialValues({
        ThemeBuilder.legacyPrimaryColorKey: 0xFF4CAF50,
      });
      expect(
        ThemeBuilder.readAppearance(await SharedPreferences.getInstance()),
        const NotionAppearance(
          accent: NotionAccent.green,
          intensity: NotionIntensity.balanced,
        ),
      );
      SharedPreferences.setMockInitialValues({
        ThemeBuilder.legacyPrimaryColorKey: 0xFF4CAF50,
        AppSettings.appearanceAccent.key: 'teal',
        AppSettings.appearanceIntensity.key: 'muted',
      });
      expect(
        ThemeBuilder.readAppearance(await SharedPreferences.getInstance()),
        const NotionAppearance(
          accent: NotionAccent.teal,
          intensity: NotionIntensity.muted,
        ),
      );
    });
  });

  group('Appearance page', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
    });

    Future<SharedPreferences> mount(
      WidgetTester tester, {
      double width = 390,
      double height = 1400,
      double scale = 1,
      Brightness brightness = Brightness.dark,
      TargetPlatform platform = TargetPlatform.android,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, height);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('theme_mode', brightness.name);
      final client = _Account();
      await tester.pumpWidget(
        RepaintBoundary(
          key: _captureKey,
          child: Provider<MatrixState>.value(
            value: _Matrix(client, preferences),
            child: ThemeBuilder(
              preferences: preferences,
              builder: (context, mode, appearance) => MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: const Locale('en'),
                supportedLocales: const [Locale('en')],
                localizationsDelegates: L10n.localizationsDelegates,
                theme: ChatLoomThemes.buildTheme(
                  context,
                  brightness,
                  appearance,
                  ThemeController.of(context).displayPreferences,
                ).copyWith(platform: platform),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const SettingsStyle(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return preferences;
    }

    Finder ownBubbleFill() => find.descendant(
      of: find.widgetWithText(ConversationBubble, 'How about ten?'),
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration,
      ),
    );

    BoxDecoration ownDecoration(WidgetTester tester) =>
        tester.widget<Container>(ownBubbleFill().first).decoration!
            as BoxDecoration;

    testWidgets('intensity and accent re-theme the app at once', (
      tester,
    ) async {
      final preferences = await mount(tester);
      expect(find.text('Colour intensity'), findsOneWidget);
      expect(find.text('Accent colour'), findsOneWidget);
      // Removed FluffyChat leftovers.
      expect(find.text('Font size'), findsNothing);
      expect(find.byType(GridView), findsNothing);

      final balanced = ownDecoration(tester);
      expect(balanced.gradient, isA<LinearGradient>());
      expect(
        (balanced.gradient! as LinearGradient).colors,
        NotionPalette.resolve(
          NotionAppearance.standard,
          NotionColors.dark,
          Brightness.dark,
        ).bubbleGradient!.map(
          (color) => color.withValues(alpha: NotionBubble.fillOpacity),
        ),
      );

      await tester.tap(find.bySemanticsLabel(RegExp('^Vivid colours')));
      await tester.pumpAndSettle();
      expect(ownDecoration(tester).gradient, isA<LinearGradient>());
      expect(
        preferences.getString(AppSettings.appearanceIntensity.key),
        'vivid',
      );

      // The page follows its own choice (it is a const route child that the
      // new theme alone would not rebuild).
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^Vivid colours'))),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^Balanced colours'))),
        isSemantics(isSelected: false),
      );

      await tester.tap(find.bySemanticsLabel('Pink accent'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Pink accent')),
        isSemantics(isSelected: true),
      );
      final pink = NotionPalette.resolve(
        const NotionAppearance(
          accent: NotionAccent.pink,
          intensity: NotionIntensity.vivid,
        ),
        NotionColors.dark,
        Brightness.dark,
      );
      expect(
        (ownDecoration(tester).gradient! as LinearGradient).colors,
        pink.bubbleGradient!.map(
          (color) => color.withValues(alpha: NotionBubble.fillOpacity),
        ),
      );
      expect(preferences.getString(AppSettings.appearanceAccent.key), 'pink');

      await tester.tap(find.bySemanticsLabel(RegExp('^Muted colours')));
      await tester.pumpAndSettle();
      expect(ownDecoration(tester).gradient, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('layout controls persist and reset without resetting colours', (
      tester,
    ) async {
      final preferences = await mount(tester);
      await _reveal(tester, find.text('Network badges'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Network badges'));
      await tester.pumpAndSettle();
      expect(
        ThemeBuilder.readDisplayPreferences(preferences).inboxNetworkBadges,
        isFalse,
      );
      await _reveal(tester, find.text('Reduce motion'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reduce motion'));
      await tester.pumpAndSettle();
      expect(
        ThemeBuilder.readDisplayPreferences(preferences).reduceMotion,
        isTrue,
      );
      await _reveal(tester, find.text('Reset layout and effects'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset layout and effects'));
      await tester.pumpAndSettle();
      expect(
        ThemeBuilder.readDisplayPreferences(preferences),
        NotionDisplayPreferences.standard,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('wave 8 options persist from the page', (tester) async {
      final preferences = await mount(tester);
      Future<void> tapText(String text) async {
        await _reveal(tester, find.text(text));
        await tester.pumpAndSettle();
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      }

      await tapText('Pure black');
      await tapText('Two-line previews');
      await tapText('Sender names');
      await tapText('Delivery ticks');
      await tapText('Haptic feedback');
      var stored = ThemeBuilder.readDisplayPreferences(preferences);
      expect(stored.trueBlack, isTrue);
      expect(stored.inboxPreviewLines, 2);
      expect(stored.senderNames, isFalse);
      expect(stored.deliveryTicks, isFalse);
      expect(stored.haptics, isFalse);

      await tapText('Chat background');
      final ocean = find.bySemanticsLabel('Ocean background');
      await _reveal(tester, ocean);
      await tester.pumpAndSettle();
      await tester.tap(ocean);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply background'));
      await tester.pumpAndSettle();
      stored = ThemeBuilder.readDisplayPreferences(preferences);
      expect(stored.wallpaperPreset, NotionWallpaperPreset.ocean);
      expect(find.text('Background strength · 50%'), findsOneWidget);

      await tapText('Outgoing bubbles');
      await tester.tap(find.text('Colour blend').last);
      await tester.pumpAndSettle();
      expect(
        ThemeBuilder.readDisplayPreferences(preferences).bubbleFinish,
        NotionBubbleFinish.gradient,
      );

      await tapText('Message times');
      await tester.tap(find.text('Every message').last);
      await tester.pumpAndSettle();
      await tapText('Clock');
      await tester.tap(find.text('24-hour').last);
      await tester.pumpAndSettle();
      stored = ThemeBuilder.readDisplayPreferences(preferences);
      expect(stored.messageTimestamps, NotionTimestampMode.every);
      expect(stored.clockFormat, NotionClockFormat.h24);

      // Custom accent: the picker's colour replaces the preset.
      final custom = find.bySemanticsLabel('Custom accent');
      await _reveal(tester, custom);
      await tester.pumpAndSettle();
      await tester.tap(custom);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('custom_accent_apply')));
      await tester.pumpAndSettle();
      expect(
        preferences.getString(AppSettings.appearanceCustomAccent.key),
        matches(RegExp(r'^#[0-9A-F]{6}$')),
      );
      // A preset clears it again.
      final pink = find.bySemanticsLabel('Pink accent');
      await _reveal(tester, pink);
      await tester.pumpAndSettle();
      await tester.tap(pink);
      await tester.pumpAndSettle();
      expect(preferences.getString(AppSettings.appearanceCustomAccent.key), '');

      // Reset colours returns to a new install's accent and intensity.
      await tapText('Reset colours');
      expect(
        ThemeBuilder.readAppearance(preferences),
        NotionAppearance.standard,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits 320 pt at 200 percent text', (tester) async {
      await mount(tester, width: 320, scale: 2);
      expect(find.text('Colour intensity'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('background picker previews changes before applying', (
      tester,
    ) async {
      final preferences = await mount(tester, height: 844);
      await _capture(tester, 'appearance-mobile');
      final open = find.text('Chat background');
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Aurora background'));
      await tester.pumpAndSettle();
      expect(
        ThemeBuilder.readDisplayPreferences(preferences).wallpaperPreset,
        NotionWallpaperPreset.none,
      );
      await _capture(tester, 'background-picker-mobile');
      await tester.tap(find.text('Apply background'));
      await tester.pumpAndSettle();
      expect(
        ThemeBuilder.readDisplayPreferences(preferences).wallpaperPreset,
        NotionWallpaperPreset.aurora,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('private theme picker saves, resets or cancels', (
      tester,
    ) async {
      await mount(
        tester,
        width: 1100,
        height: 760,
        brightness: Brightness.light,
        platform: TargetPlatform.macOS,
      );
      final context = tester.element(find.byType(SettingsStyle));
      Future<({ChatTheme? theme})?> open([ChatTheme? initial]) =>
          showChatAppearanceDialog(
            context,
            accountConfig: const ApplicationAccountConfig(),
            initial: initial,
          );

      final pending = open();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blue hour'));
      await tester.pumpAndSettle();
      await _capture(tester, 'private-chat-appearance-desktop');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final persisted = (await pending)!.theme!;
      expect(persisted.wallpaperAsset, 'ocean');
      expect(persisted.outgoingColor, isNotNull);

      final cancelled = open(persisted);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await cancelled, isNull);

      final reset = open(persisted);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use default appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((await reset)!.theme, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
