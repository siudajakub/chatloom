// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 6 legacy pages and onboarding: the single-choice row, the permission
// level sheet, the double-tap reaction sheet, the recovery-key copy button
// (clipboard only, never the share sheet) and the ChatLoom intro copy.
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/bootstrap/widgets/store_recovery_key_view.dart';
import 'package:chatloom/pages/chat_permissions_settings/permission_list_tile.dart';
import 'package:chatloom/pages/intro/intro_page.dart';
import 'package:chatloom/pages/settings_chat/settings_chat_view.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: NotionTheme.build(brightness),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: home,
    );

void main() {
  group('NotionChoiceRow', () {
    testWidgets('shows a check on the selected option and reports taps', (
      tester,
    ) async {
      var tapped = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Column(
              children: [
                NotionChoiceRow(
                  title: 'Fictional first',
                  selected: true,
                  onTap: () => tapped++,
                ),
                NotionChoiceRow(
                  title: 'Fictional second',
                  subtitle: 'Fictional detail',
                  selected: false,
                  onTap: () => tapped++,
                ),
                const NotionChoiceRow(
                  title: 'Fictional disabled',
                  selected: false,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('Fictional detail'), findsOneWidget);
      await tester.tap(find.text('Fictional second'));
      await tester.tap(find.text('Fictional disabled'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        tester
            .getSemantics(find.text('Fictional first'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );
      handle.dispose();
    });

    testWidgets('fits a 320 pt screen at 2x text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: _app(
            const Scaffold(
              body: NotionChoiceRow(
                title: 'Members only (since they were invited)',
                subtitle: 'Fictional longer explanation of the option',
                selected: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('PermissionsListTile', () {
    Future<List<int?>> pumpTile(
      WidgetTester tester, {
      bool canEdit = true,
    }) async {
      final changes = <int?>[];
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: PermissionsListTile(
              permissionKey: 'invite',
              permission: 0,
              canEdit: canEdit,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return changes;
    }

    testWidgets('a level is chosen in a Notion sheet', (tester) async {
      final changes = await pumpTile(tester);
      final l10n = L10n.of(tester.element(find.byType(PermissionsListTile)));
      expect(find.text(l10n.inviteOtherUsers), findsOneWidget);
      expect(find.text(l10n.userLevel(0)), findsOneWidget);
      expect(find.byType(DropdownButton<int>), findsNothing);

      await tester.tap(find.text(l10n.inviteOtherUsers));
      await tester.pumpAndSettle();
      expect(find.byType(NotionSheet), findsOneWidget);
      await tester.tap(find.text(l10n.moderatorLevel(50)));
      await tester.pumpAndSettle();
      expect(changes, [50]);

      // "Custom" hands over to the controller's number chooser.
      await tester.tap(find.text(l10n.inviteOtherUsers));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.custom));
      await tester.pumpAndSettle();
      expect(changes, [50, null]);

      // The current level or a dismissed sheet changes nothing.
      await tester.tap(find.text(l10n.inviteOtherUsers));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.userLevel(0)).last);
      await tester.pumpAndSettle();
      expect(changes, [50, null]);
    });

    testWidgets('read-only without the permission', (tester) async {
      await pumpTile(tester, canEdit: false);
      final l10n = L10n.of(tester.element(find.byType(PermissionsListTile)));
      await tester.tap(find.text(l10n.inviteOtherUsers));
      await tester.pumpAndSettle();
      expect(find.byType(NotionSheet), findsNothing);
    });
  });

  testWidgets('double-tap reaction picker is a Notion sheet with Automatic', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    late BuildContext context;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (c) {
            context = c;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final result = showDoubleTapReactionPicker(context);
    await tester.pumpAndSettle();
    expect(find.byType(NotionSheet), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text(L10n.of(context).doubleTapReaction), findsOneWidget);
    await tester.tap(find.byKey(const Key('double_tap_reaction_automatic')));
    await tester.pumpAndSettle();
    expect(await result, '');
  });

  group('RecoveryKeyField', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      debugSystemShowsClipboardOverlay = null;
    });

    for (final systemOverlay in [false, true]) {
      testWidgets(
        'copy writes the clipboard only (system overlay: $systemOverlay)',
        (tester) async {
          debugSystemShowsClipboardOverlay = systemOverlay;
          const key = 'EsTF ictI onal Reco very Key0';
          await tester.pumpWidget(
            _app(
              const Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(NotionSpace.md),
                  child: RecoveryKeyField(recoveryKey: key),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byTooltip('Copy recovery key'), findsOneWidget);
          await tester.tap(find.byTooltip('Copy recovery key'));
          await tester.pumpAndSettle();
          final clipboard = calls
              .where((call) => call.method == 'Clipboard.setData')
              .toList();
          expect(clipboard, hasLength(1));
          expect((clipboard.single.arguments as Map)['text'], key);
          // Confirmed by the button itself, and by a snackbar only where
          // the system does not show its own clipboard overlay.
          expect(find.byTooltip('Recovery key copied'), findsOneWidget);
          expect(
            find.text('Recovery key copied'),
            systemOverlay ? findsNothing : findsOneWidget,
          );
        },
      );
    }
  });

  group('IntroPage', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
    });

    testWidgets('speaks about ChatLoom and Beeper, keeps other servers', (
      tester,
    ) async {
      var logins = 0;
      await tester.pumpWidget(
        _app(
          IntroPage(
            isLoading: false,
            loggingInToHomeserver: null,
            hasPresetHomeserver: false,
            welcomeText: null,
            login: () => logins++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(IntroPage.title), findsOneWidget);
      expect(find.text(IntroPage.description), findsOneWidget);
      expect(find.textContaining('[matrix]'), findsNothing);
      final l10n = L10n.of(tester.element(find.byType(IntroPage)));
      expect(find.text(l10n.createNewAccount), findsNothing);
      expect(find.byType(PopupMenuButton), findsNothing);
      expect(find.text('Use another server'), findsOneWidget);

      await tester.tap(find.byKey(const Key('intro_sign_in')));
      await tester.pump();
      expect(logins, 1);

      // The Matrix ID login stays available as an advanced option.
      await tester.tap(find.byKey(const Key('intro_more')));
      await tester.pumpAndSettle();
      expect(find.byType(NotionSheet), findsOneWidget);
      expect(find.byKey(const Key('intro_matrix_id_login')), findsOneWidget);
      expect(find.text(l10n.hydrate), findsOneWidget);
    });

    testWidgets('a busy Beeper sign-in cannot be started twice', (
      tester,
    ) async {
      var logins = 0;
      await tester.pumpWidget(
        _app(
          IntroPage(
            isLoading: false,
            loggingInToHomeserver: null,
            hasPresetHomeserver: false,
            welcomeText: null,
            loginBusy: true,
            login: () => logins++,
          ),
        ),
      );
      await tester.pump(NotionMotion.long);
      await tester.tap(find.byKey(const Key('intro_sign_in')));
      await tester.pump();
      expect(logins, 0);
    });
  });
}
