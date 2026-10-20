// SPDX-License-Identifier: AGPL-3.0-or-later
// Play paths wait only briefly behind a prefetch and stop waiting on cancel;
// background thumbnails keep the long wait. Fictional offline fixtures only.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/media_inflight.dart';
import 'package:chatloom/personal/round_video/round_media_loader.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

Event _round(String mxc) => Event(
  room: Room(
    id: '!inflight:example.invalid',
    client: Client('inflight fixture', database: _UnusedDatabase()),
  ),
  eventId: r'$inflight-round',
  senderId: '@fixture:example.invalid',
  type: EventTypes.Message,
  originServerTs: DateTime.utc(2026),
  content: {
    'msgtype': 'm.video',
    'body': 'fixture.mp4',
    'url': mxc,
    'info': {
      'fi.mau.telegram.round_message': true,
      'duration': 2500,
      'mimetype': 'video/mp4',
      'size': 3,
    },
  },
);

void main() {
  test('nothing in flight answers synchronously', () {
    expect(
      MediaInflight.settle(Uri.parse('mxc://example.invalid/none')),
      isNull,
    );
  });

  test('user wait is short, background wait keeps its bound', () {
    fakeAsync((async) {
      final mxc = Uri.parse('mxc://example.invalid/slow-user');
      final prefetch = Completer<void>();
      MediaInflight.track(mxc, prefetch.future);
      var user = false, background = false;
      MediaInflight.settle(mxc)!.then((_) => user = true);
      MediaInflight.settle(
        mxc,
        wait: MediaInflight.maxWait,
      )!.then((_) => background = true);
      async.elapse(MediaInflight.userWait - const Duration(milliseconds: 1));
      expect(user, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(user, isTrue);
      expect(background, isFalse);
      async.elapse(MediaInflight.maxWait);
      expect(background, isTrue);
      prefetch.complete();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a finished prefetch or a cancel ends the wait at once', () {
    fakeAsync((async) {
      final mxc = Uri.parse('mxc://example.invalid/cancel');
      final prefetch = Completer<void>();
      MediaInflight.track(mxc, prefetch.future);
      var cancelled = false, ended = false;
      MediaInflight.settle(
        mxc,
        wait: MediaInflight.maxWait,
        cancelled: () => cancelled,
      )!.then((_) => ended = true);
      async.elapse(const Duration(seconds: 1));
      expect(ended, isFalse);
      cancelled = true;
      async.elapse(MediaInflight.cancelPoll);
      expect(ended, isTrue);
      expect(async.pendingTimers, isEmpty);

      var done = false;
      MediaInflight.settle(mxc)!.then((_) => done = true);
      prefetch.complete();
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a cancelled user load stops waiting behind a prefetch', () {
    fakeAsync((async) {
      const mxc = 'mxc://example.invalid/cancel-load';
      final prefetch = Completer<void>();
      MediaInflight.track(Uri.parse(mxc), prefetch.future);
      var downloads = 0;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              downloads++;
              return MatrixFile(bytes: Uint8List(3), name: 'fixture.mp4');
            },
      );
      final cancellation = RoundMediaCancellation();
      Object? failure;
      loader
          .load(_round(mxc), cancellation: cancellation)
          .then<void>((_) {}, onError: (Object error) => failure = error);
      async.elapse(const Duration(seconds: 1));
      expect(failure, isNull);
      cancellation.cancel();
      async.elapse(MediaInflight.cancelPoll);
      expect(failure, isA<RoundMediaUnavailable>());
      expect(downloads, 0);
      prefetch.complete();
      async.flushMicrotasks();
    });
  });
}
