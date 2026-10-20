// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:flutter/foundation.dart';
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

  /// Lazily built playback continuation (only on an explicit play).
  final List<Event> Function()? continuationQueue;
  final bool outgoing;
  final Widget? statusOverlay;

  /// False where the round is already shown large (media viewer).
  final bool enlargeOnPlay;
  const RoundVideoBridgeMessage(
    this.event, {
    super.key,
    this.textColor,
    this.showTranscript = true,
    this.continuationQueue,
    this.outgoing = false,
    this.statusOverlay,
    this.enlargeOnPlay = true,
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
    // A state already loaded (also by a batched preload) renders at once,
    // without a pending frame.
    if (_service.isMediaStateKnown(widget.event)) {
      _state = _service.verifiedMediaStateSnapshot(widget.event);
      _pending = false;
    } else {
      unawaited(_load());
    }
  }

  void _apply(Map<String, dynamic>? state) {
    if (!mounted) return;
    if (!_pending && !_unavailable && mapEquals(state, _state)) return;
    setState(() {
      _state = state;
      _pending = false;
      _unavailable = false;
    });
  }

  /// The service also notifies capture/upload progress and other events'
  /// states; rebuild only when this event's verified state changed.
  void _refresh() {
    if (_service.isMediaStateKnown(widget.event)) {
      _apply(_service.verifiedMediaStateSnapshot(widget.event));
      return;
    }
    // Keep a verified source available while refreshing, then stop if its
    // trusted state has changed.
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final state = await _service.mediaState(widget.event);
      if (!mounted || generation != _generation) return;
      _apply(state);
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
      ++_generation;
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
    return RoundVideoMessage(
      event,
      textColor: widget.textColor,
      outgoing: widget.outgoing,
      statusOverlay: widget.statusOverlay,
      enlargeOnPlay: widget.enlargeOnPlay,
      showThumbnail: AppSettings.showThumbnailsInTimeline.value,
      // Muted previews would create a second native player per visible row;
      // only the round the user plays owns a controller.
      allowMutedAutoplay: false,
      receipts: _service,
      isExpired: _state?['expired'] == true,
      sourceStatePending: _pending,
      sourceStateUnavailable: _unavailable,
      mediaUnread: _state?['media_unread'] == true,
      sourceAvailable: () =>
          _service.verifiedMediaStateSnapshot(event)?['expired'] != true,
      continuationQueue: widget.continuationQueue,
      continuationUnread: (source) {
        final unread = _service.verifiedMediaStateSnapshot(
          source,
        )?['media_unread'];
        return unread is bool ? unread : null;
      },
      onForward: ready && policy.canForward && _service.canNativeForward(event)
          ? (source) => _service.showForwardPicker(context, source)
          : null,
      onExport: ready && policy.canExport
          ? (source) => source.saveFile(context)
          : null,
      below: ready && widget.showTranscript && policy.canTranscribe
          ? TranscriptPanel(event: event, foregroundColor: widget.textColor)
          : null,
    );
  }
}
