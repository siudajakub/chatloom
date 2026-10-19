// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:fluffychat/config/routes.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_style/settings_style_view.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_settings_page.dart';
import 'package:fluffychat/ui/notion/notion_motion.dart';
import 'package:fluffychat/ui/notion/notion_theme.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
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
  _Account() : super('fictional motion account', database: _NoDatabase());
  @override
  String? get userID => '@motion-fixture:example.invalid';
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

/// Mounts the real settings shell under a fixture inbox, like the app.
Future<GoRouter> _mount(
  WidgetTester tester, {
  required String path,
  double width = 390,
  bool disableAnimations = false,
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
        pageBuilder: (context, state) => AppRoutes.defaultPageBuilder(
          context,
          state,
          const Scaffold(body: Text('Chats fixture')),
        ),
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
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        supportedLocales: const [Locale('en')],
        localizationsDelegates: L10n.localizationsDelegates,
        theme: NotionTheme.build(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        routerConfig: router,
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

/// Horizontal offsets applied by the Notion transitions around [finder],
/// nearest page first.
List<double> _offsets(WidgetTester tester, Finder finder) => find
    .ancestor(of: finder, matching: find.byType(NotionPageTransition))
    .evaluate()
    .map((element) {
      FractionalTranslation? translation;
      void visit(Element e) {
        if (translation != null) return;
        if (e.widget is FractionalTranslation) {
          translation = e.widget as FractionalTranslation;
          return;
        }
        e.visitChildElements(visit);
      }

      element.visitChildElements(visit);
      return translation!.translation.dx;
    })
    .toList();

Future<void> _backGesture(
  WidgetTester tester,
  String method, [
  double? progress,
]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  'flutter/backgesture',
  const StandardMethodCodec().encodeMethodCall(
    MethodCall(
      method,
      progress == null
          ? null
          : <String, Object?>{
              'touchOffset': <double>[5, 300],
              'progress': progress,
              'swipeEdge': 0,
            },
    ),
  ),
  (_) {},
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() {
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoFiles();
    addTearDown(() => PathProviderPlatform.instance = original);
  });

  test('theme maps every platform to the Notion motion', () {
    for (final brightness in Brightness.values) {
      final builders = NotionTheme.build(
        brightness,
      ).pageTransitionsTheme.builders;
      for (final platform in TargetPlatform.values) {
        expect(
          builders[platform],
          platform == TargetPlatform.iOS
              ? isA<CupertinoPageTransitionsBuilder>()
              : isA<NotionPageTransitionsBuilder>(),
          reason: '$platform',
        );
      }
    }
    expect(
      const NotionPageTransitionsBuilder().transitionDuration,
      NotionMotion.forward,
    );
  });

  testWidgets('Appearance slides in from the settings index on phones', (
    tester,
  ) async {
    final router = await _mount(tester, path: '/rooms/settings');
    await tester.tap(find.text('Appearance'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final style = find.byType(SettingsStyleView);
    expect(style, findsOneWidget);
    final animation = ModalRoute.of(tester.element(style))!.animation!;
    expect(animation.value, inExclusiveRange(0, 1));
    expect(_offsets(tester, style).any((dx) => dx > 0), isTrue);
    // The index underneath stays visible (parallax), never a blank frame.
    expect(find.byType(NotionSettingsPage), findsOneWidget);
    // The message preview is built only after the slide finished.
    expect(find.text('Lorem ipsum dolor sit amet'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Lorem ipsum dolor sit amet'), findsOneWidget);
    expect(router.state.uri.path, '/rooms/settings/style');
    expect(_offsets(tester, style).every((dx) => dx == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening settings from the inbox animates and back pops', (
    tester,
  ) async {
    final router = await _mount(tester, path: '/rooms');
    router.go('/rooms/settings');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final page = find.byType(NotionSettingsPage);
    expect(page, findsOneWidget);
    expect(_offsets(tester, page).any((dx) => dx > 0), isTrue);
    expect(find.text('Chats fixture', skipOffstage: false), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_offsets(tester, page).every((dx) => dx == 0), isTrue);

    // The header back button is a real pop with a reverse transition.
    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(NotionSettingsPage), findsOneWidget);
    expect(_offsets(tester, page).any((dx) => dx > 0), isTrue);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/rooms');
    expect(find.text('Chats fixture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two-column settings switch panes instantly', (tester) async {
    final router = await _mount(tester, path: '/rooms/settings', width: 1365);
    router.go('/rooms/settings/style');
    await tester.pump();
    final style = find.byType(SettingsStyleView);
    expect(style, findsOneWidget);
    expect(ModalRoute.of(tester.element(style))!.animation!.value, 1);
    expect(_offsets(tester, style).every((dx) => dx == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion removes movement from every page', (
    tester,
  ) async {
    await _mount(tester, path: '/rooms/settings', disableAnimations: true);
    await tester.tap(find.text('Appearance'));
    await tester.pump();
    final style = find.byType(SettingsStyleView);
    expect(style, findsOneWidget);
    expect(ModalRoute.of(tester.element(style))!.animation!.value, 1);
    expect(_offsets(tester, style).every((dx) => dx == 0), isTrue);

    // Imperative pushes keep only a short fade.
    final navigator = Navigator.of(tester.element(style));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Pushed fixture')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final pushed = find.text('Pushed fixture');
    expect(_offsets(tester, pushed).every((dx) => dx == 0), isTrue);
    final opacity = tester
        .widgetList<Opacity>(
          find.ancestor(of: pushed, matching: find.byType(Opacity)),
        )
        .map((o) => o.opacity)
        .reduce((a, b) => a * b);
    expect(opacity, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden pages keep their identical child across navigation', (
    tester,
  ) async {
    var builds = 0;
    final router = GoRouter(
      initialLocation: '/rooms',
      routes: [
        GoRoute(
          path: '/rooms',
          pageBuilder: (context, state) => AppRoutes.defaultPageBuilder(
            context,
            state,
            _BuildCounter(() => builds++),
          ),
          routes: [
            GoRoute(
              path: 'detail',
              pageBuilder: (context, state) => AppRoutes.defaultPageBuilder(
                context,
                state,
                const Scaffold(body: Text('Detail fixture')),
              ),
              routes: [
                GoRoute(
                  path: 'more',
                  pageBuilder: (context, state) => AppRoutes.defaultPageBuilder(
                    context,
                    state,
                    const Scaffold(body: Text('More fixture')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: NotionTheme.build(Brightness.dark),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
    expect(builds, 1);
    router.go('/rooms/detail');
    await tester.pumpAndSettle();
    router.go('/rooms/detail/more');
    await tester.pumpAndSettle();
    router.go('/rooms/detail');
    await tester.pumpAndSettle();
    expect(find.text('Detail fixture'), findsOneWidget);
    expect(builds, 1);
    router.go('/rooms?filter=fixture');
    await tester.pumpAndSettle();
    expect(builds, 2, reason: 'a changed query is a new signature');
  });

  testWidgets('predictive back pops one settings page, then settings', (
    tester,
  ) async {
    final router = await _mount(tester, path: '/rooms/settings');
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    final style = find.byType(SettingsStyleView);
    final route = ModalRoute.of(tester.element(style))!;

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.5);
    await tester.pump();
    expect(route.animation!.value, closeTo(0.5, 0.001));
    expect(_offsets(tester, style).first, greaterThan(0));
    await _backGesture(tester, 'commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // The commit continues from the released position, it does not jump
    // back to fully visible first.
    expect(_offsets(tester, style).first, greaterThan(0.1));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/rooms/settings');
    expect(find.byType(NotionSettingsPage), findsOneWidget);

    // On the index, the gesture moves the whole settings shell.
    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.3);
    await tester.pump();
    expect(find.text('Chats fixture'), findsOneWidget);
    await _backGesture(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/rooms/settings');

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.4);
    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/rooms');
    expect(find.text('Chats fixture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dialog on top declines the predictive back gesture', (
    tester,
  ) async {
    final router = await _mount(tester, path: '/rooms/settings');
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    final style = find.byType(SettingsStyleView);
    showDialog<void>(
      context: tester.element(style),
      useRootNavigator: false,
      builder: (_) => const Dialog(child: Text('Dialog fixture')),
    );
    await tester.pumpAndSettle();
    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.5);
    await tester.pump();
    expect(ModalRoute.of(tester.element(style))!.animation!.value, 1);
    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    // The framework pops the dialog only.
    expect(find.text('Dialog fixture'), findsNothing);
    expect(router.state.uri.path, '/rooms/settings/style');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AfterRouteTransition shows the placeholder while animating', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: NotionTheme.build(Brightness.dark),
        home: const Scaffold(body: Text('Home fixture')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: AfterRouteTransition(
            placeholder: Text('Placeholder fixture'),
            child: Text('Heavy fixture'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Placeholder fixture'), findsOneWidget);
    expect(find.text('Heavy fixture'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Heavy fixture'), findsOneWidget);
  });
}

class _BuildCounter extends StatelessWidget {
  final VoidCallback onBuild;
  const _BuildCounter(this.onBuild);
  @override
  Widget build(BuildContext context) {
    onBuild();
    return const Scaffold(body: Text('Inbox fixture'));
  }
}
