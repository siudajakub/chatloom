// SPDX-License-Identifier: AGPL-3.0-or-later
/// Private, explicitly requested voice-to-text drafts. No recipient belongs
/// in this protocol: only the composer sends the reviewed text.
abstract final class DictationLimits {
  static const maxDuration = Duration(minutes: 5);
  static const maxBytes = 10 * 1024 * 1024;
  static const dailyBudgetUsd = 0.50;
  static const sourceLifetime = Duration(minutes: 15);
  static const sourceMarker = 'com.chatloom.dictation';
  static bool validId(Object? id) =>
      id is String && RegExp(r'^dictation-[a-zA-Z0-9-]{1,80}$').hasMatch(id);
}
