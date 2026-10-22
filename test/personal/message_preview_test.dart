// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline fixtures; no account, storage or network.
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show roundMessageMarker;

const _owner = '@owner:example.invalid';
const _bot = '@telegrambot:bridge.invalid';
const _partner = '@telegram_200:bridge.invalid';
const _ownGhost = '@telegram_100:bridge.invalid';
const _member = '@telegram_300:bridge.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('preview fixture', database: _NoDatabase());
  @override
  String get userID => _owner;
  final direct = <String, List<String>>{};
  @override
  Map<String, List<String>> get directChats => direct;
}

void _state(Room room, String type, Map<String, dynamic> content, String key) =>
    room.setState(
      Event(
        room: room,
        type: type,
        stateKey: key,
        content: content,
        eventId: '\$state-$type-$key',
        senderId: _bot,
        originServerTs: DateTime.utc(2026),
      ),
    );

Room _room(_Client client, String id, {required bool dm}) {
  final room = Room(id: id, client: client, membership: Membership.join);
  client.rooms.add(room);
  _state(room, 'm.bridge', {
    'bridgebot': _bot,
    'protocol': {'id': 'telegram'},
    'channel': {'id': dm ? '200' : '-1009', if (dm) 'fi.mau.receiver': '100'},
    'com.beeper.room_type.v2': dm ? 'dm' : 'group_dm',
  }, 'fixture');
  for (final entry in {
    _owner: 'Owner',
    _bot: 'Telegram bridge bot',
    _partner: 'Anna',
    _member: 'Bob',
    _ownGhost: 'excellent P',
  }.entries) {
    if (dm && entry.key == _member) continue;
    _state(room, EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': entry.value,
    }, entry.key);
  }
  if (dm) client.direct[_partner] = [room.id];
  return room;
}

var _sequence = 0;
Event _event(
  Room room,
  String sender,
  Map<String, dynamic> content, {
  String type = EventTypes.Message,
  bool redacted = false,
}) => Event(
  room: room,
  eventId: '\$event-${_sequence++}',
  senderId: sender,
  type: type,
  originServerTs: DateTime.utc(2026, 10, 17),
  content: content,
  unsigned: redacted
      ? {
          'redacted_because': {
            'event_id': r'$redaction',
            'type': EventTypes.Redaction,
            'sender': sender,
            'origin_server_ts': 0,
            'content': {},
          },
        }
      : null,
);

void main() {
  late _Client client;
  late Room dm, group;
  setUp(() {
    client = _Client();
    dm = _room(client, '!dm:example.invalid', dm: true);
    group = _room(client, '!group:example.invalid', dm: false);
    OwnSenderResolver.invalidate(client);
  });

  test('own ghost resolves from the DM receiver and applies in groups', () {
    final resolver = OwnSenderResolver.of(client);
    expect(resolver.isOwnSender(_owner), isTrue);
    expect(resolver.isOwnSender(_ownGhost), isTrue);
    expect(resolver.isOwnSender(_partner), isFalse);
    expect(resolver.isOwnSender(_member), isFalse);
    final builds = resolver.debugBuilds;
    resolver.isOwnSender(_ownGhost);
    expect(resolver.debugBuilds, builds, reason: 'cached between changes');
  });

  test('own sticker from the native app reads "You: Sticker"', () {
    final sticker = _event(dm, _ownGhost, {
      'body': 'sticker',
      'url': 'mxc://example.invalid/s',
    }, type: EventTypes.Sticker);
    expect(personalEventPreview(sticker), 'You: Sticker');
    expect(
      personalEventPreview(
        _event(group, _ownGhost, {
          'body': 'x',
          'url': 'mxc://example.invalid/s',
        }, type: EventTypes.Sticker),
      ),
      'You: Sticker',
    );
    expect(
      personalEventPreview(
        _event(dm, _owner, {'msgtype': 'm.text', 'body': 'hi'}),
      ),
      'You: hi',
    );
  });

  test('labels for every message type', () {
    String label(
      Map<String, dynamic> content, {
      String type = 'm.room.message',
    }) => personalPreview(
      _event(dm, _partner, content, type: type),
      own: false,
      group: false,
    );
    expect(label({'msgtype': 'm.image', 'body': 'a.jpg'}), 'Photo');
    expect(
      label({'msgtype': 'm.image', 'body': 'Look', 'filename': 'a.jpg'}),
      'Photo: Look',
    );
    expect(
      label({
        'msgtype': 'm.video',
        'body': 'round.mp4',
        'info': {roundMessageMarker: true, 'mimetype': 'video/mp4'},
      }),
      'Video message',
    );
    expect(label({'msgtype': 'm.video', 'body': 'v.mp4'}), 'Video');
    expect(
      label({
        'msgtype': 'm.video',
        'body': 'g.mp4',
        'info': {'fi.mau.gif': true},
      }),
      'GIF',
    );
    // Telegram video stickers arrive as GIF-flagged webm videos.
    expect(
      label({
        'msgtype': 'm.video',
        'body': 'sticker',
        'info': {
          'fi.mau.gif': true,
          'fi.mau.telegram.animated_sticker': {'id': 1},
          'mimetype': 'video/webm',
        },
      }),
      'Sticker',
    );
    expect(
      label({
        'msgtype': 'm.audio',
        'body': 'voice.ogg',
        'org.matrix.msc3245.voice': {},
      }),
      'Voice message',
    );
    expect(label({'msgtype': 'm.audio', 'body': 'song.mp3'}), 'Audio');
    expect(label({'msgtype': 'm.file', 'body': 'doc.pdf'}), 'File');
    expect(
      label({'msgtype': 'm.location', 'body': 'geo', 'geo_uri': 'geo:1,2'}),
      'Location',
    );
    expect(
      label({
        'org.matrix.msc3381.poll.start': {
          'question': {'org.matrix.msc1767.text': 'Lunch?'},
        },
      }, type: 'org.matrix.msc3381.poll.start'),
      'Poll: Lunch?',
    );
    expect(label({'msgtype': 'm.emote', 'body': 'waves'}), '* waves');
    expect(
      label({'msgtype': 'm.notice', 'body': 'line 1\nline 2'}),
      'line 1 line 2',
    );
  });

  test('prefix: own everywhere, sender in groups, none for the DM partner', () {
    final photo = {'msgtype': 'm.image', 'body': 'a.jpg'};
    expect(personalEventPreview(_event(dm, _partner, photo)), 'Photo');
    expect(personalEventPreview(_event(group, _member, photo)), 'Bob: Photo');
    expect(personalEventPreview(_event(group, _ownGhost, photo)), 'You: Photo');
    expect(
      personalPreview(
        _event(group, _member, photo),
        own: false,
        group: true,
        senderName: 'Robert',
      ),
      'Robert: Photo',
    );
  });

  test('undecryptable, redacted and state events keep the SDK fallback', () {
    final encrypted = _event(dm, _ownGhost, {
      'algorithm': 'm.megolm.v1.aes-sha2',
      'ciphertext': 'x',
    }, type: EventTypes.Encrypted);
    final text = personalEventPreview(encrypted);
    expect(text, isNotEmpty);
    expect(text, isNot(startsWith('You: ')));
    final redacted = _event(dm, _partner, {
      'msgtype': 'm.text',
      'body': 'gone',
    }, redacted: true);
    expect(personalEventPreview(redacted), isNot(contains('gone')));
    final name = _event(dm, _partner, {
      'name': 'New',
    }, type: EventTypes.RoomName);
    expect(personalEventPreview(name), isNot(startsWith('You: ')));
    expect(personalPreviewLabel(name), isNotEmpty);
  });

  test('plain-text fast path equals the markdown path over a corpus', () {
    const corpus = [
      'Hello there',
      '  padded words  ',
      'Numbers 123 and 4.5 are fine',
      'Question? Yes, really (maybe) - ok',
      'Zażółć gęślą jaźń',
      '👍 emoji only',
      'www.example.invalid site',
      'Ends with a dot.',
      'a.b@example.invalid writes',
      '1. list item',
      '2) other list',
      '- dash item',
      '+ plus item',
      '> quote',
      '# heading',
      'Setext\n===',
      'line one\nline two',
      'Tom &amp; Jerry',
      'R&D',
      ':smile: emote',
      '@anna:example.invalid pill',
      '#room:example.invalid',
      '[link](https://example.invalid)',
      '**bold** and _it_',
      '~~strike~~',
      '||spoiler||',
      '`code`',
      r'$x^2$ latex',
      '<b>tag</b>',
      'a | b | c',
      r'escaped \* star',
      '---',
    ];
    for (final body in corpus) {
      final event = _event(dm, _partner, {
        'msgtype': MessageTypes.Text,
        'body': body,
      });
      final slow = event
          .calcUnlocalizedBody(
            hideReply: true,
            hideEdit: true,
            plaintextBody: true,
            removeMarkdown: true,
          )
          .replaceAll(RegExp(r'\s*\n\s*'), ' ')
          .trim();
      final fast = personalPlainFastPath(event);
      if (fast != null) {
        expect(fast, slow, reason: 'fast path differs for "$body"');
      }
      expect(personalPreviewLabel(event), slow, reason: body);
    }
    // Ordinary chat lines take the fast path.
    for (final body in corpus.take(8)) {
      expect(
        personalPlainFastPath(
          _event(dm, _partner, {'msgtype': MessageTypes.Text, 'body': body}),
        ),
        isNotNull,
        reason: body,
      );
    }
    // HTML bodies, edits and redactions take the full path.
    expect(
      personalPlainFastPath(
        _event(dm, _partner, {
          'msgtype': MessageTypes.Text,
          'body': 'plain',
          'format': 'org.matrix.custom.html',
          'formatted_body': '<b>plain</b>',
        }),
      ),
      isNull,
    );
    expect(
      personalPlainFastPath(
        _event(dm, _partner, {
          'msgtype': MessageTypes.Text,
          'body': 'plain',
        }, redacted: true),
      ),
      isNull,
    );
  });

  test('a preview is computed once per event until its content changes', () {
    final event = _event(dm, _partner, {
      'msgtype': MessageTypes.Text,
      'body': '**Bold** news',
    });
    final before = debugPreviewSlowPaths;
    expect(personalPreviewLabel(event), 'Bold news');
    expect(debugPreviewSlowPaths, before + 1);
    for (var i = 0; i < 5; i++) {
      expect(personalPreviewLabel(event), 'Bold news');
    }
    expect(debugPreviewSlowPaths, before + 1);
    // A local edit of the same instance (or a redaction) is seen.
    event.content['body'] = '**Other** news';
    expect(personalPreviewLabel(event), 'Other news');
    expect(debugPreviewSlowPaths, before + 2);
    // Plain text never needs the markdown path.
    final plain = _event(dm, _partner, {
      'msgtype': MessageTypes.Text,
      'body': 'See you at five',
    });
    expect(personalPreviewLabel(plain), 'See you at five');
    expect(debugPreviewSlowPaths, before + 2);
  });
}
