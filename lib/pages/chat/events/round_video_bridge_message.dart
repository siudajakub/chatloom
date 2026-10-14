// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/personal/transcript_panel.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'round_video_message.dart';

/// One persisted-state lookup per source/revision. Only the service can accept
/// reverse bridge state; untrusted content never controls unread/expiry here.
class RoundVideoBridgeMessage extends StatefulWidget {
  final Event event;
  final Color? textColor;
  final bool showTranscript;
  final List<Event> continuationQueue;
  const RoundVideoBridgeMessage(
    this.event, {
    super.key,
    this.textColor,
    this.showTranscript = true,
    this.continuationQueue = const [],
  });
  @override
  State<RoundVideoBridgeMessage> createState() =>
      _RoundVideoBridgeMessageState();
}

class _RoundVideoBridgeMessageState extends State<RoundVideoBridgeMessage> {
  late TelegramRoundService _service;
  Map<String, dynamic>? _state;
  bool _pending = true, _unavailable = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _service = TelegramRoundService.of(widget.event.room.client);
    _service.addListener(_refresh);
    unawaited(_load());
  }

  void _refresh() {
    final snapshot = _service.verifiedMediaStateSnapshot(widget.event);
    if (snapshot != null) {
      if (mounted) {
        setState(() {
          _state = snapshot;
          _pending = false;
          _unavailable = false;
        });
      }
      return;
    }
    // Service also notifies recording/upload progress. Keep a verified source
    // available while refreshing, then stop if its trusted state has changed.
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final state = await _service.mediaState(widget.event);
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = state;
        _pending = false;
        _unavailable = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _pending = false;
        _unavailable = true;
      });
    }
  }

  @override
  void didUpdateWidget(RoundVideoBridgeMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId ||
        oldWidget.event.room.id != widget.event.room.id ||
        !identical(oldWidget.event.room.client, widget.event.room.client)) {
      _service.removeListener(_refresh);
      _pending = true;
      _state = null;
      _unavailable = false;
      _bind();
    }
  }

  @override
  void dispose() {
    ++_generation;
    _service.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final policy = RoundMediaPolicy.fromContent(event.content);
    final ready = !_pending && !_unavailable && _state?['expired'] != true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RoundVideoMessage(
          event,
          textColor: widget.textColor,
          showThumbnail: AppSettings.showThumbnailsInTimeline.value,
          allowMutedAutoplay:
              AppSettings.autoplayImages.value &&
              AppSettings.showThumbnailsInTimeline.value,
          receipts: _service,
          isExpired: _state?['expired'] == true,
          sourceStatePending: _pending,
          sourceStateUnavailable: _unavailable,
          mediaUnread: _state?['media_unread'] == true,
          sourceAvailable: () =>
              _service.verifiedMediaStateSnapshot(event)?['expired'] != true,
          continuationQueue: widget.continuationQueue,
          onForward:
              ready && policy.canForward && _service.canNativeForward(event)
              ? (source) => _service.showForwardPicker(context, source)
              : null,
          onExport: ready && policy.canExport
              ? (source) => source.saveFile(context)
              : null,
        ),
        if (ready && widget.showTranscript && policy.canTranscribe)
          TranscriptPanel(event: event),
      ],
    );
  }
}
