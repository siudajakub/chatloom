// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// UI reports actual playback, never preload/autoplay or chat-read intent.
/// The implementation owns trusted capability, exact-source grant, encrypted
/// custom event transport and a request-time incognito check. No queued flush
/// when incognito changes, and no m.read or ordinary-message fallback.
abstract interface class RoundPlaybackReceipts {
  bool get incognito;
  bool canExplicitlyReport(Event event);
  Future<void> onUserStartedPlaying(Event event);
  Future<void> explicitlyReportPlayed(Event event);
}
