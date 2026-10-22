// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

/// Device measurements: numeric durations under fixed code labels only.
///
/// * Every [span]/[record] lands in a small in-memory summary (the last
///   [PerformanceSamples.capacity] samples per operation, at most
///   [maxOperations] operations), shown in Settings → Advanced → Performance.
///   Nothing is persisted or sent; a restart starts empty. The cost is one
///   [Stopwatch] and a list write per user action.
/// * Frame timings are collected only while [recordingFrames] is on (the
///   Performance page switch, or a `PERSONAL_PERFORMANCE_PROBE=true` build).
/// * `PERSONAL_PERFORMANCE_PROBE=true` builds additionally log every sample
///   and a frame summary every 5 s as `PERSONAL_PERF {json}` lines.
///
/// Labels are code constants (`chat_open.rows`), never account, room, event,
/// file or user names; values are milliseconds and counts.
abstract final class PersonalPerformanceProbe {
  static const enabled = bool.fromEnvironment('PERSONAL_PERFORMANCE_PROBE');

  /// Distinct operations kept; later new labels are dropped.
  static const maxOperations = 64;

  static bool _installed = false;
  static AppLifecycleListener? _lifecycle;

  /// Probe builds: frame summaries and lifecycle transitions from the start.
  static void install() {
    if (!enabled || _installed) return;
    _installed = true;
    recordFrames(true);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) => emit('lifecycle', {'state': state.name}),
    );
  }

  // ---------------------------------------------------------------- spans

  static final _operations = <String, PerformanceSamples>{};

  /// Starts timing [operation]; see [PerformanceSpan.mark].
  static PerformanceSpan span(String operation) => PerformanceSpan._(operation);

  /// Adds one sample of [operation].
  static void record(String operation, Duration elapsed) {
    final ms = elapsed.inMicroseconds / 1000;
    final samples =
        _operations[operation] ??
        (_operations.length < maxOperations
            ? _operations[operation] = PerformanceSamples()
            : null);
    samples?.add(ms);
    if (enabled) emit(operation, {'ms': _round(ms)});
  }

  /// Times [action] as [operation] (also when it throws).
  static Future<T> time<T>(String operation, Future<T> Function() action) {
    final watch = Stopwatch()..start();
    return action().whenComplete(() => record(operation, watch.elapsed));
  }

  static final _zoneKey = Object();

  /// Runs [body] with [span] as [currentSpan], so code reached from it
  /// (also asynchronously: the outbox transport, the SDK's local echo) can
  /// mark phases without knowing the caller.
  static R runInSpan<R>(PerformanceSpan span, R Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: span});

  /// The span of the enclosing [runInSpan], if any.
  static PerformanceSpan? get currentSpan {
    final span = Zone.current[_zoneKey];
    return span is PerformanceSpan ? span : null;
  }

  /// Runs [action] once the frame that shows the current change has been
  /// built (one is scheduled if none is pending); at once without a binding
  /// (background isolate).
  static void afterFrame(void Function() action) {
    try {
      SchedulerBinding.instance.endOfFrame.then((_) => action());
    } catch (_) {
      action();
    }
  }

  /// Summaries in first-recorded order.
  static List<PerformanceSummary> summaries() => [
    for (final entry in _operations.entries)
      if (entry.value.count > 0) entry.value.summary(entry.key),
  ];

  static final Stopwatch _sinceMain = Stopwatch();

  /// Startup timeline: milliseconds since the first mark (`main`). [phase] is
  /// a fixed code label, never an account, room or file name.
  static void startupPhase(String phase) {
    if (!_sinceMain.isRunning) _sinceMain.start();
    record('startup.$phase', _sinceMain.elapsed);
  }

  // --------------------------------------------------------------- frames

  static final frames = FrameRecorder();
  static final _window = FrameRecorder(capacity: 2048);
  static final _sinceEmit = Stopwatch();
  static bool _recordingFrames = false;

  /// Whether frame timings are being collected.
  static bool get recordingFrames => _recordingFrames;

  /// Starts or stops collecting frame timings (build and raster time per
  /// frame, reported by the engine; no extra frames are scheduled).
  static void recordFrames(bool on) {
    if (on == _recordingFrames) return;
    _recordingFrames = on;
    final binding = SchedulerBinding.instance;
    if (on) {
      _sinceEmit
        ..reset()
        ..start();
      binding.addTimingsCallback(_onTimings);
    } else {
      binding.removeTimingsCallback(_onTimings);
    }
  }

  static void _onTimings(List<FrameTiming> timings) {
    final budget = frameBudget();
    for (final timing in timings) {
      frames.add(timing, budget);
      if (enabled) _window.add(timing, budget);
    }
    // Summaries ride on the engine's own reports: an idle app reports no
    // frames and so emits nothing (no timer).
    if (enabled && _sinceEmit.elapsed >= const Duration(seconds: 5)) {
      final summary = _window.summary();
      if (summary != null) emit('frames', summary.toJson());
      _window.clear();
      _sinceEmit
        ..reset()
        ..start();
    }
  }

  /// One frame's time at the display's refresh rate (16.7 ms at 60 Hz,
  /// 8.3 ms at 120 Hz); 60 Hz when the platform does not report it.
  static Duration frameBudget() {
    var rate = 60.0;
    try {
      final reported =
          PlatformDispatcher.instance.displays.firstOrNull?.refreshRate;
      if (reported != null && reported >= 30 && reported <= 240) {
        rate = reported;
      }
    } catch (_) {}
    return Duration(microseconds: (1000000 / rate).round());
  }

  // --------------------------------------------------------------- output

  /// Clears every summary (the frame switch keeps its state).
  static void reset() {
    _operations.clear();
    frames.clear();
    _window.clear();
  }

  /// Plain-text summary for "Copy": labels, counts and milliseconds only.
  static String report() {
    final lines = <String>['ChatLoom performance summary'];
    final frameSummary = frames.summary();
    if (frameSummary != null) lines.add(frameSummary.describe());
    for (final summary in summaries()) {
      lines.add(summary.describe());
    }
    if (lines.length == 1) lines.add('No measurements yet.');
    return lines.join('\n');
  }

  static void emit(String operation, Map<String, Object> counters) {
    if (!enabled) return;
    debugPrint(
      'PERSONAL_PERF ${jsonEncode({'operation': operation, ...counters})}',
    );
  }

  @visibleForTesting
  static void debugReset() {
    reset();
    recordFrames(false);
    _lifecycle?.dispose();
    _lifecycle = null;
    _installed = false;
  }
}

/// One measured operation: phases are recorded as `operation.phase`.
class PerformanceSpan {
  PerformanceSpan._(this.operation) : _watch = Stopwatch()..start();

  final String operation;
  final Stopwatch _watch;
  final _marked = <String>{};
  bool _done = false;

  Duration get elapsed => _watch.elapsed;
  bool get done => _done;

  /// Records `operation.phase` with the time since the span started, once.
  void mark(String phase) {
    if (_done || !_marked.add(phase)) return;
    PersonalPerformanceProbe.record('$operation.$phase', _watch.elapsed);
  }

  /// Marks [phase] once the frame that shows the current change has been
  /// built (one is scheduled if none is pending).
  void markAfterFrame(String phase, {bool finish = false}) {
    if (_done || _marked.contains(phase)) return;
    PersonalPerformanceProbe.afterFrame(() {
      mark(phase);
      if (finish) _done = true;
    });
  }

  /// Marks [phase] and ends the span: later marks are ignored.
  void finish(String phase) {
    mark(phase);
    _done = true;
  }

  /// Ends the span without recording (the operation was abandoned).
  void cancel() => _done = true;
}

/// The last [capacity] samples (ms) of one operation, plus lifetime count
/// and maximum.
class PerformanceSamples {
  PerformanceSamples({this.capacity = 128});

  final int capacity;
  final _values = <double>[];
  int _next = 0;
  int count = 0;
  double max = 0;

  void add(double ms) {
    count++;
    if (ms > max) max = ms;
    if (_values.length < capacity) {
      _values.add(ms);
    } else {
      _values[_next] = ms;
      _next = (_next + 1) % capacity;
    }
  }

  /// Samples currently kept (at most [capacity]).
  int get kept => _values.length;

  PerformanceSummary summary(String name) {
    final sorted = [..._values]..sort();
    return PerformanceSummary(
      name: name,
      count: count,
      p50: percentile(sorted, 0.5),
      p90: percentile(sorted, 0.9),
      p99: percentile(sorted, 0.99),
      max: max,
    );
  }
}

/// Nearest-rank percentile of an ascending list; 0 for an empty list.
double percentile(List<double> sorted, double fraction) {
  if (sorted.isEmpty) return 0;
  final rank = (fraction * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

class PerformanceSummary {
  const PerformanceSummary({
    required this.name,
    required this.count,
    required this.p50,
    required this.p90,
    required this.p99,
    required this.max,
  });

  final String name;
  final int count;
  final double p50, p90, p99, max;

  Map<String, Object> toJson() => {
    'operation': name,
    'count': count,
    'p50_ms': _round(p50),
    'p90_ms': _round(p90),
    'p99_ms': _round(p99),
    'max_ms': _round(max),
  };

  String describe() =>
      '$name: n=$count p50=${formatMs(p50)} p90=${formatMs(p90)} '
      'p99=${formatMs(p99)} max=${formatMs(max)}';
}

/// Build and raster time of recent frames against the display's budget.
class FrameRecorder {
  FrameRecorder({this.capacity = 1200});

  final int capacity;
  final _build = <double>[];
  final _raster = <double>[];
  int _next = 0;
  int frames = 0;
  int missed = 0;
  double worstRaster = 0;
  Duration budget = const Duration(microseconds: 16667);

  void add(FrameTiming timing, Duration budget) => addDurations(
    build: timing.buildDuration,
    raster: timing.rasterDuration,
    budget: budget,
  );

  void addDurations({
    required Duration build,
    required Duration raster,
    required Duration budget,
  }) {
    this.budget = budget;
    frames++;
    if (build > budget || raster > budget) missed++;
    final b = build.inMicroseconds / 1000;
    final r = raster.inMicroseconds / 1000;
    if (r > worstRaster) worstRaster = r;
    if (_build.length < capacity) {
      _build.add(b);
      _raster.add(r);
    } else {
      _build[_next] = b;
      _raster[_next] = r;
      _next = (_next + 1) % capacity;
    }
  }

  void clear() {
    _build.clear();
    _raster.clear();
    _next = 0;
    frames = missed = 0;
    worstRaster = 0;
  }

  FrameSummary? summary() {
    if (frames == 0) return null;
    final build = [..._build]..sort();
    final raster = [..._raster]..sort();
    return FrameSummary(
      frames: frames,
      missed: missed,
      budgetMs: budget.inMicroseconds / 1000,
      buildP50: percentile(build, 0.5),
      buildP90: percentile(build, 0.9),
      buildP99: percentile(build, 0.99),
      rasterP50: percentile(raster, 0.5),
      rasterP90: percentile(raster, 0.9),
      rasterP99: percentile(raster, 0.99),
      worstRaster: worstRaster,
    );
  }
}

class FrameSummary {
  const FrameSummary({
    required this.frames,
    required this.missed,
    required this.budgetMs,
    required this.buildP50,
    required this.buildP90,
    required this.buildP99,
    required this.rasterP50,
    required this.rasterP90,
    required this.rasterP99,
    required this.worstRaster,
  });

  final int frames, missed;
  final double budgetMs;
  final double buildP50, buildP90, buildP99;
  final double rasterP50, rasterP90, rasterP99, worstRaster;

  Map<String, Object> toJson() => {
    'frames': frames,
    'missed_budget': missed,
    'budget_ms': _round(budgetMs),
    'build_p50_ms': _round(buildP50),
    'build_p90_ms': _round(buildP90),
    'build_p99_ms': _round(buildP99),
    'raster_p50_ms': _round(rasterP50),
    'raster_p90_ms': _round(rasterP90),
    'raster_p99_ms': _round(rasterP99),
    'worst_raster_ms': _round(worstRaster),
  };

  String describe() =>
      'frames: n=$frames missed=$missed budget=${formatMs(budgetMs)} '
      'build p50=${formatMs(buildP50)} p90=${formatMs(buildP90)} '
      'p99=${formatMs(buildP99)} raster p50=${formatMs(rasterP50)} '
      'p90=${formatMs(rasterP90)} p99=${formatMs(rasterP99)} '
      'worst=${formatMs(worstRaster)}';
}

double _round(double ms) => double.parse(ms.toStringAsFixed(2));

/// `0.4 ms`, `12 ms`, `1.2 s`.
String formatMs(double ms) {
  if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)} s';
  if (ms >= 10) return '${ms.round()} ms';
  return '${ms.toStringAsFixed(1)} ms';
}
