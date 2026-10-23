// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

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
  StreamSubscription<CachedPresence>? _sub;
  Client? _client;
  String? _userId;
  int _generation = 0;

  void _updatePresence(CachedPresence? presence) {
    if (!mounted) return;
    setState(() {
      _presence = presence;
    });
  }

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
    final generation = ++_generation;
    unawaited(_sub?.cancel());
    _sub = null;
    if (userId != null) {
      var live = false;
      _sub = client.onPresenceChanged.stream
          .where((presence) => presence.userid == userId)
          .listen((presence) {
            if (generation != _generation) return;
            live = true;
            _updatePresence(presence);
          });
      // Opening a profile must not cause a new presence query. A slower
      // database result also must not overwrite a newer sync event/account.
      unawaited(
        client.fetchCurrentPresence(userId, fetchOnlyFromCached: true).then((
          presence,
        ) {
          if (mounted && generation == _generation && !live) {
            _updatePresence(presence);
          }
        }, onError: (Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    _generation++;
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _presence);
}
