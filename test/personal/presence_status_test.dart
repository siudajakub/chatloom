// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/presence_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 25, 14, 3);
  String? text(DateTime? last, {bool online = false, bool use24h = true}) =>
      presenceLabel(
        online: online,
        lastActive: last,
        now: now,
        use24h: use24h,
      )?.text;

  test('online wins and needs no refresh', () {
    final label = presenceLabel(
      online: true,
      lastActive: null,
      now: now,
      use24h: true,
    );
    expect(label?.text, 'online');
    expect(label?.refreshAt, isNull);
  });

  test('no data and future timestamps show nothing', () {
    expect(text(null), isNull);
    expect(text(now.add(const Duration(minutes: 1))), isNull);
  });

  test('relative wording within the hour, refreshed each minute', () {
    expect(
      text(now.subtract(const Duration(seconds: 20))),
      'last seen just now',
    );
    final at = now.subtract(const Duration(minutes: 5, seconds: 10));
    final label = presenceLabel(
      online: false,
      lastActive: at,
      now: now,
      use24h: true,
    )!;
    expect(label.text, 'last seen 5 min ago');
    expect(label.refreshAt, at.add(const Duration(minutes: 6)));
  });

  test('today, yesterday, this year and older', () {
    expect(text(DateTime(2026, 10, 25, 9, 7)), 'last seen today at 09:07');
    expect(
      text(DateTime(2026, 10, 25, 9, 7), use24h: false),
      'last seen today at 9:07 AM',
    );
    expect(
      text(DateTime(2026, 10, 24, 23, 59)),
      'last seen yesterday at 23:59',
    );
    expect(text(DateTime(2026, 10, 12, 8)), 'last seen Oct 12 at 08:00');
    expect(text(DateTime(2025, 3, 2, 8)), 'last seen Mar 2, 2025');
  });

  test('today and yesterday re-word at midnight', () {
    final label = presenceLabel(
      online: false,
      lastActive: DateTime(2026, 10, 25, 9),
      now: now,
      use24h: true,
    )!;
    expect(label.refreshAt, DateTime(2026, 10, 26));
  });

  test('coarse buckets never show a time', () {
    String? coarse(PresencePrecision precision) => presenceLabel(
      online: false,
      lastActive: null,
      now: now,
      use24h: true,
      precision: precision,
    )?.text;
    expect(coarse(PresencePrecision.recently), 'last seen recently');
    expect(coarse(PresencePrecision.week), 'last seen within a week');
    expect(coarse(PresencePrecision.month), 'last seen within a month');
  });

  test('bridge presence parses the schema and rejects junk', () {
    final value = BridgePresence.tryParse({
      'presence': 'offline',
      'last_active_ts': 1761400000000,
      'precision': 'recently',
      'source': 'telegram',
    })!;
    expect(value.online, isFalse);
    expect(value.precision, PresencePrecision.recently);
    expect(value.source, 'telegram');
    expect(value.lastActive.millisecondsSinceEpoch, 1761400000000);
    // Online is always exact; missing precision means exact.
    expect(
      BridgePresence.tryParse({
        'presence': 'online',
        'last_active_ts': 1,
        'precision': 'month',
      })!.precision,
      PresencePrecision.exact,
    );
    expect(
      BridgePresence.tryParse({
        'presence': 'offline',
        'last_active_ts': 5,
      })!.precision,
      PresencePrecision.exact,
    );
    for (final junk in <Map<String, Object?>?>[
      null,
      {},
      {'presence': 'unavailable', 'last_active_ts': 5},
      {'presence': 'offline'},
      {'presence': 'offline', 'last_active_ts': 0},
      {'presence': 'offline', 'last_active_ts': 5, 'precision': 'year'},
    ]) {
      expect(BridgePresence.tryParse(junk), isNull);
    }
  });
}
