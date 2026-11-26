// SPDX-License-Identifier: AGPL-3.0-or-later
// Counts rebuilds of widgets that were already on screen while a measured
// interaction runs. `debugOnRebuildDirtyWidget`'s `builtOnce` argument is
// only tracked while `debugPrintRebuildDirtyWidgets` is on (otherwise it is
// always false), so it cannot tell a rebuild from a first build: the
// elements that exist before the window are snapshotted instead. Rows that
// scroll into view during the window are new elements and are not counted.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rebuilds, by widget type, of elements that existed before [body] ran.
Future<Map<Type, int>> countRebuilds(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final existing = tester.allElements.toSet();
  final counts = <Type, int>{};
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previous?.call(element, builtOnce);
    if (!existing.contains(element)) return;
    final type = element.widget.runtimeType;
    counts[type] = (counts[type] ?? 0) + 1;
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return counts;
}

/// The [top] most rebuilt types, for a failure message.
String describeRebuilds(Map<Type, int> counts, {int top = 12}) {
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.take(top).map((e) => '${e.key}: ${e.value}').join(', ');
}
