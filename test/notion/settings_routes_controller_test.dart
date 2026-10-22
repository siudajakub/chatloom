// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/config/routes.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_settings_adapter.dart';
import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/personal/ui/reminders_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoFiles extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw StateError('Synthetic unavailable storage; no files may be opened');
}

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Account extends Client {
  _Account() : super('fictional settings account', database: _NoDatabase());
  @override
  String? get userID => '@settings-fixture:example.invalid';
  @override
  String? get deviceID => 'fixture-device';
  @override
  String get fingerprintKey => 'fixture-public-fingerprint';
  @override
  bool get encryptionEnabled => false;
  @override
  bool isLogged() => true;
  @override
  Future<Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) async => Profile(userId: userId, displayName: 'Fictional account');
  @override
  Future<Capabilities> getCapabilities() async =>
      throw StateError('Synthetic offline capabilities');
  @override
  Future<GetAuthMetadataResponse> getAuthMetadata({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => throw StateError('Synthetic offline account management');
  @override
  Future<List<Pusher>> getPushers() async =>
      throw StateError('Synthetic offline push registration');
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

const _boundary = Key('settings-fixture-capture');
Future<GoRouter> _mount(
  WidgetTester tester, {
  required String path,
  double width = 390,
  double scale = 1,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  final client = _Account();
  final preferences = await SharedPreferences.getInstance();
  final outer = AppRoutes.routes.whereType<ShellRoute>().single;
  final rooms = outer.routes.whereType<GoRoute>().firstWhere(
    (r) => r.path == '/rooms',
  );
  final settings = rooms.routes.whereType<ShellRoute>().single;
  final router = GoRouter(
    initialLocation: path,
    routes: [
      GoRoute(
        path: '/rooms',
        builder: (_, _) => const Scaffold(body: Text('Chats fixture')),
        routes: [settings],
      ),
    ],
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<MatrixState>.value(value: _Matrix(client, preferences)),
        Provider<ThemeController>.value(value: ThemeController()),
        Provider<AppLock>.value(value: AppLock()),
      ],
      child: RepaintBoundary(
        key: _boundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          supportedLocales: const [Locale('en')],
          localizationsDelegates: L10n.localizationsDelegates,
          theme: NotionTheme.build(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    PersonalClient.of(client).dispose();
    router.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  return router;
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['SETTINGS_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  await tester.runAsync(() async {
    final pixels = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    pixels.dispose();
  });
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    final fonts = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
    }
    await fonts.load();
    final iconFile = Platform.environment['SETTINGS_ICON_FONT'];
    if (iconFile != null) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(iconFile).readAsBytes()),
          ),
        );
      await loader.load();
    }
  });
  setUp(() {
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoFiles();
    addTearDown(() => PathProviderPlatform.instance = original);
  });

  testWidgets(
    'settings ignores unrelated personal changes but updates pending summary',
    (tester) async {
      await _mount(tester, path: '/rooms/settings');
      final context = tester.element(find.byType(NotionSettingsAdapter));
      final personal = PersonalClient.of(Matrix.of(context).client);
      NotionSettingsPage page() =>
          tester.widget(find.byType(NotionSettingsPage));
      final before = page();
      personal.notifyListeners();
      await tester.pump();
      expect(page(), same(before));
      personal.pending['synthetic-command'] = PersonalOperation(
        opId: 'synthetic-command',
        kind: 'put',
        entityId: 'org:synthetic',
        createdAt: DateTime.utc(2026),
        payload: {},
      );
      personal.notifyListeners();
      await tester.pump();
      expect(page(), isNot(same(before)));
      expect(tester.takeException(), isNull);
    },
  );

  test('settings routes keep ChatLoom pages and drop FluffyChat leftovers', () {
    final outer = AppRoutes.routes.whereType<ShellRoute>().single;
    final rooms = outer.routes.whereType<GoRoute>().firstWhere(
      (r) => r.path == '/rooms',
    );
    final shell = rooms.routes.whereType<ShellRoute>().single;
    final settings = shell.routes.whereType<GoRoute>().single;
    final paths = <String>{};
    void collect(GoRoute route, String prefix) {
      final path = prefix.isEmpty ? route.path : '$prefix/${route.path}';
      paths.add(path);
      for (final child in route.routes.whereType<GoRoute>()) {
        collect(child, path);
      }
    }

    for (final child in settings.routes.whereType<GoRoute>()) {
      collect(child, '');
    }
    for (final kept in [
      'account',
      'style',
      'notifications',
      'notifications/diagnostics',
      'notifications/registration',
      'notifications/rules',
      'push',
      'security',
      'security/ignorelist',
      'devices',
      'recovery',
      'chat',
      'chat/media',
      'people',
      'networks',
      'transcriptions',
      'reminders',
      'scheduled',
      'bookmarks',
      'sync',
      'advanced',
    ]) {
      expect(paths, contains(kept));
    }
    for (final removed in [
      'about',
      'homeserver',
      'addaccount',
      'organization',
      'chat/emotes',
      'security/password',
      'security/3pid',
    ]) {
      expect(paths, isNot(contains(removed)));
    }
    // Every settings index row opens a registered route.
    for (final category in NotionSettingsCategory.values) {
      if (category == NotionSettingsCategory.account) continue;
      expect(paths, contains(category.path), reason: category.title);
    }
    // Room stickers & emotes were a FluffyChat leftover as well.
    final room = rooms.routes.whereType<GoRoute>().firstWhere(
      (r) => r.path == ':roomid',
    );
    final details = room.routes.whereType<GoRoute>().firstWhere(
      (r) => r.path == 'details',
    );
    expect(
      details.routes.whereType<GoRoute>().map((r) => r.path),
      isNot(contains('emotes')),
    );
  });

  for (final entry in const {
    'account': 'Change display name',
    'security': 'Incognito mode',
    'chat': 'Voice messages & round videos',
    'style': 'Appearance',
    'networks': 'No networks yet',
    'people': 'Merge conversations',
    'sync': 'Private sync not connected',
    'transcriptions': 'Transcription service',
    'bookmarks': 'No bookmarks',
    'reminders': 'No reminders',
    'scheduled': 'No scheduled messages',
    'push': 'Set up notifications automatically',
    'notifications': 'Push setup',
    'developer': 'App configuration',
    'notifications/registration': 'Could not load registered devices',
    'notifications/rules': 'Rules are not available yet',
    'recovery': 'Key backup',
    'advanced': 'About ChatLoom',
  }.entries) {
    testWidgets(
      'actual route ${entry.key} works offline and returns to index',
      (tester) async {
        final router = await _mount(
          tester,
          path: '/rooms/settings/${entry.key}',
        );
        expect(find.text(entry.value), findsWidgets);
        expect(find.text('Labels'), findsNothing);
        expect(find.text('My labels'), findsNothing);
        if (entry.key == 'push') {
          final row = find.widgetWithText(
            ListTile,
            'Set up notifications automatically',
          );
          // Manual gateway setup moved to Advanced › Developer (CS-02).
          expect(find.text('Advanced notification settings'), findsNothing);
          expect(find.text('Configure a gateway manually'), findsNothing);
          final texts = tester.widgetList<RichText>(
            find.descendant(
              of: find.descendant(of: row, matching: find.byType(Text)),
              matching: find.byType(RichText),
            ),
          );
          expect(texts, isNotEmpty);
          for (final text in texts) {
            expect(text.text.style?.fontFamily, 'Roboto');
          }
        }
        if (entry.key == 'developer') {
          expect(find.text('Configure a gateway manually'), findsOneWidget);
          expect(find.text('Copy push registration (secrets)'), findsOneWidget);
          expect(find.text('Share keys with'), findsWidgets);
        }
        expect(tester.takeException(), isNull);
        await _capture(tester, 'route-${entry.key.replaceAll('/', '-')}-390');
        router.pop();
        await tester.pumpAndSettle();
        if (entry.key.contains('/')) {
          router.pop();
          await tester.pumpAndSettle();
        }
        expect(router.state.uri.path, '/rooms/settings');
        expect(find.text('Settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reminders page lists saving, upcoming and recent reminders', (
    tester,
  ) async {
    await _mount(tester, path: '/rooms/settings/reminders');
    expect(find.text('No reminders'), findsOneWidget);
    final context = tester.element(find.byType(RemindersPage));
    final personal = PersonalClient.of(Matrix.of(context).client);
    final now = DateTime.now();
    const conversation = {
      'accountId': '@settings-fixture:example.invalid',
      'roomId': '!fixture:example.invalid',
      'network': 'telegram',
    };
    personal.reminders['upcoming'] = {
      'kind': 'reminder',
      'conversation': conversation,
      'dueAt': now.add(const Duration(days: 2)).toUtc().toIso8601String(),
      'state': 'queued',
      'revision': 1,
      'untilReply': true,
    };
    personal.reminders['fired'] = {
      'kind': 'reminder',
      'conversation': conversation,
      'dueAt': now.subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
      'state': 'done',
      'revision': 2,
    };
    // Fired by the worker's grace although it could not read the history.
    personal.reminders['unchecked'] = {
      'kind': 'reminder',
      'conversation': conversation,
      'dueAt': now.subtract(const Duration(hours: 4)).toUtc().toIso8601String(),
      'state': 'done',
      'due': true,
      'revision': 3,
      'untilReply': true,
      'replyCheck': 'skipped',
      'replyCheckError': 'waiting_keys',
    };
    personal.pending['op-new'] = PersonalOperation(
      opId: 'op-new',
      kind: 'reminder.create',
      entityId: 'new',
      createdAt: DateTime.utc(2026),
      payload: {
        'id': 'new',
        'conversation': conversation,
        'dueAt': now.add(const Duration(hours: 3)).toUtc().toIso8601String(),
        'untilReply': false,
      },
    );
    addTearDown(() {
      personal.reminders.clear();
      personal.pending.clear();
    });
    personal.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('No reminders'), findsNothing);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.textContaining('Saving…'), findsOneWidget);
    expect(find.textContaining('Only if no reply'), findsOneWidget);
    expect(find.textContaining('· Done'), findsNWidgets(2));
    expect(
      find.textContaining('Done · couldn’t check for replies'),
      findsOneWidget,
    );
    // Private sync is not connected in the fixture: nothing can be changed.
    expect(find.text('Private sync is unavailable'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('New reminder'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic push setup remains readable at 320 and 200 percent', (
    tester,
  ) async {
    await _mount(tester, path: '/rooms/settings/push', width: 320, scale: 2);
    expect(find.text('Set up notifications automatically'), findsOneWidget);
    // Manual gateway setup lives in Advanced › Developer (CS-02).
    expect(find.text('Advanced notification settings'), findsNothing);
    expect(find.text('Configure a gateway manually'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('developer options reveal the developer tools row', (
    tester,
  ) async {
    await DeveloperOptions.setEnabled(false);
    addTearDown(() => DeveloperOptions.setEnabled(false));
    await _mount(tester, path: '/rooms/settings/advanced');
    expect(find.text('Developer options'), findsOneWidget);
    expect(find.text('Developer tools'), findsNothing);
    await tester.tap(find.text('Developer options'));
    await tester.pumpAndSettle();
    expect(DeveloperOptions.enabled, isTrue);
    expect(find.text('Developer tools'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile category round trip restores the index scroll offset', (
    tester,
  ) async {
    final router = await _mount(tester, path: '/rooms/settings');
    await tester.scrollUntilVisible(find.text('Scheduled messages'), 180);
    await tester.ensureVisible(find.text('Scheduled messages'));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    await tester.tap(find.text('Scheduled messages'));
    await tester.pumpAndSettle();
    expect(find.text('No scheduled messages'), findsOneWidget);
    expect(router.state.uri.path, '/rooms/settings/scheduled');
    router.pop();
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      position,
    );
  });

  testWidgets('desktop root opens Account and Escape returns to chats', (
    tester,
  ) async {
    await _mount(tester, path: '/rooms/settings', width: 1365);
    expect(find.text('Change display name'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Chats fixture'), findsOneWidget);
  });

  testWidgets('desktop privacy summary follows the effective device policy', (
    tester,
  ) async {
    await AppSettings.personalIncognito.setItem(true);
    await _mount(tester, path: '/rooms/settings/security', width: 1365);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(AppSettings.personalIncognito.value, isFalse);
    expect(
      find.text('Incognito off · App lock, devices and recovery'),
      findsOneWidget,
    );
    await AppSettings.personalIncognito.setItem(true);
  });

  testWidgets(
    'resizing keeps the current settings route and desktop selection',
    (tester) async {
      final router = await _mount(tester, path: '/rooms/settings/sync');
      tester.view.physicalSize = const Size(1365, 900);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/rooms/settings/sync');
      expect(find.text('Background service'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/rooms/settings/sync');
      expect(find.text('Background service'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 390.0, 430.0, 900.0, 1365.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        for (final page in ['', 'account', 'security']) {
          testWidgets('routed $page at $width/$scale/$brightness', (
            tester,
          ) async {
            await _mount(
              tester,
              path: page.isEmpty ? '/rooms/settings' : '/rooms/settings/$page',
              width: width,
              scale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            await _capture(
              tester,
              '${page.isEmpty ? 'overview' : page}-${width.toInt()}-${scale.toInt()}-${brightness.name}',
            );
          });
        }
      }
    }
  }
}
