// SPDX-License-Identifier: AGPL-3.0-or-later
// Real composers, fictional offline rooms. No messages or system clipboard IO.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/composer_keyboard.dart';
import 'package:chatloom/pages/chat/input_bar.dart';
import 'package:chatloom/pages/chat/send_file_dialog.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String clipboard;
  late int reads;
  late bool restoreAfterRead;
  Completer<void>? readGate;

  Future<String> readText() async {
    reads++;
    final text = clipboard;
    if (restoreAfterRead) clipboard = 'previous clipboard';
    final gate = readGate;
    if (gate != null) await gate.future;
    return text;
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() {
    clipboard = 'zażółć 🗣️';
    reads = 0;
    restoreAfterRead = false;
    readGate = null;
    PersonalPrivacy.surfaceUnlocked = true;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': await readText()};
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('pasteboard'),
      (call) async => call.method == 'files' ? <String>[] : null,
    );
    messenger.setMockMethodCallHandler(MacDesktopWindow.channel, (call) async {
      if (call.method == 'readPasteboard') {
        return {'prefersMedia': false, 'text': await readText()};
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), null);
    messenger.setMockMethodCallHandler(MacDesktopWindow.channel, null);
    PersonalPrivacy.surfaceUnlocked = true;
  });

  test(
    'native snapshot retains dictation when the clipboard is restored',
    () async {
      final snapshot = await MacDesktopWindow.readPasteboard();
      clipboard = 'previous clipboard';
      expect(snapshot, (prefersMedia: false, text: 'zażółć 🗣️'));
      expect(reads, 1);
    },
  );

  test('a missing native snapshot falls back without throwing', () async {
    messenger.setMockMethodCallHandler(MacDesktopWindow.channel, null);
    expect(await MacDesktopWindow.readPasteboard(), isNull);
    expect((await readComposerClipboard()).text, clipboard);
  });

  test('files keep priority over image and text representations', () async {
    messenger.setMockMethodCallHandler(
      MacDesktopWindow.channel,
      (_) async => {'prefersMedia': true, 'text': null},
    );
    messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (
      call,
    ) async {
      expect(call.method, 'files');
      return ['/fictional/example.txt'];
    });
    final paste = await readComposerClipboard();
    expect(paste.media!.single.path, '/fictional/example.txt');
    expect(paste.text, isNull);
    expect(reads, 0);
  });

  test('an image-only paste stays an attachment', () async {
    messenger.setMockMethodCallHandler(
      MacDesktopWindow.channel,
      (_) async => {'prefersMedia': true, 'text': null},
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('pasteboard'),
      (call) async =>
          call.method == 'files' ? <String>[] : Uint8List.fromList([1, 2, 3]),
    );
    final paste = await readComposerClipboard();
    expect(await paste.media!.single.readAsBytes(), [1, 2, 3]);
    expect(paste.text, isNull);
    expect(reads, 0);
  });

  for (final merged in [false, true]) {
    group(merged ? 'merged composer' : 'ordinary composer', () {
      late ConversationPersonal personal;

      Future<TextField> mount(WidgetTester tester) async {
        final client = ConversationClient();
        final a = ConversationRoom(client, '!paste-a:example.invalid');
        final b = ConversationRoom(
          client,
          '!paste-b:example.invalid',
          network: 'telegram',
        );
        a.message(r'$hello', 'Fictional message');
        personal = ConversationPersonal(client);
        PersonalClient.debugUse(client, personal);
        addTearDown(personal.dispose);
        final matrix = ConversationMatrix(
          client,
          await SharedPreferences.getInstance(),
        );
        await tester.pumpWidget(
          Provider<MatrixState>.value(
            value: matrix,
            child: MaterialApp(
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              home: merged
                  ? MergedChatPage(
                      personal: personal,
                      group: PersonGroup(
                        id: 'paste-person',
                        name: 'Fictional person',
                        members: [personal.ref(a), personal.ref(b)],
                        defaultRoomId: a.id,
                      ),
                    )
                  : ChatPageWithRoom(room: a),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final finder = find.descendant(
          of: find.byType(InputBar),
          matching: find.byType(TextField),
        );
        await tester.tap(finder);
        await tester.pump();
        return tester.widget<TextField>(finder);
      }

      Future<void> paste(WidgetTester tester) async {
        final editor = find.descendant(
          of: find.byType(InputBar),
          matching: find.byType(EditableText),
        );
        Actions.invoke(
          tester.element(editor),
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
        await tester.pump();
      }

      Future<void> unmount(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }

      testWidgets('dictation replaces the selection and keeps focus', (
        tester,
      ) async {
        final field = await mount(tester);
        field.controller!.value = const TextEditingValue(
          text: 'Hello world!',
          selection: TextSelection(baseOffset: 6, extentOffset: 11),
        );
        await paste(tester);
        expect(field.controller!.text, 'Hello zażółć 🗣️!');
        expect(field.focusNode!.hasFocus, isTrue);
        expect(field.controller!.selection.baseOffset, 6 + clipboard.length);
        expect(find.byType(SendFileDialog), findsNothing);
        expect(personal.sends, isEmpty);
        expect(reads, 1);
        await unmount(tester);
      });

      testWidgets('an active composition does not discard pasted text', (
        tester,
      ) async {
        final field = await mount(tester);
        field.controller!.value = const TextEditingValue(
          text: 'abc',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        );
        await paste(tester);
        expect(field.controller!.text, 'abc$clipboard');
        expect(field.focusNode!.hasFocus, isTrue);
        await unmount(tester);
      });

      testWidgets('a temporary dictation clipboard is read only once', (
        tester,
      ) async {
        final field = await mount(tester);
        restoreAfterRead = true;
        final dictated = clipboard;
        await paste(tester);
        expect(clipboard, 'previous clipboard');
        expect(field.controller!.text, dictated);
        expect(reads, 1);
        await unmount(tester);
      });

      if (!merged) {
        testWidgets('text can be pasted while editing a sent message', (
          tester,
        ) async {
          final field = await mount(tester);
          final controller = tester.state<ChatController>(
            find.byType(ChatPageWithRoom),
          );
          final original = (controller.room as ConversationRoom).message(
            r'$own',
            'Original message',
            outgoing: true,
          );
          controller.editEventAction(original);
          field.controller!.selection = TextSelection.collapsed(
            offset: field.controller!.text.length,
          );
          await tester.pump();
          await paste(tester);
          expect(controller.editEvent, same(original));
          expect(field.controller!.text, 'Original message$clipboard');
          expect(personal.sends, isEmpty);
          await unmount(tester);
        });
      }

      testWidgets('typing during a delayed paste keeps the new draft', (
        tester,
      ) async {
        final field = await mount(tester);
        final gate = readGate = Completer<void>();
        await paste(tester);
        field.controller!.text = 'New draft';
        gate.complete();
        await tester.pump();
        expect(field.controller!.text, 'New draft');
        await unmount(tester);
      });

      testWidgets('lock and unlock invalidate an outstanding paste', (
        tester,
      ) async {
        final field = await mount(tester);
        final gate = readGate = Completer<void>();
        await paste(tester);
        PersonalPrivacy.surfaceUnlocked = false;
        PersonalPrivacy.surfaceUnlocked = true;
        gate.complete();
        await tester.pump();
        expect(field.controller!.text, isEmpty);
        await unmount(tester);
      });
    });
  }
}
