// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

void main() {
  const descriptor = RoundVideoDescriptor(
    sizeBytes: 1024,
    width: 384,
    height: 384,
    durationMs: 5000,
    videoCodec: 'h264',
    audioCodec: 'aac',
    cornersSanitized: true,
  );

  Map<String, dynamic> video(Map<String, dynamic> info) => {
    'msgtype': 'm.video',
    'body': 'video_message.mp4',
    'info': info,
  };

  test('detector accepts the Telegram marker or the display marker', () {
    expect(
      RoundVideoDescriptor.fromContent(video({roundMessageMarker: true})),
      isNotNull,
    );
    expect(
      RoundVideoDescriptor.fromContent(video({roundVideoDisplayMarker: true})),
      isNotNull,
    );
    expect(
      RoundVideoDescriptor.fromContent(
        video({roundMessageMarker: false, roundVideoDisplayMarker: true}),
      ),
      isNotNull,
    );
    for (final info in <Map<String, dynamic>>[
      {},
      {roundMessageMarker: 'true'},
      {roundVideoDisplayMarker: 1},
      {roundVideoDisplayMarker: false},
      {'pl.personal.chat.telegram.round_video': true},
    ]) {
      expect(RoundVideoDescriptor.fromContent(video(info)), isNull);
    }
    expect(
      RoundVideoDescriptor.fromContent({
        'msgtype': 'm.image',
        'info': {roundVideoDisplayMarker: true},
      }),
      isNull,
    );
    expect(
      RoundVideoDescriptor.fromContent(
        video({roundVideoDisplayMarker: true}),
        redacted: true,
      ),
      isNull,
    );
  });

  test('Telegram info is unchanged; other networks get the display marker', () {
    const telegram =
        '{"mimetype":"video/mp4","size":1024,"w":384,"h":384,"duration":5000,'
        '"fi.mau.telegram.round_message":true}';
    expect(jsonEncode(descriptor.matrixInfo), telegram);
    expect(jsonEncode(descriptor.matrixInfoFor('telegram')), telegram);
    expect(
      jsonEncode(descriptor.matrixInfoFor('facebook')),
      '{"mimetype":"video/mp4","size":1024,"w":384,"h":384,"duration":5000,'
      '"pl.personal.chat.round_video":true}',
    );
    expect(
      RoundVideoDescriptor.isTelegramRound(
        video(descriptor.matrixInfoFor('telegram')),
      ),
      isTrue,
    );
    expect(
      RoundVideoDescriptor.isTelegramRound(
        video(descriptor.matrixInfoFor('facebook')),
      ),
      isFalse,
    );
  });

  test('send targets: Telegram and Messenger, never a silent Messenger', () {
    RoundSendTarget target(String network, {bool silent = false}) =>
        RoundSendTarget(
          accountId: 'a',
          deviceId: 'd',
          roomId: 'r',
          network: network,
          silent: silent,
        );
    expect(target('telegram').valid, isTrue);
    expect(target('telegram', silent: true).valid, isTrue);
    expect(target('facebook').valid, isTrue);
    expect(target('facebook', silent: true).valid, isFalse);
    for (final other in ['instagram', 'whatsapp', 'signal', '']) {
      expect(target(other).valid, isFalse, reason: other);
    }
    expect(roundSendNetworks, {'telegram', 'facebook'});
  });
}
