// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 5, 12);
  test(
    'old malformed and unconfigured heartbeat never imply dictation ready',
    () {
      for (final payload in <Map<String, dynamic>>[
        {},
        {'transcription': 'ready'},
        {'dictation': true, 'dictationVersion': '1'},
        {'dictation': 'unexpected', 'dictationVersion': -1},
      ]) {
        final value = WorkerReadiness.fromPayload(payload, now);
        expect(value.dictation, isNull);
        expect(value.dictationVersion, isNull);
      }
      final off = WorkerReadiness.fromPayload({
        'dictation': 'not_configured',
        'dictationVersion': 1,
      }, now);
      expect(off.dictation, 'not_configured');
    },
  );
  test('capability participates in equality and freshness stays bounded', () {
    final older = WorkerReadiness.fromPayload({'healthy': true}, now);
    final newer = WorkerReadiness.fromPayload({
      'healthy': true,
      'dictation': 'ready',
      'dictationVersion': 1,
    }, now);
    expect(newer, isNot(older));
    expect(newer.dictation, 'ready');
    expect(newer.dictationVersion, 1);
    expect(newer.freshAt(now.add(const Duration(minutes: 12))), isFalse);
  });
}
