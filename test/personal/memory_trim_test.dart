// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline fixtures only: synthetic bytes, no network or account storage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatloom/personal/memory_trim.dart';
import 'package:chatloom/utils/bounded_byte_cache.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  _Database({required this.disk});
  final bool disk;

  @override
  bool get supportsFileStoring => disk;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4nGP4z8DwHwohFABFzAf5Zsv/OQAAAABJRU5ErkJggg==',
);

class _ImageEvent extends Event {
  _ImageEvent(Room room, String id, this.bytes)
    : super(
        room: room,
        eventId: id,
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {'msgtype': MessageTypes.Image},
      );
  final Uint8List bytes;
  int requests = 0;

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    requests++;
    return MatrixImageFile(bytes: bytes, name: 'fixture.png');
  }
}

Room _room(String name, {required bool disk}) => Room(
  id: '!$name:example.invalid',
  client: Client(name, database: _Database(disk: disk)),
);

Widget _images(List<Event> events) => MaterialApp(
  home: Column(
    children: [
      for (final event in events)
        MxcImage(
          key: ValueKey(event.eventId),
          event: event,
          cacheKey: event.eventId,
          cacheName: 'memory-trim-test',
          width: 40,
          height: 40,
          placeholder: (_) => const Text('placeholder'),
        ),
    ],
  ),
);

/// A pending decode in Flutter's image cache, as a scrolled-away row leaves.
Object _pendingDecode() {
  final key = Object();
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
  );
  return key;
}

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await tester.pump();
}

void main() {
  tearDown(() {
    MemoryTrim.debugReset();
    MxcImage.trimMemory();
    PaintingBinding.instance.imageCache.clear();
    MacDesktopWindow.visible.value = true;
    debugDefaultTargetPlatformOverride = null;
  });

  group('BoundedByteCache', () {
    test('trimTo drops least recently used evictable entries only', () {
      final cache = BoundedByteCache<String>(maxBytes: 100, maxEntries: 10)
        ..put('a', Uint8List(30))
        ..put('keep', Uint8List(30))
        ..put('b', Uint8List(30));
      cache.get('a'); // a is now the most recent
      cache.trimTo(40, evictable: (key) => key != 'keep');
      expect(cache.get('b'), isNull);
      expect(cache.get('a'), isNull);
      expect(cache.get('keep'), isNotNull);
      expect(cache.retainedBytes, 30);
      cache.clear();
      expect(cache.length, 0);
      expect(cache.retainedBytes, 0);
    });

    test('trimTo leaves a cache under the budget untouched', () {
      final cache = BoundedByteCache<int>(maxBytes: 100, maxEntries: 10)
        ..put(1, Uint8List(10))
        ..put(2, Uint8List(10));
      cache.trimTo(20);
      expect(cache.length, 2);
    });
  });

  test('Lottie sniff rejects images before any parse', () {
    expect(MxcImage.mayBeLottie(_pixel), isFalse);
    expect(MxcImage.mayBeLottie(Uint8List.fromList([0xff, 0xd8, 0xff])), false);
    expect(MxcImage.mayBeLottie(Uint8List.fromList(gzip.encode([1]))), true);
    expect(MxcImage.mayBeLottie(utf8.encode(' \n{"layers":[]}')), true);
    expect(MxcImage.mayBeLottie(Uint8List(0)), false);
  });

  testWidgets('pausing trims background caches and keeps the shown image', (
    tester,
  ) async {
    MemoryTrim.install();
    final disk = _room('trim-disk', disk: true);
    final memoryOnly = _room('trim-memory', disk: false);
    // Disk-backed sources beyond the background budget, plus one that only
    // the network could restore.
    final big = Uint8List(3 * 1024 * 1024);
    final shown = _ImageEvent(disk, r'$shown', _pixel);
    final old1 = _ImageEvent(disk, r'$old1', big);
    final old2 = _ImageEvent(disk, r'$old2', big);
    final network = _ImageEvent(memoryOnly, r'$network', big);
    await tester.pumpWidget(_images([old1, old2, network]));
    await tester.pump();
    await tester.pump();
    expect(MxcImage.debugRetainedEntries, 3);
    await tester.pumpWidget(_images([shown]));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    ImageProvider source() =>
        (tester.widget<Image>(find.byType(Image)).image as ResizeImage)
            .imageProvider;
    final before = source();
    final decode = _pendingDecode();

    await _lifecycle(tester, AppLifecycleState.inactive);
    await _lifecycle(tester, AppLifecycleState.hidden);
    await _lifecycle(tester, AppLifecycleState.paused);

    expect(MemoryTrim.debugTrims, 1);
    expect(MemoryTrim.debugTrimPending, isFalse);
    expect(PaintingBinding.instance.imageCache.containsKey(decode), isFalse);
    // The oldest disk-backed entries went until the budget was met; the
    // one only the network could restore stayed.
    expect(MxcImage.debugRetainedEntries, 2);
    expect(MxcImage.debugRetainedBytes, big.length + _pixel.length);

    await _lifecycle(tester, AppLifecycleState.hidden);
    await _lifecycle(tester, AppLifecycleState.inactive);
    await _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    // The image on screen is untouched: same bytes, no reload.
    expect(find.byType(Image), findsOneWidget);
    expect(source(), before);
    expect(shown.requests, 1);

    // A row scrolled back in reloads what was trimmed.
    await tester.pumpWidget(_images([shown, old1, network]));
    await tester.pump();
    await tester.pump();
    expect(old1.requests, 2);
    expect(network.requests, 1);

    // Another absence trims again.
    await _lifecycle(tester, AppLifecycleState.inactive);
    await _lifecycle(tester, AppLifecycleState.hidden);
    await _lifecycle(tester, AppLifecycleState.paused);
    expect(MemoryTrim.debugTrims, 2);
    await _lifecycle(tester, AppLifecycleState.hidden);
    await _lifecycle(tester, AppLifecycleState.inactive);
    await _lifecycle(tester, AppLifecycleState.resumed);
  });

  testWidgets('memory pressure empties the encoded cache', (tester) async {
    MemoryTrim.install();
    final event = _ImageEvent(
      _room('pressure', disk: false),
      r'$pressure',
      _pixel,
    );
    await tester.pumpWidget(_images([event]));
    await tester.pump();
    await tester.pump();
    expect(MxcImage.debugRetainedEntries, 1);
    final decode = _pendingDecode();
    var extra = 0;
    MemoryTrim.addCache(() => extra++);

    tester.binding.handleMemoryPressure();
    await tester.pump();

    expect(MemoryTrim.debugTrims, 1);
    expect(extra, 1);
    expect(MxcImage.debugRetainedEntries, 0);
    expect(MxcImage.debugParsedLottie, 0);
    expect(PaintingBinding.instance.imageCache.containsKey(decode), isFalse);
    expect(find.byType(Image), findsOneWidget);
    expect(event.requests, 1);
  });

  testWidgets('a desktop window hidden for a moment is not trimmed', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MemoryTrim.install();
    await tester.pumpWidget(const SizedBox.shrink());

    MacDesktopWindow.visible.value = false;
    await tester.pump(MemoryTrim.hiddenDelay - const Duration(seconds: 1));
    expect(MemoryTrim.debugTrims, 0);
    MacDesktopWindow.visible.value = true;
    await tester.pump(const Duration(minutes: 1));
    expect(MemoryTrim.debugTrims, 0);
    expect(MemoryTrim.debugTrimPending, isFalse);

    MacDesktopWindow.visible.value = false;
    await tester.pump(MemoryTrim.hiddenDelay + const Duration(seconds: 1));
    expect(MemoryTrim.debugTrims, 1);
    // Once per absence, not again every interval.
    await tester.pump(MemoryTrim.hiddenDelay * 3);
    expect(MemoryTrim.debugTrims, 1);
    expect(MemoryTrim.debugTrimPending, isFalse);

    MacDesktopWindow.visible.value = true;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a hidden desktop lifecycle trims after the delay', (
    tester,
  ) async {
    MemoryTrim.install();
    await tester.pumpWidget(const SizedBox.shrink());
    await _lifecycle(tester, AppLifecycleState.inactive);
    await _lifecycle(tester, AppLifecycleState.hidden);
    expect(MemoryTrim.debugTrimPending, isTrue);
    await tester.pump(MemoryTrim.hiddenDelay + const Duration(seconds: 1));
    expect(MemoryTrim.debugTrims, 1);
    await _lifecycle(tester, AppLifecycleState.inactive);
    await _lifecycle(tester, AppLifecycleState.resumed);
    expect(MemoryTrim.debugTrimPending, isFalse);
  });

  testWidgets('an original with a box decodes at that box', (tester) async {
    final event = _ImageEvent(
      _room('emoji', disk: false),
      r'$emoji',
      _pixel,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: MxcImage(event: event, width: 20, height: 20, isThumbnail: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image)).image;
    expect(image, isA<ResizeImage>());
    final dpr = tester.view.devicePixelRatio;
    expect((image as ResizeImage).width, (20 * dpr).ceil());
    expect(image.height, (20 * dpr).ceil());
  });
}
