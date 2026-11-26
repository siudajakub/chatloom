// SPDX-License-Identifier: AGPL-3.0-or-later
// Shared media grid of the chat details (MD-14, FX-18): month headers,
// durations and which items the viewer opens.
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Db implements DatabaseApi {
  @override
  int get maxFileSize => 1 << 24;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access ${invocation.memberName}');
}

Event _media(
  Client client,
  String id,
  DateTime ts, {
  String type = MessageTypes.Image,
  Map<String, Object?> extra = const {},
}) => Event(
  room: Room(id: '!media:example.invalid', client: client),
  eventId: id,
  senderId: '@fixture:example.invalid',
  type: EventTypes.Message,
  originServerTs: ts,
  content: {
    'msgtype': type,
    'body': 'media',
    'url': 'mxc://example.invalid/$id',
    'info': {
      'mimetype': type == MessageTypes.Video ? 'video/mp4' : 'image/jpeg',
      'size': 100,
    },
    ...extra,
  },
);

void main() {
  test('grid tiles decode at their own size, covering the tile', () {
    // A ~121 dp tile no longer decodes a fixed 240 dp box.
    expect(
      sharedMediaDecodeBox({
        'info': {'w': 1000, 'h': 1000},
      }, 121),
      (128.0, 128.0),
    );
    // Landscape: the short side lands on the tile (no upscale under cover).
    expect(
      sharedMediaDecodeBox({
        'info': {
          'w': 4000,
          'h': 3000,
          'thumbnail_info': {'w': 800, 'h': 400},
        },
      }, 121),
      (256.0, 128.0),
    );
    // Portrait from the full image info, extreme ratios bounded.
    expect(
      sharedMediaDecodeBox({
        'info': {'w': 100, 'h': 1000},
      }, 120),
      (128.0, 384.0),
    );
    // Unknown aspect: 2 × tile, like the old fixed box for 2:1.
    expect(sharedMediaDecodeBox({'info': <String, Object?>{}}, 121), (
      256.0,
      256.0,
    ));
    // Sub-pixel resizes keep the same decode (16 dp steps).
    expect(sharedMediaDecodeBox({}, 113.2), sharedMediaDecodeBox({}, 127.9));
    expect(sharedMediaDecodeBox({}, double.infinity), (240.0, 240.0));
  });

  test('month labels are readable', () {
    expect(sharedMonthLabel(DateTime(2026, 10, 23)), 'October 2026');
    expect(sharedMonthLabel(DateTime(2025, 1, 1)), 'January 2025');
  });

  test('durations read m:ss and h:mm:ss', () {
    expect(sharedDurationLabel(const Duration(seconds: 7)), '0:07');
    expect(sharedDurationLabel(const Duration(seconds: 73)), '1:13');
    expect(
      sharedDurationLabel(const Duration(minutes: 62, seconds: 5)),
      '1:02:05',
    );
  });

  test('media groups by local month, newest first, order kept', () {
    final client = Client('grid', database: _Db());
    final events = [
      _media(client, r'$c', DateTime(2026, 10, 20)),
      _media(client, r'$b', DateTime(2026, 10, 2)),
      _media(client, r'$a', DateTime(2026, 9, 30)),
      _media(client, r'$z', DateTime(2025, 10, 30)),
    ];
    final months = groupSharedMediaByMonth(events);
    expect(
      [for (final (label, _) in months) label],
      ['October 2026', 'September 2026', 'October 2025'],
    );
    expect([for (final e in months.first.$2) e.eventId], [r'$c', r'$b']);
  });

  test('photos and playable videos open in the viewer, rounds do not', () {
    final client = Client('viewer', database: _Db());
    final ts = DateTime(2026, 10, 1);
    expect(sharedOpensInViewer(_media(client, r'$p', ts)), isTrue);
    expect(
      sharedOpensInViewer(
        _media(client, r'$v', ts, type: MessageTypes.Video),
        supportsVideo: true,
      ),
      isTrue,
    );
    expect(
      sharedOpensInViewer(
        _media(client, r'$v', ts, type: MessageTypes.Video),
        supportsVideo: false,
      ),
      isFalse,
    );
    expect(
      sharedOpensInViewer(
        _media(client, r'$f', ts, type: MessageTypes.File),
        supportsVideo: true,
      ),
      isFalse,
    );
  });
}
