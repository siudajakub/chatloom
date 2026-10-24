// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// The chat's disappearing-message timer for people (FX-13): "1 day",
/// "1 week", "8 hours", "1 day after reading", or "On" when the network
/// says the timer is on without a readable duration. Null when it is off or
/// the room state is not loaded (only the chat header and its details,
/// whose room is loaded, show it). Read-only: setting the timer changes the
/// chat for everyone and is not offered.
String? disappearingTimerLabel(Room room) {
  final content = room.getState(beeperDisappearingTimerKey)?.content;
  return disappearingTimerLabelOf(content);
}

/// [disappearingTimerLabel] for a raw `com.beeper.disappearing_timer` value.
String? disappearingTimerLabelOf(Object? content) {
  if (content == null ||
      disappearingTimerState(content) == DisappearingTimerState.off) {
    return null;
  }
  final timer = content is Map ? content['timer'] : null;
  final type = content is Map ? content['type'] : null;
  if (timer is! num || timer <= 0 || timer.isNaN || timer.isInfinite) {
    return 'On';
  }
  final label = disappearingDurationLabel(
    Duration(milliseconds: timer.round()),
  );
  return type == 'after_read' ? '$label after reading' : label;
}

/// "1 week", "3 days", "8 hours", "5 minutes", "30 seconds".
String disappearingDurationLabel(Duration duration) {
  String unit(int count, String name) => '$count $name${count == 1 ? '' : 's'}';
  final seconds = duration.inSeconds;
  if (seconds >= Duration.secondsPerDay * 7 &&
      seconds % (Duration.secondsPerDay * 7) == 0) {
    return unit(seconds ~/ (Duration.secondsPerDay * 7), 'week');
  }
  if (seconds >= Duration.secondsPerDay &&
      seconds % Duration.secondsPerDay == 0) {
    return unit(seconds ~/ Duration.secondsPerDay, 'day');
  }
  if (seconds >= Duration.secondsPerHour) {
    return unit((seconds / Duration.secondsPerHour).round(), 'hour');
  }
  if (seconds >= Duration.secondsPerMinute) {
    return unit((seconds / Duration.secondsPerMinute).round(), 'minute');
  }
  return unit(seconds < 1 ? 1 : seconds, 'second');
}
