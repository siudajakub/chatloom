// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: synthetic files in a private temp folder; nothing is sent.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/open_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

final _plaintext = Uint8List.fromList(
  List<int>.generate(64, (i) => 200 + i % 50),
);

Event _fileEvent(Room room, {String name = 'Quarterly report.pdf'}) => Event(
  room: room,
  eventId: r'$open-file',
  type: EventTypes.Message,
  senderId: '@fixture:example.invalid',
  originServerTs: DateTime.utc(2026),
  content: {
    'msgtype': MessageTypes.File,
    'body': name,
    'filename': name,
    'info': {'mimetype': 'application/pdf', 'size': _plaintext.length},
    'url': 'mxc://example.invalid/file',
  },
);

Future<MatrixFile> _download(
  Event event, {
  required MediaDownloadToken token,
  void Function(int bytes)? onDownloadProgress,
}) async {
  onDownloadProgress?.call(_plaintext.length);
  return MatrixFile(bytes: _plaintext, name: 'x', mimeType: 'application/pdf');
}

List<File> _filesUnder(Directory directory) =>
    directory.listSync(recursive: true).whereType<File>().toList();

void main() {
  late Directory temp;
  late Room room;
  // Folder times are real, so the test clock starts at the real time.
  var now = DateTime.now();

  setUp(() async {
    now = DateTime.now();
    temp = await Directory.systemTemp.createTemp('open_file_');
    room = Room(
      id: '!fixture:example.invalid',
      client: Client('open file', database: _Database()),
    );
  });

  tearDown(() => temp.delete(recursive: true));

  Future<OpenedFileCopies> copies({int processId = 4242}) =>
      OpenedFileCopies.open(
        Directory('${temp.path}/${OpenedFileCopies.folderName}'),
        scheduleCleanup: false,
        now: () => now,
        processId: processId,
      );

  group('OpenedFileCopies', () {
    test('writes the named file into a new owner-only folder', () async {
      final store = await copies();
      final copy = await store.create(_plaintext, 'Quarterly report.pdf');
      expect(copy.file.path, startsWith('${store.root.path}/4242_'));
      expect(copy.file.uri.pathSegments.last, 'Quarterly report.pdf');
      expect((await copy.file.parent.stat()).mode & 0x1ff, 0x1c0);
      expect(copy.file.readAsBytesSync(), _plaintext);
      await copy.delete();
      expect(copy.file.parent.existsSync(), isFalse);
    });

    test('file names lose path parts and never become hidden', () {
      expect(OpenedFileCopies.safeFileName('../../etc/passwd'), 'passwd');
      expect(OpenedFileCopies.safeFileName('.profile'), 'file.profile');
      expect(OpenedFileCopies.safeFileName('a:b?.pdf'), 'a_b_.pdf');
      expect(OpenedFileCopies.safeFileName(''), 'file');
    });

    test('the next start removes copies of earlier processes', () async {
      final earlier = await copies(processId: 111);
      final left = await earlier.create(_plaintext, 'a.pdf');
      final current = await copies(processId: 222);
      final mine = await current.create(_plaintext, 'b.pdf');
      // create() already swept the earlier process's copy.
      expect(left.file.existsSync(), isFalse);
      expect(await current.sweep(), 0);
      expect(mine.file.existsSync(), isTrue);
    });

    test('a copy is removed once it is older than keepFor', () async {
      final store = await copies();
      final copy = await store.create(_plaintext, 'a.pdf');
      now = now.add(
        OpenedFileCopies.defaultKeepFor - const Duration(minutes: 1),
      );
      expect(await store.sweep(), 0);
      now = DateTime.now().add(OpenedFileCopies.defaultKeepFor);
      expect(await store.sweep(), 1);
      expect(copy.file.existsSync(), isFalse);
    });

    test('logout removes every copy, also this process\'s', () async {
      final store = await copies();
      await store.create(_plaintext, 'a.pdf');
      await store.create(_plaintext, 'b.pdf');
      expect(await store.sweep(all: true), 2);
      expect(_filesUnder(store.root), isEmpty);
    });

    test('a shared root is refused (fail closed)', () async {
      final shared = Directory('${temp.path}/shared')..createSync();
      await Process.run('chmod', ['0777', shared.path]);
      await expectLater(OpenedFileCopies.open(shared), throwsA(anything));
    });
  });

  group('openMimeType', () {
    test('event type, else from the name', () {
      expect(openMimeType('application/pdf', 'x'), 'application/pdf');
      expect(openMimeType('IMAGE/PNG; q=1', 'x'), 'image/png');
      expect(openMimeType('', 'x.pdf'), 'application/pdf');
      expect(openMimeType('application/octet-stream', 'a.txt'), 'text/plain');
      expect(openMimeType(null, 'x.unknownext'), 'application/octet-stream');
    });
  });

  group('openEventAttachment', () {
    late BuildContext context;

    Future<void> pumpHost(WidgetTester tester, Event event) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return Center(
                  child: FileOpenStatusIcon(
                    eventId: event.eventId,
                    idle: const Icon(Icons.insert_drive_file_outlined),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    Future<void> drainSnackBars(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    }

    testWidgets('downloads, re-checks the export gate and opens a private '
        'copy', (tester) async {
      final event = _fileEvent(room);
      await pumpHost(tester, event);
      var guards = 0;
      File? opened;
      String? mime;
      late OpenedFileCopies store;
      await tester.runAsync(() async {
        store = await copies();
        await openEventAttachment(
          context,
          event,
          guard: () async {
            guards++;
            return true;
          },
          save: () async => fail('no save'),
          opener: (file, mimeType) async {
            opened = file;
            mime = mimeType;
            expect(file.readAsBytesSync(), _plaintext);
            return true;
          },
          copies: () async => store,
          download: _download,
        );
      });
      expect(guards, 2, reason: 'before and after the download');
      expect(mime, 'application/pdf');
      expect(opened!.path, startsWith(store.root.path));
      expect(opened!.uri.pathSegments.last, 'Quarterly report.pdf');
      // The plaintext exists only inside the private open folder.
      for (final file in _filesUnder(temp)) {
        expect(file.path, startsWith(store.root.path));
      }
      expect(FileOpenDownloads.isActive(event.eventId), isFalse);
    });

    testWidgets('no app for the type: the copy goes and Save is '
        'offered', (tester) async {
      final event = _fileEvent(room);
      await pumpHost(tester, event);
      var saves = 0;
      late OpenedFileCopies store;
      await tester.runAsync(() async {
        store = await copies();
        await openEventAttachment(
          context,
          event,
          guard: () async => true,
          save: () async => saves++,
          opener: (file, mimeType) async => false,
          copies: () async => store,
          download: _download,
        );
      });
      expect(_filesUnder(temp), isEmpty);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('No app on this device can open this file.'), findsOne);
      await tester.tap(find.text('Save'));
      expect(saves, 1);
      await drainSnackBars(tester);
    });

    testWidgets('a protected message is neither downloaded nor '
        'opened', (tester) async {
      final event = _fileEvent(room);
      await pumpHost(tester, event);
      var downloads = 0;
      await tester.runAsync(() async {
        await openEventAttachment(
          context,
          event,
          guard: () async => false,
          save: () async => fail('no save'),
          opener: (file, mimeType) async => fail('no open'),
          copies: copies,
          download: (event, {required token, onDownloadProgress}) async {
            downloads++;
            return _download(event, token: token);
          },
        );
      });
      expect(downloads, 0);
      expect(_filesUnder(temp), isEmpty);
    });

    testWidgets('the bubble shows the ring; a second tap cancels', (
      tester,
    ) async {
      final event = _fileEvent(room);
      await pumpHost(tester, event);
      MediaDownloadToken? running;
      final started = Completer<void>();
      final first = openEventAttachment(
        context,
        event,
        guard: () async => true,
        save: () async => fail('no save'),
        opener: (file, mimeType) async => fail('no open'),
        copies: copies,
        download: (event, {required token, onDownloadProgress}) async {
          running = token;
          onDownloadProgress?.call(16);
          started.complete();
          await token.onAbort;
          throw const MediaDownloadCancelled();
        },
      );
      await tester.pump();
      await started.future;
      await tester.pump();
      expect(FileOpenDownloads.isActive(event.eventId), isTrue);
      expect(find.byKey(const ValueKey('file-open-progress')), findsOne);

      await openEventAttachment(
        context,
        event,
        guard: () async => fail('a cancel tap never checks'),
        save: () async => fail('no save'),
      );
      await first;
      await tester.pump();
      expect(running!.cancelled, isTrue);
      expect(FileOpenDownloads.isActive(event.eventId), isFalse);
      expect(find.byKey(const ValueKey('file-open-progress')), findsNothing);
      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOne);
    });

    testWidgets('without a system opener (Linux test host) the file is '
        'saved instead', (tester) async {
      final event = _fileEvent(room);
      await pumpHost(tester, event);
      var saves = 0;
      await tester.runAsync(
        () => openEventAttachment(
          context,
          event,
          guard: () async => fail('save checks itself'),
          save: () async => saves++,
        ),
      );
      expect(saves, 1);
    });
  });
}
