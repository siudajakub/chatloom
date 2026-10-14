// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// A native rule remains source-authoritative, including after failed or
/// partially completed writes. A request acknowledgement is not a rule sync.
class NotionNotificationBinding<T extends Object> extends ChangeNotifier {
  final T Function() read;
  final Future<void> Function(T) write;
  bool busy = false;
  T? pending;
  String? error;
  bool _disposed = false;
  NotionNotificationBinding({required this.read, required this.write});
  T get value => read();
  bool get canEdit => !busy && pending == null;
  String? get status =>
      error ??
      (pending == null
          ? null
          : 'Waiting for the network to confirm the notification rule.');
  void refresh() {
    if (_disposed) return;
    if (pending != null && read() == pending) {
      pending = null;
      notifyListeners();
    }
  }

  Future<void> set(T value) async {
    if (_disposed || !canEdit || value == read()) return;
    busy = true;
    pending = value;
    error = null;
    notifyListeners();
    try {
      await write(value);
      if (_disposed) return;
      if (read() == value) pending = null;
    } catch (_) {
      if (_disposed) return;
      pending = null;
      error =
          'Could not finish changing notifications. Check the current rule and try again.';
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
