// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/composer_keyboard.dart';
import 'package:chatloom/pages/chat/send_file_dialog.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/merged_attachments.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_chat_details_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

class _DraftPersonal extends ConversationPersonal {
  _DraftPersonal(super.client);
  bool failSave = false;
  int completed = 0;
  Completer<void>? nextSave;
  @override
  Future<void> savePersonalDraft(
    String key,
    SendTarget target,
    String text,
  ) async {
    final gate = nextSave;
    nextSave = null;
    if (gate != null) await gate.future;
    if (failSave) throw StateError('Fictional storage failure');
    await super.savePersonalDraft(key, target, text);
  }

  @override
  Future<void> completeImmediate(String actionId) async {
    completed++;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  test(
    'external picker lifecycle preserves lock epoch; manual lock invalidates it',
    () {
      PersonalPrivacy.surfaceUnlocked = true;
      PersonalPrivacy.surfaceForeground = true;
      final lockEpoch = PersonalPrivacy.surfaceLockGeneration;
      final renderEpoch = PersonalPrivacy.surfaceGeneration;
      PersonalPrivacy.surfaceForeground = false;
      PersonalPrivacy.surfaceForeground = true;
      expect(PersonalPrivacy.surfaceLockGeneration, lockEpoch);
      expect(PersonalPrivacy.surfaceGeneration, greaterThan(renderEpoch));
      PersonalPrivacy.surfaceUnlocked = false;
      PersonalPrivacy.surfaceUnlocked = true;
      expect(PersonalPrivacy.surfaceLockGeneration, greaterThan(lockEpoch));
    },
  );
  for (final failSave in [false, true]) {
    testWidgets(
      'merged accepted send preserves draft during storage ${failSave ? 'failure' : 'delay'}',
      (tester) async {
        final client = ConversationClient();
        final room = ConversationRoom(client, '!merged-draft:example.invalid');
        final personal = _DraftPersonal(client)..failSave = failSave;
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
              home: MergedChatPage(
                personal: personal,
                group: PersonGroup(
                  id: 'draft-person',
                  name: 'Fictional person',
                  members: [
                    personal.ref(room),
                    personal.ref(
                      ConversationRoom(
                        client,
                        '!other-source:example.invalid',
                        network: 'telegram',
                      ),
                    ),
                  ],
                  defaultRoomId: room.id,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final editor = find.byType(TextField).last;
        await tester.enterText(editor, 'Original message');
        await tester.pump();
        final gate = failSave ? null : Completer<void>();
        personal.nextSave = gate;
        await tester.tap(find.byTooltip('Send message'));
        await tester.pump();
        if (gate != null) {
          await tester.enterText(editor, 'The next draft');
          gate.complete();
        }
        await tester.pumpAndSettle();
        expect(personal.sends.length, 1);
        // The outbox has the message: the composer is empty either way
        // (Telegram). A failed draft clear keeps the attempt, not the text.
        expect(
          tester.widget<TextField>(editor).controller!.text,
          failSave ? isEmpty : 'The next draft',
        );
        expect(personal.completed, failSave ? 0 : 1);
        // CS-12: a failed draft clear is logged only; the message itself
        // is safe in the outbox, so no notice interrupts the user.
        if (failSave)
          expect(find.byType(SnackBar), findsNothing);
        else
          expect(personal.drafts.last.text, 'The next draft');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  test('Enter respects composition, Shift, preferences and held keys', () {
    var sends = 0;
    KeyEventResult handle(
      KeyEvent event, {
      bool ime = false,
      bool shift = false,
      bool preference = true,
    }) => conversationComposerKeyResult(
      event,
      value: TextEditingValue(
        text: 'draft',
        composing: ime ? const TextRange(start: 0, end: 5) : TextRange.empty,
      ),
      sendOnEnter: preference,
      shiftPressed: shift,
      onSend: () => sends++,
    );
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: Duration.zero,
    );
    expect(handle(down, ime: true), KeyEventResult.ignored);
    expect(handle(down, shift: true), KeyEventResult.ignored);
    expect(handle(down, preference: false), KeyEventResult.ignored);
    expect(sends, 0);
    expect(handle(down), KeyEventResult.handled);
    expect(
      handle(
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.handled,
    );
    expect(
      handle(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.handled,
    );
    expect(sends, 1);
  });
  testWidgets('merged Enter sends once; Shift and IME preserve the draft', (
    tester,
  ) async {
    await AppSettings.sendOnEnter.setItem(true);
    final client = ConversationClient();
    final room = ConversationRoom(client, '!merged-keyboard:example.invalid');
    final personal = ConversationPersonal(client);
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
          home: MergedChatPage(
            personal: personal,
            group: PersonGroup(
              id: 'keyboard-person',
              name: 'Fictional person',
              members: [
                personal.ref(room),
                personal.ref(
                  ConversationRoom(
                    client,
                    '!other-source:example.invalid',
                    network: 'telegram',
                  ),
                ),
              ],
              defaultRoomId: room.id,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = find.byType(TextField).last;
    await tester.enterText(editor, 'First message');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(personal.sends.map((s) => s.text), ['First message']);
    await tester.enterText(editor, 'Keep this draft');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(personal.sends.length, 1);
    final field = tester.widget<TextField>(editor);
    field.controller!.value = const TextEditingValue(
      text: 'candidate',
      selection: TextSelection.collapsed(offset: 9),
      composing: TextRange(start: 0, end: 9),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(personal.sends.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'merged attachments use the normal send dialog with the source check',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!merged-preview:example.invalid');
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                page = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var checks = 0;
      final result = showDialog<AttachmentSendResult>(
        context: page,
        builder: (_) => SendFileDialog(
          room: room,
          outerContext: page,
          threadLastEventId: null,
          threadRootEventId: null,
          initialCaption: 'Fictional caption',
          files: [
            XFile.fromData(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
              ),
              name: 'photo.png',
              path: 'photo.png',
              mimeType: 'image/png',
            ),
          ],
          preflight: (context, files, caption) async {
            checks++;
            expect(files.single.name, 'photo.png');
            expect(caption, 'Fictional caption');
            throw const PersonalCapabilityUnavailable(
              'This network does not accept images.',
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      // The same caption field and compression switch as any chat.
      expect(find.text('Fictional caption'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.text(L10n.of(page).send));
      await tester.pumpAndSettle();
      expect(checks, 1);
      // The bridge's reason, inline; the selection and caption stay.
      expect(find.text('This network does not accept images.'), findsOneWidget);
      expect(find.text('Fictional caption'), findsOneWidget);
      await tester.tap(find.text(L10n.of(page).cancel));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(personal.sends, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('merged preflight asks before an unverified feature', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!merged-check:example.invalid');
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              page = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final file = XFile.fromData(
      utf8.encode('fictional'),
      name: 'notes.txt',
      path: 'notes.txt',
    );
    Future<MergedAttachmentMeasure> measure(XFile _) async => (
      feature: BridgeFeature.upload,
      media: const BridgeMediaRequest(mimeType: 'text/plain', sizeBytes: 9),
    );
    final status = RoomCapabilities.forFeature(
      BridgeFeature.upload,
      room,
      media: const BridgeMediaRequest(mimeType: 'text/plain', sizeBytes: 9),
    ).status;
    final check = mergedAttachmentPreflight(
      page,
      room: room,
      replyTo: null,
      files: [file],
      caption: '',
      measure: measure,
    );
    await tester.pumpAndSettle();
    switch (status) {
      case CapabilityStatus.unavailable:
        await expectLater(check, throwsA(isA<PersonalCapabilityUnavailable>()));
      case CapabilityStatus.unverified:
        expect(find.text('Not verified for this network'), findsOneWidget);
        await tester.tap(find.text('Back'));
        await tester.pumpAndSettle();
        expect(await check, isFalse);
      default:
        expect(await check, isTrue);
    }
  });
  testWidgets(
    'details show one destination for shared content and one notification action',
    (tester) async {
      var media = 0, notifications = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NotionChatDetailsPage(
            data: const NotionConversationDetailsData(
              incognito: true,
              name: 'Fictional contact',
              network: 'Matrix',
              avatar: Icon(Icons.person_outline),
            ),
            actions: NotionConversationDetailsActions(
              media: () => media++,
              notifications: () => notifications++,
              mute: () => notifications++,
              search: () {},
            ),
          ),
        ),
      );
      expect(find.text('Shared content'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Search messages'), findsOneWidget);
      await tester.tap(find.text('Media, files & links'));
      expect(media, 1);
      await tester.ensureVisible(find.text('Notifications'));
      await tester.tap(find.text('Notifications'));
      expect(notifications, 1);
    },
  );
}
