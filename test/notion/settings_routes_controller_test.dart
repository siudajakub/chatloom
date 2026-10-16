// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fluffychat/config/routes.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/ui/notion/notion_theme.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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

  for (final entry in const {
    'account': 'Change display name',
    'security': 'Incognito mode',
    'chat': 'Conversation preferences',
    'style': 'Appearance',
    'organization': 'Choose a conversation',
    'networks': 'No networks loaded yet.',
    'people': 'Merge conversations',
    'sync': 'Private sync not connected',
    'transcriptions': 'Transcription service',
    'bookmarks': 'Bookmark a message to find it here later.',
    'reminders': 'No reminders',
    'scheduled': 'No scheduled messages',
    'push': 'Notification setup',
    'notifications': 'Push setup & registration',
    'notifications/registration': 'Could not load registered devices',
    'recovery': 'Key backup',
    'about': 'App information',
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
          final row = find.widgetWithText(ListTile, 'Notification setup');
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
      expect(find.text('Background services'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/rooms/settings/sync');
      expect(find.text('Background services'), findsOneWidget);
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
