// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// The display-only "Show activity status" preference for chat headers.
///
/// It only decides whether received presence is shown; own presence is
/// always sent as offline (`PrivacyPolicy.allowOnlinePresence`).
abstract final class PresenceDisplay {
  static ValueNotifier<bool>? _enabled;

  /// Live value, seeded from [AppSettings.personalShowPresence] on first use.
  static ValueNotifier<bool> get enabled =>
      _enabled ??= ValueNotifier(AppSettings.personalShowPresence.value);

  static Future<void> set(bool value) async {
    enabled.value = value;
    await AppSettings.personalShowPresence.setItem(value);
  }

  @visibleForTesting
  static void debugReset([bool? value]) {
    _enabled?.dispose();
    _enabled = value == null ? null : ValueNotifier(value);
  }
}

/// How exact a last-seen time is. Networks that hide the exact time (Telegram
/// "last seen recently") only reveal a bucket.
enum PresencePrecision { exact, recently, week, month }

/// Room account data a ChatLoom bridge fork writes through the user's double
/// puppet for a 1:1 portal. It is private to the account, never in the
/// timeline, and invisible to the contact.
const chatloomPresenceType = 'com.chatloom.presence';

/// A parsed `com.chatloom.presence` value:
/// `{"presence":"online|offline","last_active_ts":ms,
///   "precision":"exact|recently|week|month","source":"telegram"}`.
///
/// For `online` and exact `offline`, [lastActive] is when the contact was
/// last seen (for online: when the bridge last observed it). For coarse
/// precision it is only when the bridge observed the bucket and is never
/// shown as a time.
class BridgePresence {
  const BridgePresence({
    required this.online,
    required this.lastActive,
    required this.precision,
    this.source,
  });

  final bool online;
  final DateTime lastActive;
  final PresencePrecision precision;
  final String? source;

  /// Parses permissively; anything malformed is no data (null).
  static BridgePresence? tryParse(Map<String, Object?>? content) {
    if (content == null) return null;
    final presence = content['presence'];
    final ts = content['last_active_ts'];
    if (presence != 'online' && presence != 'offline') return null;
    if (ts is! int || ts <= 0) return null;
    final precision = switch (content['precision']) {
      null || 'exact' => PresencePrecision.exact,
      'recently' => PresencePrecision.recently,
      'week' => PresencePrecision.week,
      'month' => PresencePrecision.month,
      _ => null,
    };
    if (precision == null) return null;
    final source = content['source'];
    return BridgePresence(
      online: presence == 'online',
      lastActive: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      precision: presence == 'online' ? PresencePrecision.exact : precision,
      source: source is String ? source : null,
    );
  }
}

/// A Telegram-style presence line and the moment its wording next changes.
typedef PresenceLabel = ({String text, DateTime? refreshAt});

/// "online", "last seen just now", "last seen 5 min ago",
/// "last seen today at 14:03", "last seen yesterday at 14:03",
/// "last seen Oct 12 at 14:03" or "last seen Oct 12, 2025"; coarse buckets
/// read "last seen recently", "last seen within a week" or "last seen within
/// a month".
///
/// Returns null without data: silence never becomes "offline".
PresenceLabel? presenceLabel({
  required bool online,
  required DateTime? lastActive,
  required DateTime now,
  required bool use24h,
  PresencePrecision precision = PresencePrecision.exact,
}) {
  if (online) return (text: 'online', refreshAt: null);
  switch (precision) {
    case PresencePrecision.recently:
      return (text: 'last seen recently', refreshAt: null);
    case PresencePrecision.week:
      return (text: 'last seen within a week', refreshAt: null);
    case PresencePrecision.month:
      return (text: 'last seen within a month', refreshAt: null);
    case PresencePrecision.exact:
      break;
  }
  final raw = lastActive;
  if (raw == null) return null;
  final at = raw.toLocal();
  final local = now.toLocal();
  if (at.isAfter(local)) return null;
  final elapsed = local.difference(at);
  if (elapsed < const Duration(minutes: 1)) {
    return (
      text: 'last seen just now',
      refreshAt: at.add(const Duration(minutes: 1)),
    );
  }
  if (elapsed < const Duration(hours: 1)) {
    final minutes = elapsed.inMinutes;
    return (
      text: 'last seen $minutes min ago',
      refreshAt: at.add(Duration(minutes: minutes + 1)),
    );
  }
  final time = DateFormat(use24h ? 'HH:mm' : 'h:mm a', 'en_US').format(at);
  // Calendar days in UTC so a DST shift cannot turn yesterday into today.
  final days = DateTime.utc(
    local.year,
    local.month,
    local.day,
  ).difference(DateTime.utc(at.year, at.month, at.day)).inDays;
  final tomorrow = DateTime(local.year, local.month, local.day + 1);
  if (days == 0) {
    return (text: 'last seen today at $time', refreshAt: tomorrow);
  }
  if (days == 1) {
    return (text: 'last seen yesterday at $time', refreshAt: tomorrow);
  }
  if (at.year == local.year) {
    final date = DateFormat.MMMd('en_US').format(at);
    return (text: 'last seen $date at $time', refreshAt: null);
  }
  return (
    text: 'last seen ${DateFormat.yMMMd('en_US').format(at)}',
    refreshAt: null,
  );
}
