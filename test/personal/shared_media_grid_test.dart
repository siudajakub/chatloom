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
