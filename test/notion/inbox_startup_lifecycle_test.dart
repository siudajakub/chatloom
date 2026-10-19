// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

class _Statuses extends CachedStreamController<SyncStatusUpdate> {
  final events = StreamController<SyncStatusUpdate>.broadcast();
  @override
  Stream<SyncStatusUpdate> get stream => events.stream;
  @override
  void add(SyncStatusUpdate value) => events.add(value);
  @override
  Future<void> close() => events.close();
}

class _Client extends ConversationClient {
  _Client(super.owner);
  @override
  final _Statuses onSyncStatus = _Statuses();
}

class _Inbox extends ChatList {
  const _Inbox({super.key}) : super(activeChat: null);
  @override
  ChatListController createState() => _Controller();
}

class _Controller extends ChatListController {
  final shortcuts = <String>[];
  @override
  // Exercise the actual wait and shortcut controller methods without native
  // startup, account storage, transport, or private data.
  // ignore: must_call_super
  void initState() {
    activeFilter = ActiveFilter.allChats;
  }

  Future<void> readiness() => waitForInitialSync();
  Future<void> bindShortcuts() => bindLauncherShortcuts();
  @override
  void onLauncherShortcut(String action) => shortcuts.add(action);
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<void> _launchShortcut(WidgetTester tester, String action) async {
  final response = tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'im.fluffychat.flutter_shortcuts_new',
    const StandardMethodCodec().encodeMethodCall(MethodCall('launch', action)),
    null,
  );
  await tester.pump();
  await response;
}

Future<void> _flushSdkStreamCleanup(WidgetTester tester) async {
  await tester.pump();
  // Dart's StreamIterator.cancel() can return the SDK's cached root-zone
  // null future. Its continuation needs a real microtask turn, followed by a
  // fake-zone flush for the controller's remaining readiness continuation.
  await tester.runAsync(() => Future<void>.value());
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('offline initial-sync waits cancel on rebind and view teardown', (
    tester,
  ) async {
    final a = _Client('@fixture-a:example.invalid');
    final b = _Client('@fixture-b:example.invalid');
    addTearDown(a.onSyncStatus.close);
    addTearDown(b.onSyncStatus.close);
    final matrix = ConversationMatrix(a, await SharedPreferences.getInstance());
    final key = GlobalKey<ChatListController>();
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: matrix,
        child: MaterialApp(home: _Inbox(key: key)),
      ),
    );
    final controller = key.currentState! as _Controller;
    final aReadiness = controller.readiness();
    await tester.pump();
    expect(a.onSyncStatus.events.hasListener, isTrue);
    matrix.active = b;
    final bReadiness = controller.readiness();
    await _flushSdkStreamCleanup(tester);
    // StreamIterator's cancellation has its own asynchronous completion.
    // Observe the actual operation rather than one frame's microtask budget.
    await aReadiness;
    expect(a.onSyncStatus.events.hasListener, isFalse);
    expect(b.onSyncStatus.events.hasListener, isTrue);
    expect(controller.waitForFirstSync, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await _flushSdkStreamCleanup(tester);
    await bReadiness;
    expect(b.onSyncStatus.events.hasListener, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'superseded shared loading cannot resume an older readiness pass',
    (tester) async {
      final client = _Client('@fixture:example.invalid');
      addTearDown(client.onSyncStatus.close);
      final loading = Completer<void>();
      client.roomsLoading = loading.future;
      final matrix = ConversationMatrix(
        client,
        await SharedPreferences.getInstance(),
      );
      final key = GlobalKey<ChatListController>();
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp(home: _Inbox(key: key)),
        ),
      );
      final controller = key.currentState! as _Controller;
      var latestCompleted = false;
      final supersededReadiness = controller.readiness();
      await tester.pump();
      final latestReadiness = controller.readiness().then(
        (_) => latestCompleted = true,
      );
      await tester.pump();
      await supersededReadiness;
      expect(latestCompleted, isFalse);
      expect(client.onSyncStatus.events.hasListener, isFalse);
      loading.complete();
      await tester.pump();
      expect(client.onSyncStatus.events.hasListener, isTrue);
      client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
      await _flushSdkStreamCleanup(tester);
      await latestReadiness;
      expect(latestCompleted, isTrue);
      expect(controller.waitForFirstSync, isTrue);
      expect(client.onSyncStatus.events.hasListener, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'shortcut dispatcher releases old owners without clearing a new one',
    (tester) async {
      const channel = MethodChannel('im.fluffychat.flutter_shortcuts_new');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        channel.setMethodCallHandler(null);
      });
      final firstKey = GlobalKey<ChatListController>();
      final secondKey = GlobalKey<ChatListController>();
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              _Inbox(key: firstKey),
              _Inbox(key: secondKey),
            ],
          ),
        ),
      );
      final first = firstKey.currentState! as _Controller;
      final second = secondKey.currentState! as _Controller;
      unawaited(first.bindShortcuts());
      await tester.pump();
      await _launchShortcut(tester, 'fixture-first');
      expect(first.shortcuts, ['fixture-first']);
      unawaited(second.bindShortcuts());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Row(children: [_Inbox(key: secondKey)]),
        ),
      );
      await _launchShortcut(tester, 'fixture-second');
      expect(first.shortcuts, ['fixture-first']);
      expect(second.shortcuts, ['fixture-second']);
      await tester.pumpWidget(const SizedBox.shrink());
      await _launchShortcut(tester, 'fixture-after-dispose');
      expect(second.shortcuts, ['fixture-second']);
      expect(tester.takeException(), isNull);
    },
  );
}
