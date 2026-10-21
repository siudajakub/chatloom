// SPDX-License-Identifier: AGPL-3.0-or-later
// Appearance settings: stored choices, migration of the old colour seed,
// live re-theming without restart, and the page itself.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/settings_style/settings_style.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
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

void main() {
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
      double scale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = await SharedPreferences.getInstance();
      final client = _Account();
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: _Matrix(client, preferences),
          child: ThemeBuilder(
            preferences: preferences,
            builder: (context, mode, appearance) => MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('en'),
              supportedLocales: const [Locale('en')],
              localizationsDelegates: L10n.localizationsDelegates,
              theme: NotionTheme.build(Brightness.dark, appearance),
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
      );
      await tester.pumpAndSettle();
      return preferences;
    }

    Finder ownBubbleFill() => find.descendant(
      of: find.widgetWithText(ConversationBubble, 'At vero eos et accusam'),
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
      expect(balanced.gradient, isNull);
      expect(
        balanced.color,
        NotionPalette.resolve(
          NotionAppearance.standard,
          NotionColors.dark,
          Brightness.dark,
        ).bubble,
      );

      await tester.tap(find.bySemanticsLabel(RegExp('^Vivid colours')));
      await tester.pumpAndSettle();
      expect(ownDecoration(tester).gradient, isA<LinearGradient>());
      expect(
        preferences.getString(AppSettings.appearanceIntensity.key),
        'vivid',
      );

      await tester.tap(find.bySemanticsLabel('Pink accent'));
      await tester.pumpAndSettle();
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
        pink.bubbleGradient,
      );
      expect(preferences.getString(AppSettings.appearanceAccent.key), 'pink');

      await tester.tap(find.bySemanticsLabel(RegExp('^Muted colours')));
      await tester.pumpAndSettle();
      expect(ownDecoration(tester).gradient, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits 320 pt at 200 percent text', (tester) async {
      await mount(tester, width: 320, scale: 2);
      expect(find.text('Colour intensity'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
