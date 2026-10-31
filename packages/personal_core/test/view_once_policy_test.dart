// SPDX-License-Identifier: AGPL-3.0-or-later
// View-once media: bridgev2's `com.beeper.view_limited` object and the
// ChatLoom Instagram bridge marker `pl.personal.chat.instagram.raven`.
// Fictional content only.
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> _media(String msgtype, Map<String, dynamic> extra) => {
  'msgtype': msgtype,
  'body': msgtype == 'm.video' ? 'video.mp4' : 'image.jpg',
  'url': 'mxc://example.invalid/media',
  'info': {
    'mimetype': msgtype == 'm.video' ? 'video/mp4' : 'image/jpeg',
    'size': 1000,
  },
  ...extra,
};

void main() {
  group('com.beeper.view_limited', () {
    test('a bool keeps its meaning', () {
      final on = RoundMediaPolicy.fromContent(
        _media('m.image', {beeperViewLimitedKey: true}),
      );
      expect(on.isTimeLimited, isTrue);
      expect(on.malformed, isFalse);
      expect(on.canPlay, isFalse);
      final off = RoundMediaPolicy.fromContent(
        _media('m.image', {beeperViewLimitedKey: false}),
      );
      expect(off.isTimeLimited, isFalse);
      expect(off.canPlay, isTrue);
    });

    test('the bridgev2 object is limited, not malformed', () {
      for (final value in <Map<String, dynamic>>[
        {'type': 'count', 'count': 1},
        {'type': 'view_once'},
        {'type': 'time', 'time': 10000},
        {},
      ]) {
        final policy = RoundMediaPolicy.fromContent(
          _media('m.image', {beeperViewLimitedKey: value}),
        );
        expect(policy.isTimeLimited, isTrue, reason: '$value');
        expect(policy.malformed, isFalse, reason: '$value');
        expect(policy.canPlay, isFalse, reason: '$value');
        expect(policy.canExport, isFalse, reason: '$value');
        expect(policy.placeholderReason, 'limitedMediaUnavailable');
      }
    });

    test('a wrong shape is malformed (fail closed)', () {
      for (final value in <Object?>[
        'once',
        3,
        {'type': 5},
        {'count': -1},
        {'count': 'one'},
        {'time': 1.5},
      ]) {
        final policy = RoundMediaPolicy.fromContent(
          _media('m.image', {beeperViewLimitedKey: value}),
        );
        expect(policy.isTimeLimited, isTrue, reason: '$value');
        expect(policy.malformed, isTrue, reason: '$value');
        expect(policy.placeholderReason, 'invalidProtectiveMetadata');
      }
    });
  });

  group('Instagram view-once marker', () {
    test('view once and allow replay play and persist, never export', () {
      for (final (mode, expected) in [
        (0, InstagramRavenMode.viewOnce),
        (1, InstagramRavenMode.allowReplay),
      ]) {
        for (final type in ['m.image', 'm.video']) {
          final content = _media(type, {
            instagramRavenKey: {'version': 1, 'view_mode': mode},
          });
          final policy = RoundMediaPolicy.fromContent(content);
          expect(policy.viewOnceMode, expected, reason: '$type $mode');
          expect(policy.isTimeLimited, isFalse);
          expect(policy.malformed, isFalse);
          // Downloaded, cached and shown like any photo or video...
          expect(policy.canPlay, isTrue);
          expect(policy.canPersist, isTrue);
          expect(policy.placeholderReason, isNull);
          // ...but never saved, shared, forwarded or transcribed.
          expect(policy.canExport, isFalse);
          expect(policy.canForward, isFalse);
          expect(policy.canTranscribe, isFalse);
          expect(instagramRavenOf(content), (present: true, mode: expected));
        }
      }
    });

    test('a raven video is never a transcription candidate', () {
      expect(
        transcribableMediaKind(
          _media('m.video', {
            instagramRavenKey: {'version': 1, 'view_mode': 1},
          }),
        ),
        isNull,
      );
      expect(transcribableMediaKind(_media('m.video', {})), isNotNull);
    });

    test('a malformed marker is limited and malformed', () {
      for (final value in <Object?>[
        true,
        'view_once',
        {'view_mode': 0},
        {'version': 2, 'view_mode': 0},
        {'version': 1, 'view_mode': 2},
        {'version': 1, 'view_mode': '0'},
        {'version': 1},
      ]) {
        final content = _media('m.image', {instagramRavenKey: value});
        final policy = RoundMediaPolicy.fromContent(content);
        expect(policy.viewOnceMode, isNull, reason: '$value');
        expect(policy.malformed, isTrue, reason: '$value');
        expect(policy.canPlay, isFalse, reason: '$value');
        expect(instagramRavenOf(content), (present: true, mode: null));
      }
    });

    test('ordinary media is unchanged', () {
      final content = _media('m.image', {});
      final policy = RoundMediaPolicy.fromContent(content);
      expect(policy.viewOnceMode, isNull);
      expect(policy.canExport, isTrue);
      expect(policy.canForward, isTrue);
      expect(policy.canTranscribe, isTrue);
      expect(instagramRavenOf(content), (present: false, mode: null));
    });
  });
}
