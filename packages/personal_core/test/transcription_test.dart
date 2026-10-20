// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 10, 17, 12);

AutoTranscriptionCandidate candidate({
  AutoTranscriptionKind? kind = AutoTranscriptionKind.voice,
  String network = 'telegram',
  String roomId = '!room:beeper.local',
  bool outgoing = false,
  DateTime? timestamp,
  int? durationMs = 12000,
  Map<String, dynamic>? chat,
  Map<String, dynamic>? person,
  Map<String, dynamic>? networkPolicy,
}) => AutoTranscriptionCandidate(
  kind: kind,
  network: network,
  roomId: roomId,
  outgoing: outgoing,
  timestamp: timestamp ?? now.subtract(const Duration(minutes: 1)),
  durationMs: durationMs,
  chatMetadata: chat,
  personMetadata: person,
  networkMetadata: networkPolicy,
);

void main() {
  test('Armenian is offered and validated alongside Polish and English', () {
    expect(transcriptionLanguages.keys, ['pl', 'en', 'hy']);
    expect(transcriptionLanguages['hy'], 'Armenian');
    for (final code in [null, 'pl', 'en', 'hy']) {
      expect(validTranscriptionLanguage(code), isTrue, reason: '$code');
    }
    for (final code in ['', 'de', 'HY', 'hye', 1, true]) {
      expect(validTranscriptionLanguage(code), isFalse, reason: '$code');
    }
  });

  test('sha256Hex matches the FIPS 180-4 vectors', () {
    expect(
      sha256Hex(utf8.encode('')),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256Hex(
        utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      ),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
    expect(
      sha256Hex(List<int>.filled(1000000, 0x61)),
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    );
  });

  test('transcript entity id is stable and independent of network label', () {
    const a = SourceEventRef(
      conversation: ConversationRef(
        accountId: '@self:example.invalid',
        roomId: '!room:beeper.local',
        network: 'telegram',
      ),
      eventId: r'$event',
    );
    const b = SourceEventRef(
      conversation: ConversationRef(
        accountId: '@self:example.invalid',
        roomId: '!room:beeper.local',
      ),
      eventId: r'$event',
    );
    expect(transcriptEntityId(a), transcriptEntityId(b));
    expect(
      transcriptEntityId(a),
      'transcript:${sha256Hex(utf8.encode(a.key))}',
    );
    expect(
      transcriptEntityId(a),
      matches(RegExp(r'^transcript:[0-9a-f]{64}$')),
    );
  });

  test('TranscriptionJob origin is backward compatible', () {
    const source = SourceEventRef(
      conversation: ConversationRef(accountId: '@a:x', roomId: '!r:x'),
      eventId: r'$e',
    );
    const manual = TranscriptionJob(
      id: 't',
      source: source,
      state: JobState.queued,
    );
    expect(manual.toJson().containsKey('origin'), isFalse);
    expect(TranscriptionJob.fromJson(manual.toJson().cast()).automatic, false);
    const auto = TranscriptionJob(
      id: 't',
      source: source,
      state: JobState.queued,
      language: 'hy',
      origin: TranscriptionOrigin.auto,
    );
    final decoded = TranscriptionJob.fromJson(
      jsonDecode(jsonEncode(auto.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.origin, TranscriptionOrigin.auto);
    expect(decoded.language, 'hy');
    expect(
      TranscriptionJob.fromJson({
        ...manual.toJson().cast<String, dynamic>(),
        'origin': 'robot',
      }).origin,
      TranscriptionOrigin.manual,
    );
  });

  group('TranscriptionPolicy', () {
    test('absent policy is automatic everywhere with documented limits', () {
      final policy = TranscriptionPolicy.fromValue(null);
      expect(policy.auto, isTrue);
      expect(policy.enabledAt, isNull);
      expect(policy.defaultLanguage, isNull);
      expect(policy.maxSeconds, 300);
      expect(policy.dailyBudgetUsd, 1.0);
      expect(policy.networkEnabled('telegram'), isTrue);
      expect(policy.networkEnabled('unknown'), isTrue);
    });

    test('round-trips JSON and fails closed on malformed or newer data', () {
      final policy = TranscriptionPolicy.defaults
          .withAuto(false, now)
          .withAuto(true, now)
          .copyWith(
            defaultLanguage: () => 'hy',
            maxSeconds: 600,
            dailyBudgetUsd: 2,
          )
          .withNetwork('whatsapp', false)
          .withChatOverride('!a:x', true)
          .withChatOverride('!b:x', false);
      final decoded = TranscriptionPolicy.fromValue(
        jsonDecode(jsonEncode(policy.toJson())),
      );
      expect(decoded, policy);
      expect(decoded.enabledAt, now);
      expect(decoded.defaultLanguage, 'hy');
      expect(decoded.withChatOverride('!a:x', null).chatOverrides, {
        '!b:x': false,
      });
      expect(TranscriptionPolicy.fromValue('garbage').auto, isFalse);
      expect(TranscriptionPolicy.fromValue({'auto': 'yes'}).auto, isFalse);
      expect(
        TranscriptionPolicy.fromValue({'version': 2, 'auto': true}).auto,
        isFalse,
      );
      final clamped = TranscriptionPolicy.fromValue({
        'maxSeconds': 1,
        'dailyBudgetUsd': -4,
        'defaultLanguage': 'xx',
        'networks': {'telegram': 'no', '': true, 'signal': false},
      });
      expect(clamped.maxSeconds, TranscriptionPolicy.minMaxSeconds);
      expect(clamped.dailyBudgetUsd, 0);
      expect(clamped.defaultLanguage, isNull);
      expect(clamped.networks, {'signal': false});
    });

    test('turning auto on restarts the window; staying on keeps it', () {
      final later = now.add(const Duration(hours: 2));
      final on = TranscriptionPolicy.disabled.withAuto(true, now);
      expect(on.enabledAt, now);
      expect(on.withAuto(true, later).enabledAt, now);
      final off = on.withAuto(false, later);
      expect(off.auto, isFalse);
      expect(off.withAuto(true, later).enabledAt, later);
    });

    test('unknown network is skipped once any network is switched off', () {
      final policy = TranscriptionPolicy.defaults.withNetwork('signal', false);
      expect(policy.networkEnabled('signal'), isFalse);
      expect(policy.networkEnabled('telegram'), isTrue);
      expect(policy.networkEnabled('unknown'), isFalse);
    });
  });

  group('autoTranscriptionBlock', () {
    const policy = TranscriptionPolicy.defaults;
    String? block(AutoTranscriptionCandidate c, [TranscriptionPolicy? p]) =>
        autoTranscriptionBlock(p ?? policy, c, now: now);

    test('incoming voice and round messages are eligible by default', () {
      expect(block(candidate()), isNull);
      expect(block(candidate(kind: AutoTranscriptionKind.round)), isNull);
      expect(autoEligible(policy, candidate(), now: now), isTrue);
    });

    test('own, unsupported, old and pre-enable messages are excluded', () {
      expect(block(candidate(), TranscriptionPolicy.disabled), 'disabled');
      expect(block(candidate(kind: null)), 'unsupported');
      expect(block(candidate(outgoing: true)), 'outgoing');
      expect(
        block(candidate(timestamp: now.subtract(const Duration(hours: 25)))),
        'too_old',
      );
      final enabled = policy.copyWith(enabledAt: () => now);
      expect(
        block(
          candidate(timestamp: now.subtract(const Duration(seconds: 1))),
          enabled,
        ),
        'before_enabled',
      );
      expect(block(candidate(timestamp: now), enabled), isNull);
    });

    test('an unknown timestamp is too old, never eligible', () {
      const undated = AutoTranscriptionCandidate(
        kind: AutoTranscriptionKind.voice,
        network: 'telegram',
        roomId: '!room:beeper.local',
        outgoing: false,
        durationMs: 12000,
      );
      expect(block(undated), 'too_old');
      expect(
        block(undated, policy.copyWith(enabledAt: () => now)),
        'too_old',
        reason: 'The enable moment cannot be compared with an unknown age',
      );
      expect(
        block(undated, policy.withChatOverride(undated.roomId, true)),
        'too_old',
        reason: 'Per-chat Always never outranks the time window',
      );
    });

    test('ignored, muted and disabled networks are skipped', () {
      expect(block(candidate(chat: {'ignored': true})), 'ignored');
      expect(block(candidate(chat: {'placement': 'ignored'})), 'ignored');
      expect(block(candidate(person: {'ignored': true})), 'ignored');
      expect(block(candidate(chat: {'muted': true})), 'muted');
      expect(block(candidate(chat: {'notificationMode': 'muted'})), 'muted');
      expect(
        block(candidate(networkPolicy: {'notifications': 'muted'})),
        'muted',
      );
      // An explicit chat mode outranks the muted network default.
      expect(
        block(
          candidate(
            chat: {'notificationMode': 'all'},
            networkPolicy: {'notifications': 'muted'},
          ),
        ),
        isNull,
      );
      expect(
        block(candidate(), policy.withNetwork('telegram', false)),
        'network_disabled',
      );
    });

    test('per-chat Always/Never outrank network and mute rules only', () {
      final always = policy
          .withNetwork('telegram', false)
          .withChatOverride('!room:beeper.local', true);
      expect(block(candidate(chat: {'muted': true}), always), isNull);
      expect(block(candidate(outgoing: true), always), 'outgoing');
      expect(block(candidate(durationMs: 301000), always), 'duration_limit');
      final never = policy.withChatOverride('!room:beeper.local', false);
      expect(block(candidate(), never), 'chat_disabled');
    });

    test('duration cap and zero budget are reported as limits', () {
      expect(block(candidate(durationMs: 300000)), isNull);
      expect(block(candidate(durationMs: 300001)), 'duration_limit');
      expect(block(candidate(durationMs: null)), isNull);
      expect(block(candidate(), policy.copyWith(dailyBudgetUsd: 0)), 'budget');
    });
  });

  group('transcribable media kinds', () {
    Map<String, dynamic> media(
      String msgtype, {
      Map<String, dynamic> info = const {},
      Map<String, dynamic> extra = const {},
      String body = 'clip',
    }) => {'msgtype': msgtype, 'body': body, 'info': info, ...extra};

    test('voice, other audio, rounds and videos are recognised', () {
      expect(
        transcribableMediaKind(
          media('m.audio', extra: {'org.matrix.msc3245.voice': {}}),
        ),
        AutoTranscriptionKind.voice,
      );
      expect(
        transcribableMediaKind(
          media('m.audio', info: {'mimetype': 'audio/mpeg'}),
        ),
        AutoTranscriptionKind.audio,
      );
      expect(
        transcribableMediaKind(
          media(
            'm.video',
            info: {'mimetype': 'video/mp4', roundMessageMarker: true},
          ),
        ),
        AutoTranscriptionKind.round,
      );
      for (final mime in [
        'video/mp4',
        'video/webm',
        'video/quicktime',
        'video/3gpp',
        'video/x-matroska',
        'video/x-m4v',
      ]) {
        expect(
          transcribableMediaKind(media('m.video', info: {'mimetype': mime})),
          AutoTranscriptionKind.video,
          reason: mime,
        );
      }
      expect(
        transcribableMediaKind(media('m.video')),
        AutoTranscriptionKind.video,
      );
    });

    test('files with a media type or extension are recognised', () {
      expect(
        transcribableMediaKind(
          media('m.file', info: {'mimetype': 'video/mp4'}),
        ),
        AutoTranscriptionKind.video,
      );
      expect(
        transcribableMediaKind(
          media('m.file', info: {'mimetype': 'audio/ogg'}),
        ),
        AutoTranscriptionKind.audio,
      );
      expect(
        transcribableMediaKind(media('m.file', body: 'Lecture.MOV')),
        AutoTranscriptionKind.video,
      );
      expect(
        transcribableMediaKind(
          media(
            'm.file',
            body: 'caption',
            extra: {'filename': 'memo.m4a'},
            info: {'mimetype': 'application/octet-stream'},
          ),
        ),
        AutoTranscriptionKind.audio,
      );
      expect(transcribableMediaKind(media('m.file', body: 'a.pdf')), isNull);
      expect(
        transcribableMediaKind(
          media('m.file', info: {'mimetype': 'application/pdf'}),
        ),
        isNull,
      );
    });

    test('silent loops, images, playlists and protected media are not', () {
      expect(
        transcribableMediaKind(
          media('m.video', info: {'mimetype': 'video/mp4', 'fi.mau.gif': true}),
        ),
        isNull,
      );
      expect(
        transcribableMediaKind(
          media('m.video', info: {'fi.mau.no_audio': true}),
        ),
        isNull,
      );
      expect(
        transcribableMediaKind(
          media(
            'm.video',
            info: {'fi.mau.loop': true, 'fi.mau.autoplay': true},
          ),
        ),
        isNull,
      );
      expect(
        transcribableMediaKind(
          media('m.video', info: {'mimetype': 'image/gif'}),
        ),
        isNull,
      );
      expect(
        transcribableMediaKind(
          media('m.file', info: {'mimetype': 'audio/x-mpegurl'}),
        ),
        isNull,
      );
      expect(transcribableMediaKind(media('m.image')), isNull);
      expect(
        transcribableMediaKind({'msgtype': 'm.text', 'body': 'x'}),
        isNull,
      );
      expect(
        transcribableMediaKind(
          media('m.video', extra: {'protected_content': true}),
        ),
        isNull,
      );
      expect(
        transcribableMediaKind(
          media(
            'm.audio',
            extra: {
              beeperDisappearingTimerKey: {
                'type': 'after_read',
                'timer': 60000,
              },
            },
          ),
        ),
        isNull,
      );
    });

    test('per-kind switches are synced and apply even with Always', () {
      const base = TranscriptionPolicy();
      for (final kind in AutoTranscriptionKind.values) {
        expect(base.kindEnabled(kind), isTrue, reason: kind.name);
      }
      final noVideo = base.withKind(AutoTranscriptionKind.video, false);
      final restored = TranscriptionPolicy.fromValue(
        jsonDecode(jsonEncode(noVideo.toJson())),
      );
      expect(restored, noVideo);
      expect(restored.kindEnabled(AutoTranscriptionKind.video), isFalse);
      expect(restored.kindEnabled(AutoTranscriptionKind.voice), isTrue);
      expect(
        autoTranscriptionBlock(
          restored.withChatOverride('!room:beeper.local', true),
          candidate(kind: AutoTranscriptionKind.video),
          now: now,
        ),
        'kind_disabled',
      );
      expect(
        autoTranscriptionBlock(
          restored,
          candidate(kind: AutoTranscriptionKind.audio),
          now: now,
        ),
        isNull,
      );
      // Unknown and malformed kind switches are ignored.
      final odd = TranscriptionPolicy.fromValue({
        'kinds': {'video': 'no', 'hologram': false, 'round': false},
      });
      expect(odd.kinds, {'round': false});
    });
  });
}
