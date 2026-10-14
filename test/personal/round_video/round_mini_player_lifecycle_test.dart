import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/pages/chat/events/round_mini_player.dart';
import 'package:fluffychat/pages/chat/events/round_video_message.dart';
import 'package:fluffychat/personal/media/media_access.dart';
import 'package:fluffychat/personal/round_video/round_media_loader.dart';
import 'package:fluffychat/personal/round_video/round_playback_coordinator.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:video_player/video_player.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _NeverLoad extends RoundMediaLoader {
  int downloads = 0, thumbnails = 0;
  @override
  Future<RoundLoadedMedia> load(
    Event event, {
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) async {
    downloads++;
    throw StateError('blocked source reached download');
  }

  @override
  Future<Uint8List?> thumbnail(
    Event event, {
    RoundMediaCancellation? cancellation,
  }) async {
    thumbnails++;
    throw StateError('blocked source reached thumbnail');
  }
}

Event _event() {
  final client = Client('mini fixture', database: _UnusedDatabase());
  return Event(
    room: Room(id: '!fixture:example.invalid', client: client),
    eventId: r'$round',
    senderId: '@fixture:example.invalid',
    type: EventTypes.Message,
    originServerTs: DateTime.utc(2026),
    content: {
      'msgtype': 'm.video',
      'body': 'fixture.mp4',
      'info': {'fi.mau.telegram.round_message': true, 'duration': 10000},
    },
  );
}

void main() {
  test(
    'session cancellation covers playback and source subscriptions',
    () async {
      var cancellations = 0;
      final streams = List.generate(
        3,
        (_) => StreamController<Object?>(onCancel: () => cancellations++),
      );
      final event = _event();
      addTearDown(() => TelegramRoundService.closeFor(event.room.client));
      final session =
          RoundDetachedPlayback(event: event, intent: RoundPlaybackIntent())
            ..positionSubscription = streams[0].stream.listen((_) {})
            ..stateSubscription = streams[1].stream.listen((_) {})
            ..redactionSubscription = streams[2].stream.listen((_) {});
      await session.cancelSubscriptions();
      await session.cancelSubscriptions();
      expect(cancellations, 3);
      expect(session.positionSubscription, isNull);
      expect(session.stateSubscription, isNull);
      expect(session.redactionSubscription, isNull);
      for (final stream in streams) {
        await stream.close();
      }
    },
  );

  test(
    'late source callback cannot destroy a transferred player/lease',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mini_lease_fixture_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final access = await MediaAccess.open(directory: directory);
      final lease = await access.create(
        Uint8List.fromList([1, 2, 3]),
        extension: '.mp4',
      );
      final event = _event();
      addTearDown(() => TelegramRoundService.closeFor(event.room.client));
      final coordinator = RoundPlaybackCoordinator();
      final control = RoundMiniPlayerController(coordinator: coordinator);
      addTearDown(control.dispose);
      // No initialize() or native texture: this fixture tests ownership only.
      final video = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/fixture'),
      );
      final handle = coordinator.register(
        pause: () async {},
        stop: () async {},
      );
      await handle.acquireAudible();
      final session = RoundDetachedPlayback(
        event: event,
        video: video,
        media: RoundLoadedMedia.native(lease),
        handle: handle,
        intent: RoundPlaybackIntent(),
      );
      control.adopt(session);
      final stale = session.serviceListener!;
      final replacedMedia = Event(
        room: event.room,
        eventId: event.eventId,
        senderId: event.senderId,
        originServerTs: event.originServerTs,
        type: EventTypes.Message,
        content: {...event.content, 'url': 'mxc://example.invalid/replacement'},
      );
      expect(control.takeFor(replacedMedia), isNull);
      expect(control.current, same(session));
      final returned = control.takeFor(event);
      expect(returned, same(session));
      stale();
      expect(session.disposed, isFalse);
      expect(handle.isCurrent, isTrue);
      expect(await lease.file.exists(), isTrue);
      handle.dispose();
      await video.dispose();
      await session.media!.close();
    },
  );

  testWidgets(
    'mini view scales text, reopens exact source and closes its lease',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('mini_view_fixture_'),
      ))!;
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final lease = (await tester.runAsync(
        () async => (await MediaAccess.open(
          directory: directory,
        )).create(Uint8List.fromList([1]), extension: '.mp4'),
      ))!;
      final event = _event();
      addTearDown(() => TelegramRoundService.closeFor(event.room.client));
      final coordinator = RoundPlaybackCoordinator();
      final control = RoundMiniPlayerController(coordinator: coordinator);
      addTearDown(control.dispose);
      final video = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/fixture'),
      );
      video.value = const VideoPlayerValue(
        duration: Duration(seconds: 10),
        position: Duration(seconds: 1),
        isInitialized: true,
      );
      final handle = coordinator.register(
        pause: () async {},
        stop: () async {},
      );
      await handle.acquireAudible();
      control.adopt(
        RoundDetachedPlayback(
          event: event,
          video: video,
          media: RoundLoadedMedia.native(lease),
          handle: handle,
          intent: RoundPlaybackIntent(),
        ),
      );
      Event? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SizedBox(
                width: 320,
                child: RoundMiniPlayer(
                  controller: control,
                  onOpenSource: (source) => opened = source,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Round video'));
      expect(opened, same(event));
      expect(opened!.room.client, same(event.room.client));
      await tester.runAsync(control.stop);
      await tester.pump();
      expect(control.current, isNull);
      expect(await tester.runAsync(lease.file.exists), isFalse);
      expect(find.byTooltip('Zatrzymaj odtwarzanie'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final state in ['expired', 'pending', 'unavailable']) {
    testWidgets('$state source never auto-loads video or thumbnail', (
      tester,
    ) async {
      final event = _event();
      final loader = _NeverLoad();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoundVideoMessage(
              event,
              loader: loader,
              coordinator: RoundPlaybackCoordinator(),
              allowMutedAutoplay: true,
              showThumbnail: true,
              isExpired: state == 'expired',
              sourceStatePending: state == 'pending',
              sourceStateUnavailable: state == 'unavailable',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(loader.downloads, 0);
      expect(loader.thumbnails, 0);
      expect(find.byTooltip('Play video message'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
