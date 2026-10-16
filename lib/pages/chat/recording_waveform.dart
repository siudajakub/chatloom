// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

/// Retains the whole recording's envelope with a bounded number of peaks.
/// Older equal-width buckets are merged in pairs as a recording grows.
class RecordingWaveform {
  static const maxPeaks = 1024;
  final List<double> _peaks = [];
  int _bucketSize = 1, _pendingSamples = 0;
  double _pendingPeak = 0;

  int get retainedPeaks => _peaks.length + (_pendingSamples > 0 ? 1 : 0);

  void add(double amplitude) {
    final value = amplitude.isFinite ? amplitude.clamp(0.0, 100.0) : 0.0;
    _pendingPeak = math.max(_pendingPeak, value);
    if (++_pendingSamples < _bucketSize) return;
    _peaks.add(_pendingPeak);
    _pendingPeak = 0;
    _pendingSamples = 0;
    if (_peaks.length < maxPeaks) return;
    for (var index = 0; index < _peaks.length ~/ 2; index++) {
      _peaks[index] = math.max(_peaks[index * 2], _peaks[index * 2 + 1]);
    }
    _peaks.length = _peaks.length ~/ 2;
    _bucketSize *= 2;
  }

  List<int> samples({required int count}) {
    if (count <= 0) return const [];
    final values = [..._peaks, if (_pendingSamples > 0) _pendingPeak];
    if (values.isEmpty) return const [];
    final length = math.min(count, values.length);
    return List.generate(length, (index) {
      final start = index * values.length ~/ length;
      final end = (index + 1) * values.length ~/ length;
      var peak = 0.0;
      for (var sample = start; sample < end; sample++) {
        peak = math.max(peak, values[sample]);
      }
      return (peak / 100 * 1024).round().clamp(0, 1024);
    });
  }

  void clear() {
    _peaks.clear();
    _bucketSize = 1;
    _pendingSamples = 0;
    _pendingPeak = 0;
  }
}
