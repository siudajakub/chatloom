// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/pages/bootstrap/bootstrap_page.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat_access_settings/chat_access_settings_controller.dart';
import 'package:chatloom/pages/chat_details/chat_details.dart';
import 'package:chatloom/pages/chat_encryption_settings/chat_encryption_settings.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_members/chat_members.dart';
import 'package:chatloom/pages/chat_permissions_settings/chat_permissions_settings.dart';
import 'package:chatloom/pages/device_settings/device_settings.dart';
import 'package:chatloom/pages/intro/intro_page_presenter.dart';
import 'package:chatloom/pages/invitation_selection/invitation_selection.dart';
import 'package:chatloom/pages/login/login.dart';
import 'package:chatloom/pages/new_group/new_group.dart';
import 'package:chatloom/pages/new_private_chat/new_private_chat.dart';
import 'package:chatloom/pages/settings/settings.dart';
import 'package:chatloom/pages/settings_chat/settings_chat.dart';
import 'package:chatloom/pages/settings_chat/settings_media_view.dart';
import 'package:chatloom/pages/settings_ignore_list/settings_ignore_list.dart';
import 'package:chatloom/pages/settings_notifications/settings_notifications.dart';
import 'package:chatloom/pages/settings_security/settings_security.dart';
import 'package:chatloom/pages/settings_style/settings_style.dart';
import 'package:chatloom/pages/sign_in/sign_in_page.dart';
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/personal/person_route.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/personal/ui/add_network_page.dart';
import 'package:chatloom/personal/ui/developer_settings_page.dart';
import 'package:chatloom/personal/stickers/sticker_settings_page.dart';
import 'package:chatloom/personal/ui/networks_page.dart';
import 'package:chatloom/personal/ui/push_diagnostics_page.dart';
import 'package:chatloom/personal/ui/reminders_page.dart';
import 'package:chatloom/ui/notion/notion_motion.dart';
import 'package:chatloom/widgets/config_viewer.dart';
import 'package:chatloom/widgets/layouts/empty_page.dart';
import 'package:chatloom/widgets/layouts/two_column_layout.dart';
import 'package:chatloom/widgets/log_view.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

abstract class AppRoutes {
  static FutureOr<String?> loggedInRedirect(
    BuildContext context,
    GoRouterState state,
  ) => Matrix.of(context).widget.clients.any((client) => client.isLogged())
      ? '/rooms'
      : null;

  static FutureOr<String?> loggedOutRedirect(
    BuildContext context,
    GoRouterState state,
  ) => Matrix.of(context).widget.clients.any((client) => client.isLogged())
      ? null
      : '/home';

  AppRoutes();

  static final List<RouteBase> routes = [
    GoRoute(
      path: '/',
      redirect: (context, state) =>
          Matrix.of(context).widget.clients.any((client) => client.isLogged())
          ? '/rooms'
          : '/home',
    ),
    GoRoute(
      path: '/home',
      pageBuilder: (context, state) =>
          defaultPageBuilder(context, state, const IntroPagePresenter()),
      redirect: loggedInRedirect,
      routes: [
        GoRoute(
          path: 'sign_in',
          pageBuilder: (context, state) =>
              defaultPageBuilder(context, state, SignInPage(signUp: false)),
          redirect: loggedInRedirect,
        ),
        GoRoute(
          path: 'sign_up',
          pageBuilder: (context, state) =>
              defaultPageBuilder(context, state, SignInPage(signUp: true)),
          redirect: loggedInRedirect,
        ),
        GoRoute(
          path: 'login',
          pageBuilder: (context, state) => defaultPageBuilder(
            context,
            state,
            Login(client: state.extra as Client),
          ),
          redirect: loggedInRedirect,
        ),
      ],
    ),
    GoRoute(
      path: '/logs',
      pageBuilder: (context, state) =>
          defaultPageBuilder(context, state, const LogViewer()),
    ),
    GoRoute(
      path: '/configs',
      pageBuilder: (context, state) =>
          defaultPageBuilder(context, state, const ConfigViewer()),
    ),
    GoRoute(
      path: '/backup',
      redirect: loggedOutRedirect,
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        BootstrapPage(reset: state.uri.queryParameters['reset'] == 'true'),
      ),
    ),
    ShellRoute(
      // Never use a transition on the shell route. The page type is always
      // [_AppPage]; only its durations follow the layout, so a MediaQuery
      // change never renders the child twice with the same GlobalKey.
      pageBuilder: (context, state, child) => noTransitionPageBuilder(
        context,
        state,
        ChatLoomThemes.isColumnMode(context) &&
                state.fullPath?.startsWith('/rooms/settings') == false
            ? TwoColumnLayout(
                mainView: ChatList(
                  activeChat: state.pathParameters['roomid'],
                  activeGroup: state.pathParameters['groupId'],
                ),
                sideView: child,
              )
            : child,
      ),
      routes: [
        GoRoute(
          path: '/rooms',
          redirect: loggedOutRedirect,
          pageBuilder: (context, state) => defaultPageBuilder(
            context,
            state,
            ChatLoomThemes.isColumnMode(context)
                ? const EmptyPage()
                // On phones the inbox is hidden under every child page, so it
                // has no selected row; keep it identical while children
                // change (see [_PageMemo]).
                : const ChatList(activeChat: null),
            memo: 'rooms',
          ),
          routes: [
            GoRoute(
              path: 'newprivatechat',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                NewPrivateChat(
                  key: ValueKey('new_chat_${state.uri.fragment}'),
                  deeplink: state.uri.fragment,
                ),
              ),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'newgroup',
              pageBuilder: (context, state) =>
                  defaultPageBuilder(context, state, const NewGroup()),
              redirect: loggedOutRedirect,
            ),
            ShellRoute(
              // The settings shell slides over the inbox on phones and is
              // instant in two-column mode (see [_AppPageRoute]).
              pageBuilder: (context, state, child) => _page(
                context,
                state,
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(
                          state.uri.path == '/rooms/settings'
                              ? '/rooms'
                              : '/rooms/settings',
                        );
                      }
                    },
                  },
                  child: Focus(
                    autofocus: true,
                    child: ChatLoomThemes.isColumnMode(context)
                        ? TwoColumnLayout(
                            mainView: const Settings(
                              key: ValueKey('settings-index'),
                            ),
                            sideView: child,
                          )
                        : child,
                  ),
                ),
                memoise: false,
              ),
              routes: [
                GoRoute(
                  path: 'settings',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    ChatLoomThemes.isColumnMode(context)
                        ? state.uri.path == '/rooms/settings'
                              ? const Settings(surface: SettingsSurface.account)
                              : const EmptyPage()
                        : const Settings(),
                    memo: (
                      'settings',
                      ChatLoomThemes.isColumnMode(context) &&
                          state.uri.path == '/rooms/settings',
                    ),
                  ),
                  routes: [
                    for (final entry in const {
                      'account': SettingsSurface.account,
                      'recovery': SettingsSurface.recovery,
                      'advanced': SettingsSurface.advanced,
                    }.entries)
                      GoRoute(
                        path: entry.key,
                        redirect: loggedOutRedirect,
                        pageBuilder: (context, state) => defaultPageBuilder(
                          context,
                          state,
                          Settings(surface: entry.value),
                        ),
                      ),
                    // Settings › Advanced › Developer (developer options).
                    GoRoute(
                      path: 'developer',
                      redirect: loggedOutRedirect,
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const DeveloperSettingsPage(),
                      ),
                    ),
                    for (final entry in const {
                      'sync': PersonalSettingsSection.sync,
                      'people': PersonalSettingsSection.people,
                      'transcriptions': PersonalSettingsSection.transcriptions,
                      'scheduled': PersonalSettingsSection.scheduled,
                      'push': PersonalSettingsSection.push,
                    }.entries)
                      GoRoute(
                        path: entry.key,
                        redirect: loggedOutRedirect,
                        pageBuilder: (context, state) => defaultPageBuilder(
                          context,
                          state,
                          PersonalSettingsPage(
                            client: Matrix.of(context).client,
                            section: entry.value,
                          ),
                        ),
                      ),
                    GoRoute(
                      path: 'networks',
                      redirect: loggedOutRedirect,
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        NetworksPage(
                          key: ValueKey(Matrix.of(context).client),
                          personal: PersonalClient.of(
                            Matrix.of(context).client,
                          ),
                        ),
                      ),
                      routes: [
                        GoRoute(
                          path: 'add',
                          redirect: loggedOutRedirect,
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            AddNetworkPage(
                              key: ValueKey(Matrix.of(context).client),
                              client: Matrix.of(context).client,
                              network: state.uri.queryParameters['network']
                                  ?.toLowerCase(),
                            ),
                          ),
                        ),
                        GoRoute(
                          path: ':network',
                          redirect: loggedOutRedirect,
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            NetworkDetailPage(
                              key: ValueKey(Matrix.of(context).client),
                              personal: PersonalClient.of(
                                Matrix.of(context).client,
                              ),
                              network: state.pathParameters['network']!
                                  .toLowerCase(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    GoRoute(
                      path: 'reminders',
                      redirect: loggedOutRedirect,
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        RemindersPage(
                          key: ValueKey(Matrix.of(context).client),
                          personal: PersonalClient.of(
                            Matrix.of(context).client,
                          ),
                        ),
                      ),
                    ),
                    GoRoute(
                      path: 'bookmarks',
                      redirect: loggedOutRedirect,
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        BookmarkSearchPage(
                          key: ValueKey(Matrix.of(context).client),
                          personal: PersonalClient.of(
                            Matrix.of(context).client,
                          ),
                        ),
                      ),
                    ),
                    GoRoute(
                      path: 'notifications',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsNotifications(),
                      ),
                      routes: [
                        GoRoute(
                          path: 'registration',
                          redirect: loggedOutRedirect,
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            const SettingsNotifications(
                              registrationDetails: true,
                            ),
                          ),
                        ),
                        GoRoute(
                          path: 'diagnostics',
                          redirect: loggedOutRedirect,
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            const PushDiagnosticsPage(),
                          ),
                        ),
                        GoRoute(
                          path: 'rules',
                          redirect: loggedOutRedirect,
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            const SettingsNotifications(serverRules: true),
                          ),
                        ),
                      ],
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'style',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsStyle(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'devices',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const DevicesSettings(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'chat',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsChat(),
                      ),
                      routes: [
                        GoRoute(
                          path: 'media',
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            const SettingsMediaPage(),
                          ),
                        ),
                        GoRoute(
                          path: 'stickers',
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            StickerSettingsPage(
                              key: ValueKey(Matrix.of(context).client),
                              client: Matrix.of(context).client,
                            ),
                          ),
                        ),
                      ],
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'security',
                      redirect: loggedOutRedirect,
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsSecurity(),
                      ),
                      routes: [
                        GoRoute(
                          path: 'ignorelist',
                          pageBuilder: (context, state) {
                            return defaultPageBuilder(
                              context,
                              state,
                              SettingsIgnoreList(
                                initialUserId: state.extra?.toString(),
                              ),
                            );
                          },
                          redirect: loggedOutRedirect,
                        ),
                      ],
                    ),
                  ],
                  redirect: loggedOutRedirect,
                ),
              ],
            ),
            GoRoute(
              path: 'person/:groupId',
              redirect: loggedOutRedirect,
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                PersonChatRoutePage(
                  key: ValueKey(('person', state.pathParameters['groupId'])),
                  groupId: state.pathParameters['groupId']!,
                  sourceRoomId: state.uri.queryParameters['source'],
                  eventId: state.uri.queryParameters['event'],
                ),
                // Opening a source chat keeps the identical person page below.
                memo: (
                  'person',
                  state.pathParameters['groupId'],
                  state.uri.queryParameters['source'],
                  state.uri.queryParameters['event'],
                ),
              ),
              // Member source chats with every ordinary chat child route.
              routes: [_chatRoute()],
            ),
            _chatRoute(),
          ],
        ),
      ],
    ),
  ];

  /// `:roomid` with its child routes (search, details, …). Mounted under
  /// `/rooms` and under `/rooms/person/:groupId`, so a source chat opened from
  /// a person keeps the merged conversation below it.
  static GoRoute _chatRoute() => GoRoute(
    path: ':roomid',
    pageBuilder: (context, state) {
      final body = state.uri.queryParameters['body'];
      var shareItems = state.extra is List<ShareItem>
          ? state.extra as List<ShareItem>
          : null;
      if (body != null && body.isNotEmpty) {
        shareItems ??= [];
        shareItems.add(TextShareItem(body));
      }
      return defaultPageBuilder(
        context,
        state,
        ChatPage(
          key: ValueKey(state.uri),
          roomId: state.pathParameters['roomid']!,
          shareItems: shareItems,
          eventId: state.uri.queryParameters['event'],
        ),
        // Only the chat's own parameters: opening details, search
        // or members keeps the identical chat page underneath.
        memo: (
          'chat',
          state.pathParameters['roomid'],
          state.uri.queryParameters['event'],
          body,
          _Identity(state.extra),
        ),
      );
    },
    redirect: loggedOutRedirect,
    routes: [
      GoRoute(
        path: 'encryption',
        pageBuilder: (context, state) =>
            defaultPageBuilder(context, state, const ChatEncryptionSettings()),
        redirect: loggedOutRedirect,
      ),
      GoRoute(
        path: 'invite',
        pageBuilder: (context, state) => defaultPageBuilder(
          context,
          state,
          InvitationSelection(roomId: state.pathParameters['roomid']!),
        ),
        redirect: loggedOutRedirect,
      ),
      GoRoute(
        path: 'details',
        pageBuilder: (context, state) => defaultPageBuilder(
          context,
          state,
          ChatDetails(roomId: state.pathParameters['roomid']!),
        ),
        routes: [
          GoRoute(
            path: 'access',
            pageBuilder: (context, state) => defaultPageBuilder(
              context,
              state,
              ChatAccessSettings(roomId: state.pathParameters['roomid']!),
            ),
            redirect: loggedOutRedirect,
          ),
          GoRoute(
            path: 'members',
            pageBuilder: (context, state) => defaultPageBuilder(
              context,
              state,
              ChatMembersPage(roomId: state.pathParameters['roomid']!),
            ),
            redirect: loggedOutRedirect,
          ),
          GoRoute(
            path: 'permissions',
            pageBuilder: (context, state) => defaultPageBuilder(
              context,
              state,
              const ChatPermissionsSettings(),
            ),
            redirect: loggedOutRedirect,
          ),
        ],
        redirect: loggedOutRedirect,
      ),
    ],
  );

  /// A page that never animates (the outer shell). Kept for callers and
  /// tests; it is the same [_AppPage] type as every other route.
  static Page noTransitionPageBuilder(
    BuildContext context,
    GoRouterState state,
    Widget child,
  ) => _page(context, state, child, animated: false, memoise: false);

  /// The page of every route: Notion motion on phones, instant in two-column
  /// mode and with reduced motion. [memo] replaces the default signature
  /// (path and query parameters, fragment, extra) used to reuse the identical
  /// child widget while other routes change; see [_PageMemo].
  static Page defaultPageBuilder(
    BuildContext context,
    GoRouterState state,
    Widget child, {
    Object? memo,
  }) {
    final clientName = state.uri.queryParameters['client'];
    if (clientName != null) {
      final matrix = Matrix.of(context);
      final client = matrix.getClientByName(clientName);
      if (client != null) matrix.setActiveClient(client);
    }
    return _page(context, state, child, memo: memo);
  }

  static Page _page(
    BuildContext context,
    GoRouterState state,
    Widget child, {
    bool animated = true,
    bool memoise = true,
    Object? memo,
  }) => _AppPage(
    key: state.pageKey,
    restorationId: state.pageKey.value,
    animated: animated,
    child: memoise ? _PageMemo.resolve(context, state, child, memo) : child,
  );
}

/// The only page type of the router. Its type never depends on MediaQuery,
/// so resizing across the two-column breakpoint keeps every route and its
/// state; only the transition durations follow the layout.
class _AppPage<T> extends Page<T> {
  const _AppPage({
    required this.child,
    this.animated = true,
    super.key,
    super.restorationId,
  });

  final Widget child;

  /// False for the outer shell, which must never animate.
  final bool animated;

  @override
  Route<T> createRoute(BuildContext context) => _AppPageRoute<T>(this);
}

class _AppPageRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  _AppPageRoute(_AppPage<T> page) : super(settings: page) {
    assert(opaque);
  }

  _AppPage<T> get _page => settings as _AppPage<T>;

  /// Two-column mode swaps panes in place and reduced motion removes the
  /// movement; both make the route instant. The theme builder treats a zero
  /// duration as instant without changing the widget structure.
  bool get _instant {
    if (!_page.animated) return true;
    final navigator = this.navigator;
    if (navigator == null) return true;
    final context = navigator.context;
    return ChatLoomThemes.isColumnMode(context) ||
        NotionMotion.reduced(context);
  }

  @override
  Duration get transitionDuration =>
      _instant ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _instant ? Duration.zero : super.reverseTransitionDuration;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => true;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.restorationId})';
}

/// Compares [value] by identity inside a memo signature.
@immutable
class _Identity {
  const _Identity(this.value);
  final Object? value;
  @override
  bool operator ==(Object other) =>
      other is _Identity && identical(other.value, value);
  @override
  int get hashCode => identityHashCode(value);
}

/// go_router calls every page builder of the stack on each navigation. A
/// fresh child widget makes Flutter rebuild hidden pages (the inbox under a
/// chat, the chat under its details). This returns the identical child for
/// a page key while its signature is unchanged, so hidden pages skip the
/// rebuild; their own listeners still update them.
final class _PageMemo {
  static final _byRouter = Expando<_PageMemo>('page child memo');
  static const _capacity = 32;
  final _entries = <ValueKey<String>, (_PageSignature, Widget)>{};

  static Widget resolve(
    BuildContext context,
    GoRouterState state,
    Widget child,
    Object? memo,
  ) {
    final router = GoRouter.maybeOf(context);
    if (router == null) return child;
    final store = _byRouter[router] ??= _PageMemo();
    final uri = state.uri;
    final signature = _PageSignature(
      location: state.matchedLocation,
      parameters:
          memo ??
          (
            state.pathParameters,
            uri.queryParameters,
            uri.fragment,
            _Identity(state.extra),
          ),
      columns: ChatLoomThemes.isColumnMode(context),
      client: _Identity(_activeClient(context)),
      type: child.runtimeType,
    );
    final key = state.pageKey;
    final hit = store._entries.remove(key);
    if (hit != null && hit.$1 == signature) {
      store._entries[key] = hit;
      return hit.$2;
    }
    store._entries[key] = (signature, child);
    while (store._entries.length > _capacity) {
      store._entries.remove(store._entries.keys.first);
    }
    return child;
  }

  static Object? _activeClient(BuildContext context) {
    try {
      return Matrix.of(context).client;
    } catch (_) {
      return null;
    }
  }
}

@immutable
class _PageSignature {
  const _PageSignature({
    required this.location,
    required this.parameters,
    required this.columns,
    required this.client,
    required this.type,
  });

  final String location;
  final Object? parameters;
  final bool columns;
  final _Identity client;
  final Type type;

  @override
  bool operator ==(Object other) =>
      other is _PageSignature &&
      other.location == location &&
      other.columns == columns &&
      other.client == client &&
      other.type == type &&
      _deepEquals(other.parameters, parameters);

  static bool _deepEquals(Object? a, Object? b) {
    if (a is Map && b is Map) return mapEquals(a, b);
    if (a is (Map, Map, String, _Identity) &&
        b is (Map, Map, String, _Identity)) {
      return mapEquals(a.$1, b.$1) &&
          mapEquals(a.$2, b.$2) &&
          a.$3 == b.$3 &&
          a.$4 == b.$4;
    }
    return a == b;
  }

  @override
  int get hashCode => Object.hash(location, columns, client, type);
}
