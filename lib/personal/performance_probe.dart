// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Opt-in, numeric-only device measurements. Compiled out of normal builds.
abstract final class PersonalPerformanceProbe {
  static const enabled = bool.fromEnvironment('PERSONAL_PERFORMANCE_PROBE');
  static bool _installed = false;

  static void install() {
    if (!enabled || _installed) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback((frames) {
      emit('frames', {
        'ui': frames.map((f) => f.buildDuration.inMicroseconds).toList(),
        'raster': frames.map((f) => f.rasterDuration.inMicroseconds).toList(),
      });
    });
  }

  static void emit(String operation, Map<String, Object> counters) {
    if (!enabled) return;
    debugPrint(
      'PERSONAL_PERF ${jsonEncode({'operation': operation, ...counters})}',
    );
  }
}
