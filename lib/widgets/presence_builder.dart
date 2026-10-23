// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/conversation_activity.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class PresenceBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, CachedPresence? presence) builder;
  final String? userId;
  final Client? client;

  const PresenceBuilder({
    required this.builder,
    this.userId,
    this.client,
    super.key,
  });

  @override
  State<PresenceBuilder> createState() => _PresenceBuilderState();
}

class _PresenceBuilderState extends State<PresenceBuilder> {
  CachedPresence? _presence;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  ConversationActivityReceipts? _receipts;
  Timer? _expiry;
  Client? _client;
  String? _userId;
  static const _freshness = Duration(minutes: 5);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant PresenceBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
  }

  void _bind() {
    final client = widget.client ?? Matrix.of(context).client;
    final userId = widget.userId;
    if (identical(client, _client) && userId == _userId) return;
    _client = client;
    _userId = userId;
    _presence = null;
    _detach();
    if (userId != null) {
      final receipts = ConversationActivityReceipts.of(client)..retain();
      _receipts = receipts;
      void changed([Object? _]) {
        if (mounted && identical(_receipts, receipts)) {
          setState(_refresh);
        }
      }

      _subscriptions.add(
        receipts.changes
            .where((id) => id == null || id == userId)
            .listen(changed),
      );
      _subscriptions.add(client.onRoomState.stream.listen(changed));
      _refresh();
    }
  }

  // The same provenance and receipt times as chat headers, with no HTTP or
  // database query when opening a profile or recycling a participant avatar.
  void _refresh() {
    _expiry?.cancel();
    final receipts = _receipts;
    final userId = _userId;
    if (receipts == null || userId == null) return;
    _presence = receipts.safeNativePresence(userId);
    final observation = receipts.observed[userId];
    if (_presence != null && observation != null) {
      final remaining = observation.$2
          .add(_freshness)
          .difference(DateTime.now());
      if (remaining > Duration.zero) {
        _expiry = Timer(remaining, () {
          if (mounted) setState(_refresh);
        });
      }
    }
  }

  void _detach() {
    _expiry?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _receipts?.release();
    _receipts = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _presence);
}
