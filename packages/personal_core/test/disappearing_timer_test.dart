// SPDX-License-Identifier: AGPL-3.0-or-later
// mautrix bridgev2 `com.beeper.disappearing_timer`: `{type, timer}` with the
// timer in milliseconds; `{}` when off (BeeperDisappearingTimer.MarshalJSON).
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> _audio(Map<String, dynamic> extra) => {
  'msgtype': 'm.audio',
  'body': 'voice.ogg',
  'info': {'mimetype': 'audio/ogg', 'size': 10},
  ...extra,
};

void main() {
  group('disappearingTimerState', () {
    test('absent, null and explicit off values are off', () {
      for (final value in <Object?>[
        null,
        <String, dynamic>{},
        {'type': ''},
        {'type': 'none'},
        {'type': '', 'timer': 0},
        {'type': null, 'timer': null},
      ]) {
        expect(
          disappearingTimerState(value),
          DisappearingTimerState.off,
          reason: '$value',
        );
        expect(disappearingTimerLimits(value), isFalse, reason: '$value');
      }
    });

    test('any timer type or positive timer is active', () {
      for (final value in <Object?>[
        {'type': 'after_read', 'timer': 86400000},
        {'type': 'after_send', 'timer': 3600000},
        {'type': 'after_read_by_recipient', 'timer': 1000},
        {'type': 'after_send'},
        {'type': 'after_read', 'timer': 0},
        {'type': 'future_mode', 'timer': 5000},
        {'timer': 1},
        {'type': '', 'timer': 1},
        {'type': 'none', 'timer': 60000},
        {'type': 'after_send', 'timer': 1.5},
      ]) {
        expect(
          disappearingTimerState(value),
          DisappearingTimerState.active,
          reason: '$value',
        );
        expect(disappearingTimerLimits(value), isTrue, reason: '$value');
      }
    });

    test('unexpected shapes are malformed and fail closed', () {
      for (final value in <Object?>[
        true,
        false,
        0,
        'after_read',
        const <Object>[],
        {'type': 1},
        {'type': true, 'timer': 0},
        {'type': 'after_read', 'timer': '60000'},
        {'timer': -1},
        {'type': '', 'timer': double.nan},
      ]) {
        expect(
          disappearingTimerState(value),
          DisappearingTimerState.malformed,
          reason: '$value',
        );
        expect(disappearingTimerLimits(value), isTrue, reason: '$value');
      }
    });
  });

  group('RoundMediaPolicy.fromContent', () {
    test('a disappearing message is time limited and not transcribable', () {
      for (final extra in [
        {
          beeperDisappearingTimerKey: {'type': 'after_read', 'timer': 60000},
        },
        {
          'info': {
            'mimetype': 'audio/ogg',
            beeperDisappearingTimerKey: {'type': 'after_send', 'timer': 1000},
          },
        },
      ]) {
        final policy = RoundMediaPolicy.fromContent(_audio(extra));
        expect(policy.isTimeLimited, isTrue);
        expect(policy.malformed, isFalse);
        expect(policy.canPlay, isFalse);
        expect(policy.canPersist, isFalse);
        expect(policy.canTranscribe, isFalse);
        expect(policy.placeholderReason, 'limitedMediaUnavailable');
      }
    });

    test('a malformed timer is limited and flagged', () {
      for (final value in <Object?>[
        'soon',
        7,
        {'type': 3},
        {'timer': -5},
      ]) {
        final policy = RoundMediaPolicy.fromContent(
          _audio({beeperDisappearingTimerKey: value}),
        );
        expect(policy.isTimeLimited, isTrue, reason: '$value');
        expect(policy.malformed, isTrue, reason: '$value');
        expect(policy.canTranscribe, isFalse, reason: '$value');
        expect(policy.placeholderReason, 'invalidProtectiveMetadata');
      }
    });

    test('an off timer or no timer leaves ordinary media usable', () {
      for (final extra in <Map<String, dynamic>>[
        {},
        {beeperDisappearingTimerKey: null},
        {beeperDisappearingTimerKey: <String, dynamic>{}},
        {
          beeperDisappearingTimerKey: {'type': '', 'timer': 0},
        },
      ]) {
        final policy = RoundMediaPolicy.fromContent(_audio(extra));
        expect(policy.canTranscribe, isTrue, reason: '$extra');
        expect(policy.canPersist, isTrue, reason: '$extra');
      }
    });

    test('the legacy com.beeper.disappearing key keeps working', () {
      expect(
        RoundMediaPolicy.fromContent(
          _audio({
            'com.beeper.disappearing': {'timer': 5},
          }),
        ).canTranscribe,
        isFalse,
      );
    });
  });
}
