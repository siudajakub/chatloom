// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

extension StreamExtension on Stream {
  /// Returns a new Stream which outputs only `true` for every update of the original
  /// stream, ratelimited by the Duration t
  Stream<bool> rateLimit(Duration t) {
    late final StreamController<bool> controller;
    StreamSubscription? subscription;
    Timer? timer;
    var gotMessage = false;
    var cancelled = false;
    void onMessage() {
      if (cancelled || controller.isClosed) return;
      if (timer == null) {
        gotMessage = false;
        controller.add(true);
        timer = Timer(t, () {
          timer = null;
          if (gotMessage) onMessage();
        });
      } else {
        gotMessage = true;
      }
    }

    controller = StreamController<bool>(
      onListen: () {
        subscription = listen(
          (_) => onMessage(),
          onDone: () {
            timer?.cancel();
            timer = null;
            if (gotMessage) controller.add(true);
            gotMessage = false;
            unawaited(controller.close());
          },
          onError: controller.addError,
        );
      },
      onPause: () {
        subscription?.pause();
        timer?.cancel();
        timer = null;
      },
      onResume: () {
        subscription?.resume();
        if (gotMessage) onMessage();
      },
      onCancel: () async {
        cancelled = true;
        timer?.cancel();
        timer = null;
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }
}
