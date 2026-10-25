// SPDX-License-Identifier: AGPL-3.0-or-later
// Production presenters, fictional source data and synthetic thumbnail bytes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/personal/ui/notion_chat_details_adapter.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/personal/ui/notion_chat_details_page.dart';
import 'package:chatloom/ui/notion/notion.dart' show NotionGlassMenuRow;
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

class GalleryDatabase implements DatabaseApi {
  final failRooms = <String>{};
  Completer<void>? gate;
  @override
  int get maxFileSize => 1000000;
  final rows = <String, List<Event>>{};
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    int? limit,
    bool onlySending = false,
  }) async {
    if (failRooms.contains(room.id)) throw StateError('synthetic offline');
    return (rows[room.id] ?? []).skip(start).take(limit ?? 80).toList();
  }

  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    int? limit,
    bool includeSending = false,
  }) async {
    if (gate != null) await gate!.future;
    if (failRooms.contains(room.id)) throw StateError('synthetic offline');
    return (rows[room.id] ?? [])
        .map((e) => e.eventId)
        .skip(start)
        .take(limit ?? 10000)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database I/O');
}

class GalleryClient extends Client {
  final List<(String, String)> requests;
  GalleryClient(GalleryDatabase db) : this._(db, []);
  GalleryClient._(GalleryDatabase db, this.requests)
    : super(
        'gallery fixture',
        database: db,
        httpClient: MockClient((request) async {
          requests.add((request.method, request.url.path));
          return http.Response('{}', 503);
        }),
      );
  @override
  String get userID => '@owner:example.invalid';
  @override
  Map<String, List<String>> get directChats => {
    '@anna:example.invalid': rooms.map((r) => r.id).toList(),
  };
}

class ThumbnailEvent extends Event {
  final Uint8List pixels;
  int fullDownloads = 0;
  ThumbnailEvent(Room room, int i, this.pixels)
    : super(
        room: room,
        eventId: '\$photo-$i',
        type: EventTypes.Message,
        senderId: '@anna:example.invalid',
        originServerTs: DateTime.utc(2026, 10, 16, 14, i),
        content: {
          'msgtype': i % 4 == 0 ? MessageTypes.Video : MessageTypes.Image,
          'body': 'Fictional shared media $i',
          'info': {
            'thumbnail_url': 'mxc://example.invalid/thumb-$i',
            'thumbnail_info': {'size': 1024, 'w': 100, 'h': 100},
            'duration': 12000,
          },
        },
      );
  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    if (!getThumbnail) {
      fullDownloads++;
      throw StateError('Full file forbidden in gallery');
    }
    return MatrixImageFile(
      bytes: pixels,
      name: 'fixture.png',
      mimeType: 'image/png',
      width: 100,
      height: 100,
    );
  }
}

void main() {
  final output = Platform.environment['PROFILE_CAPTURE_DIR'];
  final manifest = <Map<String, Object?>>[];
  late Uint8List pixels;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.showThumbnailsInTimeline.setItem(true);
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Medium.ttf'))
          ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0xff55675c), BlendMode.src);
    canvas.drawRect(
      const Rect.fromLTWH(0, 60, 100, 40),
      Paint()..color = const Color(0xff303f3a),
    );
    canvas.drawCircle(
      const Offset(72, 28),
      14,
      Paint()..color = const Color(0xffd9c498),
    );
    final picture = recorder.endRecording();
    final img = await picture.toImage(100, 100);
    pixels = (await img.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    img.dispose();
    picture.dispose();
  });
  for (final width in [320.0, 390.0, 430.0, 900.0, 1200.0]) {
    for (final state in [
      'profile',
      'media',
      'files',
      'messages',
      'links',
      'menu',
      'empty',
      'partial',
      'sources',
      'loading',
    ]) {
      if (![
            'profile',
            'media',
            'files',
            'messages',
            'links',
            'menu',
          ].contains(state) &&
          width != 390)
        continue;
      final only = Platform.environment['PROFILE_CAPTURE_ONLY'];
      if (only != null && !only.split(',').contains('$state-${width.toInt()}'))
        continue;
      testWidgets('actual $state at $width', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final db = GalleryDatabase();
        final client = GalleryClient(db);
        final room = ConversationRoom(client, '!gallery:example.invalid');
        final personal = ConversationPersonal(client);
        final photos = [
          for (var i = 0; i < 12; i++) ThumbnailEvent(room, i, pixels),
        ];
        db.rows[room.id] = [
          ...photos,
          room.message(
            r'$file',
            'Annual_notes_and_long_filename_for_review.pdf',
            content: {
              'msgtype': MessageTypes.File,
              'body': 'Annual_notes_and_long_filename_for_review.pdf',
              'info': {'size': 983040},
            },
          ),
          room.message(
            r'$voice',
            'Voice message',
            content: {
              'msgtype': MessageTypes.Audio,
              'body': 'Voice message',
              'info': {'duration': 18000, 'size': 28104},
            },
          ),
          room.message(
            r'$note',
            'Voice message',
            outgoing: true,
            content: {
              'msgtype': MessageTypes.Audio,
              'body': 'Voice message',
              'org.matrix.msc3245.voice': <String, dynamic>{},
              'info': {'duration': 7000},
            },
          ),
          room.message(
            r'$round',
            'Video message',
            content: {
              'msgtype': MessageTypes.Video,
              'body': 'Video message',
              'info': {
                'fi.mau.telegram.round_message': true,
                'duration': 21000,
              },
            },
          ),
          room.message(
            r'$links',
            'Reading list https://example.org/notes https://example.org/long/path?reference=fictional https://example.net/guide',
          ),
        ];
        final rooms = <Room>[room];
        if (state == 'empty') db.rows[room.id] = [];
        if (state == 'partial') {
          final bad = ConversationRoom(client, '!offline:example.invalid');
          rooms.add(bad);
          db.failRooms.add(bad.id);
        }
        if (state == 'loading') db.gate = Completer<void>();
        final editor = TextEditingController();
        final boundary = GlobalKey();
        final preferences = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          Provider<MatrixState>.value(
            value: ConversationMatrix(client, preferences),
            child: RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: NotionTheme.build(
                  width >= 900 ? Brightness.light : Brightness.dark,
                ),
                localizationsDelegates: L10n.localizationsDelegates,
                supportedLocales: L10n.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width == 320 ? 2 : 1),
                  ),
                  child: child!,
                ),
                home: (state == 'profile' || state == 'sources')
                    ? NotionLiveChatDetails(personal: personal, room: room)
                    : state == 'menu'
                    ? Scaffold(
                        appBar: AppBar(
                          title: const Text('Fictional conversation'),
                          actions: [
                            RoomPersonalButton(
                              room: room,
                              composer: editor,
                              readCutoff: () => null,
                              includeChatSettings: true,
                            ),
                          ],
                        ),
                      )
                    : NotionConversationContentPage(
                        rooms: rooms,
                        name: 'Fictional conversation',
                        initialMedia: true,
                      ),
              ),
            ),
          ),
        );
        if (state == 'loading') {
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 16));
          expect(find.text('Shared content'), findsOneWidget);
        } else {
          await tester.pumpAndSettle();
        }
        if (state == 'sources') {
          // A row every chat has (the capabilities row is bridged-only).
          await tester.scrollUntilVisible(
            find.text('Participants'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(find.text('Participants'));
          await tester.pumpAndSettle();
        }
        if (state == 'partial') {
          await tester.scrollUntilVisible(
            find.textContaining('Local history could not load'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
        }
        if (state == 'files') {
          // Large text scrolls the tab bar.
          await tester.ensureVisible(find.text('Files'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Files'));
          await tester.pumpAndSettle();
        }
        if (state == 'messages') {
          // Large text scrolls the tab bar.
          await tester.ensureVisible(find.text('Messages'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Messages'));
          await tester.pumpAndSettle();
          expect(find.text('Voice message'), findsOneWidget);
          expect(find.text('Video message'), findsOneWidget);
        }
        if (state == 'links') {
          // Large text scrolls the tab bar.
          await tester.ensureVisible(find.text('Links'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Links'));
          await tester.pumpAndSettle();
        }
        if (state == 'menu') {
          await tester.tap(find.byTooltip('Conversation options'));
          await tester.pumpAndSettle();
          // Search, Send later, Remind me, Mark as read, (Mute… when
          // joined), Chat details: glass rows, no Material popup.
          expect(find.byType(NotionGlassMenuRow), findsAtLeastNWidgets(5));
          expect(find.byType(PopupMenuItem<String>), findsNothing);
        }
        if (state == 'profile') {
          expect(find.byType(NotionChatDetailsPage), findsOneWidget);
          expect(find.text('Label'), findsNothing);
        }
        if (state == 'media') {
          expect(find.byType(SliverGrid), findsOneWidget);
        }
        if (state == 'links') {
          expect(find.text('example.org'), findsNWidgets(2));
        }
        expect(tester.takeException(), isNull);
        expect(client.requests, isEmpty);
        expect(personal.sends, isEmpty);
        expect(room.reactionsSent, 0);
        expect(photos.fold<int>(0, (sum, e) => sum + e.fullDownloads), 0);
        if (output != null) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await Directory(output).create(recursive: true);
            final filename = '$state-${width.toInt()}.png';
            await File(
              '$output/$filename',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            manifest.add({
              'file': filename,
              'presenter': state == 'profile'
                  ? 'NotionLiveChatDetails'
                  : state == 'menu'
                  ? 'RoomPersonalButton'
                  : 'NotionConversationContentPage',
              'data': 'fictional; synthetic thumbnail bytes',
              'width': width,
              'textScale': width == 320 ? 2 : 1,
              'theme': width >= 900 ? 'light' : 'dark',
            });
          });
        }
        if (db.gate != null) {
          db.gate!.complete();
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        editor.dispose();
        personal.dispose();
      });
    }
  }
  testWidgets(
    'legacy labels are absent, remain stored and cannot hide the inbox',
    (tester) async {
      final db = GalleryDatabase();
      final client = GalleryClient(db);
      final room = ConversationRoom(client, '!legacy:example.invalid');
      final personal = ConversationPersonal(client);
      personal.values['label:old'] = {
        'name': 'Old hidden label',
        'showInInbox': false,
      };
      personal.values['labels:${room.id}'] = {
        'labels': ['label:old'],
      };
      personal.values['org:${room.id}'] = {
        'entityId': room.id,
        'labelIds': ['label:old'],
        'nickname': 'Private name',
      };
      expect(InboxProjection(personal).rooms([room]), contains(room));
      await tester.pumpWidget(
        MaterialApp(
          home: OrganizationPage(personal: personal, room: room),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Conversation labels'), findsNothing);
      expect(find.text('My labels'), findsNothing);
      expect(personal.values['label:old']?['showInInbox'], false);
      await tester.pumpWidget(const SizedBox.shrink());
      personal.dispose();
    },
  );
  tearDownAll(() async {
    if (output != null)
      await File(
        '$output/manifest.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
  });
}
