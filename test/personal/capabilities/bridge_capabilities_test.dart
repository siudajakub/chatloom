// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../../../packages/personal_core/lib/src/bridge_capabilities.dart';
import '../../../packages/personal_core/lib/src/contracts.dart';

void check(bool condition, String description) {
  if (!condition) throw StateError(description);
}

void status(
  BridgeCapabilityEvidence evidence,
  CapabilityStatus expected,
  String label,
) {
  check(evidence.result.status == expected, label);
}

void main() {
  const available = CapabilityStatus.available;
  const unknown = CapabilityStatus.unverified;
  const blocked = CapabilityStatus.unavailable;
  for (final feature in BridgeFeature.values) {
    status(
      BridgeRoomCapabilities.fromState(null).evidence(feature),
      unknown,
      'Missing event inferred support',
    );
    status(
      BridgeRoomCapabilities.fromState('invalid').evidence(feature),
      unknown,
      'Malformed state',
    );
  }
  status(
    BridgeRoomCapabilities.fromState({
      'protocol': {'id': 'fixture'},
    }).evidence(BridgeFeature.reply),
    unknown,
    'Bridge identity inferred feature',
  );
  for (final malformed in [true, '2', 2.0, 3, -3, null]) {
    status(
      BridgeRoomCapabilities.fromState({
        'reply': malformed,
      }).evidence(BridgeFeature.reply),
      unknown,
      'Malformed level enabled feature',
    );
  }
  for (final level in [-2, -1, 0]) {
    status(
      BridgeRoomCapabilities.fromState({
        'reply': level,
      }).evidence(BridgeFeature.reply),
      blocked,
      'Rejected/dropped/fallback allowed',
    );
  }
  check(
    BridgeRoomCapabilities.fromState({
      'reply': 1,
    }).evidence(BridgeFeature.reply).partial,
    'Partial support erased',
  );
  status(
    BridgeRoomCapabilities.fromState({
      'reply': 2,
    }).evidence(BridgeFeature.reply),
    available,
    'Full explicit support',
  );
  status(
    BridgeRoomCapabilities.fromState({'reply': 2}).evidence(BridgeFeature.edit),
    unknown,
    'Other feature defaulted',
  );

  final states = {
    'nonempty_bridge_key': {'reply': 2},
    'other_bridge_key': {'reply': -2},
  };
  status(
    BridgeRoomCapabilities.fromStateEvents(
      states,
      bridgeStateKeys: ['nonempty_bridge_key'],
    ).evidence(BridgeFeature.reply),
    available,
    'Nonempty bridge state key ignored',
  );
  status(
    BridgeRoomCapabilities.fromStateEvents(
      states,
    ).evidence(BridgeFeature.reply),
    unknown,
    'Ambiguous states combined',
  );
  status(
    BridgeRoomCapabilities.fromStateEvents(
      states,
      stateKey: 'other_bridge_key',
    ).evidence(BridgeFeature.reply),
    blocked,
    'Selected other source ignored',
  );

  final data = <String, dynamic>{
    'file': {
      'm.audio': {
        'mime_types': {'audio/ogg': 0, 'audio/*': 1, '*/*': 2},
        'max_size': 100,
        'max_duration': 5,
      },
      'org.matrix.msc3245.voice': {
        'mime_types': {'audio/ogg; codecs=opus': 2, 'audio/ogg': 0},
        'max_size': 100,
      },
      'm.image': {
        'mime_types': {'image/png': 1},
        'caption': -1,
      },
    },
  };
  final media = BridgeRoomCapabilities.fromState(data);
  // Parser snapshots source state: later SDK mutations cannot change evidence.
  (data['file'] as Map)['m.audio'] = {
    'mime_types': {'*/*': 2},
  };
  status(
    media.evidence(
      BridgeFeature.audio,
      media: const BridgeMediaRequest(
        mimeType: 'audio/ogg',
        sizeBytes: 50,
        durationSeconds: 2,
      ),
    ),
    blocked,
    'Exact unsupported MIME overridden by wildcard',
  );
  check(
    media
        .evidence(
          BridgeFeature.audio,
          media: const BridgeMediaRequest(
            mimeType: 'audio/mp4',
            sizeBytes: 50,
            durationSeconds: 2,
          ),
        )
        .partial,
    'MIME class partial lost',
  );
  status(
    media.evidence(
      BridgeFeature.voice,
      media: const BridgeMediaRequest(
        mimeType: 'audio/ogg; codecs=opus',
        sizeBytes: 50,
      ),
    ),
    available,
    'Exact Opus voice MIME rejected',
  );
  status(
    media.evidence(
      BridgeFeature.voice,
      media: const BridgeMediaRequest(mimeType: 'audio/ogg', sizeBytes: 50),
    ),
    blocked,
    'Generic OGG voice accepted without codec evidence',
  );
  status(
    media.evidence(
      BridgeFeature.voice,
      media: const BridgeMediaRequest(mimeType: 'audio/wav', sizeBytes: 50),
    ),
    blocked,
    'Unmatched MIME accepted',
  );
  status(
    media.evidence(BridgeFeature.upload),
    blocked,
    'Omitted media type inferred upload support',
  );
  status(
    media.evidence(
      BridgeFeature.audio,
      media: const BridgeMediaRequest(
        mimeType: 'audio/mp4',
        sizeBytes: 101,
        durationSeconds: 2,
      ),
    ),
    blocked,
    'Oversize accepted',
  );
  status(
    media.evidence(
      BridgeFeature.audio,
      media: const BridgeMediaRequest(
        mimeType: 'audio/mp4',
        sizeBytes: 100,
        durationSeconds: 5,
      ),
    ),
    available,
    'Limit boundary rejected',
  );
  status(
    media.evidence(
      BridgeFeature.audio,
      media: const BridgeMediaRequest(
        mimeType: 'audio/mp4',
        sizeBytes: 100,
        durationSeconds: 5.001,
      ),
    ),
    blocked,
    'Overduration accepted',
  );
  status(
    media.evidence(
      BridgeFeature.audio,
      media: const BridgeMediaRequest(mimeType: 'audio/mp4'),
    ),
    unknown,
    'Missing measurements bypassed bounds',
  );
  status(
    media.evidence(
      BridgeFeature.image,
      media: const BridgeMediaRequest(
        mimeType: 'image/png',
        caption: 'fixture-caption',
      ),
    ),
    blocked,
    'Dropped caption treated supported',
  );
  for (final malformed in [
    {
      'mime_types': {'invalid': 2},
    },
    {
      'mime_types': {'audio/*': true},
    },
    {
      'mime_types': {'audio/*': 2},
      'max_size': -1,
    },
  ]) {
    status(
      BridgeRoomCapabilities.fromState({
        'file': {'m.audio': malformed},
      }).evidence(BridgeFeature.audio),
      unknown,
      'Malformed MIME/limit enabled media',
    );
  }
  final regularAudio = BridgeRoomCapabilities.fromState({
    'file': {
      'm.audio': {
        'mime_types': {'audio/*': 2},
      },
    },
  });
  status(
    regularAudio.evidence(BridgeFeature.voice),
    blocked,
    'Regular audio implied voice support',
  );

  final edit = BridgeRoomCapabilities.fromState({
    'edit': 2,
    'edit_max_age': 900,
    'edit_max_count': 5,
  });
  status(
    edit.evidence(
      BridgeFeature.edit,
      messageAge: const Duration(seconds: 900),
      editCount: 4,
    ),
    available,
    'Edit boundary rejected',
  );
  status(
    edit.evidence(
      BridgeFeature.edit,
      messageAge: const Duration(milliseconds: 900001),
    ),
    blocked,
    'Old edit allowed',
  );
  status(
    edit.evidence(BridgeFeature.edit, editCount: 5),
    blocked,
    'Too many edits allowed',
  );
  final reaction = BridgeRoomCapabilities.fromState({
    'reaction': 2,
    'reaction_count': 1,
    'allowed_reactions': ['👍'],
  });
  status(
    reaction.evidence(BridgeFeature.reaction, reaction: '👎'),
    blocked,
    'Disallowed reaction allowed',
  );
  // BR-01: bridgev2 replaces the oldest reaction itself; the count is a
  // limit the client mirrors, never a refusal.
  final counted = reaction.evidence(BridgeFeature.reaction, reaction: '👍');
  status(counted, available, 'Reaction count refused a replacement');
  check(counted.limits['reaction_count'] == 1, 'Reaction count not exposed');

  // BR-02: a complete declaration (bridgev2 always sends its `id`) omits
  // what it does not support (`omitzero`): omitted means 0, unsupported.
  final telegramLike = BridgeRoomCapabilities.fromState({
    'id': 'fixture.capabilities+dm',
    'reply': 2,
    'location_message': 2,
    'max_text_length': 4096,
    'state': {
      'com.beeper.disappearing_timer': {'level': 2},
    },
  });
  check(telegramLike.complete, 'Declaration with id not complete');
  for (final feature in [BridgeFeature.poll, BridgeFeature.thread]) {
    final omitted = telegramLike.evidence(feature);
    status(omitted, blocked, 'Omitted level allowed ${feature.name}');
    check(
      omitted.result.reason.contains('supported on this network') &&
          !omitted.result.reason.contains('bridge'),
      'Unsupported reason not worded per feature',
    );
  }
  status(
    telegramLike.evidence(BridgeFeature.location),
    available,
    'Declared location refused',
  );
  status(
    telegramLike.evidence(BridgeFeature.upload),
    blocked,
    'Omitted file map allowed uploads',
  );
  check(telegramLike.maxTextLength == 4096, 'max_text_length lost');
  check(
    BridgeRoomCapabilities.fromState({'reply': 2}).maxTextLength == null,
    'max_text_length invented',
  );
  status(
    telegramLike.level('poll_hidden_votes'),
    blocked,
    'Omitted poll level allowed',
  );
  status(
    telegramLike.stateEvidence('m.room.name'),
    blocked,
    'Omitted room-name state allowed',
  );
  status(
    telegramLike.stateEvidence('com.beeper.disappearing_timer'),
    available,
    'Declared state refused',
  );
  status(
    telegramLike.memberActionEvidence('kick'),
    blocked,
    'Omitted member actions allowed',
  );
  final groupLike = BridgeRoomCapabilities.fromState({
    'id': 'fixture.capabilities+group',
    'state': {
      'm.room.name': {'level': 2},
      'm.room.topic': {'level': 0},
    },
    'member_actions': {'invite': 2, 'ban': 2},
  });
  status(
    groupLike.stateEvidence('m.room.name'),
    available,
    'Group rename refused',
  );
  status(
    groupLike.stateEvidence('m.room.topic'),
    blocked,
    'Explicit 0 topic allowed',
  );
  status(groupLike.memberActionEvidence('invite'), available, 'Invite refused');
  status(
    groupLike.memberActionEvidence('kick'),
    blocked,
    'Undeclared kick allowed',
  );
  status(
    groupLike.evidence(BridgeFeature.disappearing),
    blocked,
    'Undeclared disappearing timer allowed',
  );
  // Without `id` (redacted, empty or hand-written state) omitted stays
  // unknown, so ordinary chats keep offering it.
  for (final partial in [
    <String, Object?>{},
    {'id': ''},
    {'reply': 2},
  ]) {
    final caps = BridgeRoomCapabilities.fromState(partial);
    status(caps.evidence(BridgeFeature.poll), unknown, 'Partial state refused');
    status(
      caps.stateEvidence('m.room.name'),
      unknown,
      'Partial state refused rename',
    );
    status(
      caps.memberActionEvidence('kick'),
      unknown,
      'Partial state refused kick',
    );
  }
  status(
    BridgeRoomCapabilities.fromState(null).stateEvidence('m.room.name'),
    unknown,
    'Missing state refused rename',
  );
  status(
    BridgeRoomCapabilities.fromState({
      'poll': 2,
      'poll_max_options': 12,
    }).evidence(BridgeFeature.poll, pollOptions: 13),
    blocked,
    'Poll option limit bypass',
  );

  final disappearing = BridgeRoomCapabilities.fromState({
    'state': {
      'com.beeper.disappearing_timer': {'level': 2},
    },
    'disappearing_timer': {
      'types': ['after_send'],
      'timers': [86400000, 604800000],
    },
  });
  status(
    disappearing.evidence(
      BridgeFeature.disappearing,
      disappearingType: 'after_send',
      disappearingTimerMs: 86400000,
    ),
    available,
    'Advertised disappearing setting rejected',
  );
  status(
    disappearing.evidence(
      BridgeFeature.disappearing,
      disappearingType: 'after_read',
    ),
    blocked,
    'Unadvertised disappearing mode allowed',
  );
  status(
    disappearing.evidence(
      BridgeFeature.disappearing,
      disappearingTimerMs: 1000,
    ),
    blocked,
    'Unsupported timer allowed',
  );
  status(
    BridgeRoomCapabilities.fromState({
      'disappearing_timer': {
        'types': ['after_send'],
      },
    }).evidence(BridgeFeature.disappearing),
    unknown,
    'Missing state permission allowed disappearing',
  );
  // ST-12: bridgev2 checks a GIF-style video (`m.video` with
  // `info["fi.mau.gif"]`) against `file["fi.mau.gif"]`, never `m.video`.
  // Meta-style declarations (Messenger, Instagram) take only image/gif
  // there; WhatsApp-style ones take MP4 loops.
  const mp4Loop = BridgeMediaRequest(mimeType: 'video/mp4', sizeBytes: 10);
  const gifFile = BridgeMediaRequest(mimeType: 'image/gif', sizeBytes: 10);
  final metaLike = BridgeRoomCapabilities.fromState({
    'file': {
      'm.video': {
        'mime_types': {'video/mp4': 2},
        'max_size': 1000,
      },
      'fi.mau.gif': {
        'mime_types': {'image/gif': 2},
        'max_size': 1000,
      },
    },
  });
  status(
    metaLike.evidence(BridgeFeature.video, media: mp4Loop),
    available,
    'Meta-style video refused',
  );
  status(
    metaLike.evidence(BridgeFeature.gif, media: mp4Loop),
    blocked,
    'MP4 GIF allowed where only image/gif is declared',
  );
  status(
    metaLike.evidence(BridgeFeature.gif, media: gifFile),
    available,
    'image/gif GIF refused',
  );
  final whatsappLike = BridgeRoomCapabilities.fromState({
    'file': {
      'm.video': {
        'mime_types': {'video/mp4': 2},
      },
      'fi.mau.gif': {
        'mime_types': {'video/mp4': 2},
      },
    },
  });
  status(
    whatsappLike.evidence(BridgeFeature.gif, media: mp4Loop),
    available,
    'WhatsApp-style MP4 GIF refused',
  );
  status(
    BridgeRoomCapabilities.fromState({
      'file': {
        'm.video': {
          'mime_types': {'video/mp4': 2},
        },
      },
    }).evidence(BridgeFeature.gif, media: mp4Loop),
    blocked,
    'Undeclared GIF type allowed through the video declaration',
  );
  stdout.writeln(
    'PASS bridge capabilities: missing/malformed/partial state, '
    'complete declarations, state keys, MIME precedence, codec evidence, '
    'limits, timers, room state, member actions and GIFs',
  );
}
