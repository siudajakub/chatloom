// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_network_adapter.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Holds the computed inbox of one account so builds, search keystrokes and
/// filter changes only select over cached records.
///
/// * Sync updates recompute only the rooms listed in `SyncUpdate.rooms`
///   (whole index for new/left rooms, merged persons, spaces or new bridges).
/// * Personal store changes rebuild the index (private metadata may affect
///   every record).
/// * A change to a quiet inbox (no refresh within [debounce]) is published
///   at once, so a single new message shows without delay. Changes right
///   after a refresh are coalesced: [debounce] after the last change, at
///   most [maxWait] after the first one.
/// * Sync status only notifies on error/recovered and first-sync transitions.
/// * While [active] is false (the inbox route is covered by a chat), changes
///   are only recorded; one refresh runs when the inbox is shown again.
class InboxController extends ChangeNotifier {
  final Client client;
  final PersonalClient personal;
  final Duration debounce;
  final Duration maxWait;
  InboxController(
    this.client,
    this.personal, {
    this.debounce = const Duration(milliseconds: 250),
    this.maxWait = const Duration(seconds: 1),
  }) {
    _failed = client.onSyncStatus.value?.status == SyncStatus.error;
    _loading = client.prevBatch == null;
    _subscriptions.addAll([
      client.onSync.stream.listen(_onSync, onError: (_) {}),
      client.onSyncStatus.stream.listen(_onStatus, onError: (_) {}),
      personal.changes.listen((_) => _mark(all: true), onError: (_) {}),
      client.onRoomState.stream.listen(_onRoomState, onError: (_) {}),
    ]);
  }

  /// A DM's name and avatar come from the partner's member event, which is
  /// often loaded lazily from the database after start (not via sync).
  void _onRoomState(({String roomId, StrippedStateEvent state}) update) {
    if (update.state.type != EventTypes.RoomMember) return;
    final partner = client
        .getRoomById(update.roomId)
        ?.directChatMatrixIDForDisplay;
    if (partner == null || partner != update.state.stateKey) return;
    _mark(rooms: [update.roomId]);
  }

  final _subscriptions = <StreamSubscription>[];
  final _changed = <String>{};
  bool _all = false, _touched = false, _detached = false;
  Timer? _timer;
  // Runs for [debounce] after each refresh: changes inside it are coalesced.
  Timer? _cooldown;
  // A refresh is already due at once (leading edge of a quiet inbox).
  bool _leading = false;
  DateTime? _firstPending;
  InboxIndex? _index;
  List<String> _networks = const [];
  bool _failed = false, _loading = true;

  /// Increments on every published change; part of selection memo keys.
  int generation = 0;

  /// Index (re)builds, incremental updates; performance tests.
  int debugFullBuilds = 0, debugIncrementalUpdates = 0;

  bool _active = true;
  bool get active => _active;
  set active(bool value) {
    if (_active == value) return;
    _active = value;
    if (value && _pending) {
      _leading = true;
      _schedule(Duration.zero);
    }
    if (!value) {
      _timer?.cancel();
      _timer = null;
      _leading = false;
    }
  }

  /// True once [detach] or [dispose] ran (no more subscriptions).
  bool get detached => _detached;

  bool get _pending => _all || _touched || _changed.isNotEmpty;

  /// True while the last sync attempt failed (shows the offline banner).
  bool get syncFailed => _failed;

  /// True until the first sync finished.
  bool get loading => client.prevBatch == null && !_failed;

  InboxIndex get index {
    final index = _index;
    if (index != null) return index;
    _rebuild();
    return _index!;
  }

  InboxProjection get projection => index.projection;

  /// Networks of non-technical chats, sorted by label.
  List<String> get networks {
    index;
    return _networks;
  }

  void _onSync(SyncUpdate sync) {
    final rooms = sync.rooms;
    final ids = <String>{
      ...?rooms?.join?.keys,
      ...?rooms?.invite?.keys,
      ...?rooms?.leave?.keys,
      ...?rooms?.knock?.keys,
    };
    final direct = sync.accountData?.any((e) => e.type == 'm.direct') == true;
    final firstSync = _loading && client.prevBatch != null;
    if (ids.isEmpty && !direct && !firstSync) {
      // Push rules and other account data are read live by visible rows.
      if (sync.accountData?.isNotEmpty == true) _mark(touch: true);
      return;
    }
    _mark(rooms: ids, all: direct, touch: firstSync);
  }

  void _onStatus(SyncStatusUpdate status) {
    final failed = status.status == SyncStatus.error;
    final loading = client.prevBatch == null;
    if (failed == _failed && loading == _loading) return;
    _failed = failed;
    _loading = loading;
    _mark(touch: true);
  }

  /// Records a change; [rooms] are refreshed individually, [all] rebuilds,
  /// [touch] only republishes (rows read live room data).
  void markChanged({
    Iterable<String> rooms = const [],
    bool all = false,
    bool touch = false,
  }) => _mark(rooms: rooms, all: all, touch: touch);

  void _mark({
    Iterable<String> rooms = const [],
    bool all = false,
    bool touch = false,
  }) {
    if (_detached) return;
    _changed.addAll(rooms);
    _all |= all;
    _touched |= touch;
    if (!_pending || !_active || _leading) return;
    if (_timer == null && _cooldown == null) {
      // Quiet inbox: publish this change in the next event-loop turn (which
      // still merges updates of the same sync) instead of after [debounce].
      _leading = true;
      _schedule(Duration.zero);
      return;
    }
    final now = DateTime.now();
    final first = _firstPending ??= now;
    final latest = first.add(maxWait);
    final due = now.add(debounce);
    _schedule((due.isAfter(latest) ? latest : due).difference(now));
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay.isNegative ? Duration.zero : delay, refresh);
  }

  /// Applies pending changes now (also used when the inbox becomes visible).
  void refresh() {
    _timer?.cancel();
    _timer = null;
    _firstPending = null;
    _leading = false;
    if (_detached || !_pending) return;
    _cooldown?.cancel();
    _cooldown = Timer(debounce, () => _cooldown = null);
    final changed = _changed.toList();
    final all = _all;
    _changed.clear();
    _all = _touched = false;
    final index = _index;
    if (index != null && !all && changed.isNotEmpty) {
      if (index.updateRooms(changed, client.rooms)) {
        debugIncrementalUpdates++;
        _networks = _computeNetworks(index);
      } else {
        _rebuild();
      }
    } else if (index != null && all) {
      _rebuild();
    }
    generation++;
    notifyListeners();
  }

  void _rebuild() {
    debugFullBuilds++;
    final index = InboxProjection.snapshot(personal).buildIndex(client.rooms);
    _index = index;
    _networks = _computeNetworks(index);
  }

  static List<String> _computeNetworks(InboxIndex index) {
    final projection = index.projection;
    final networks = <String>{};
    for (final room in index.rooms) {
      if (projection.classifier.classify(room).technical) continue;
      networks.addAll(notionRoomNetworks(projection, room));
    }
    return networks.toList()
      ..sort((a, b) => notionNetworkLabel(a).compareTo(notionNetworkLabel(b)));
  }

  /// Stops listening immediately; [dispose] may follow later (after the
  /// widgets that listen to it have been rebuilt).
  void detach() {
    if (_detached) return;
    _detached = true;
    _timer?.cancel();
    _timer = null;
    _cooldown?.cancel();
    _cooldown = null;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
