// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/pages/chat/events/waiting_message_view.dart';
import 'package:fluffychat/personal/encryption/e2ee_health.dart';
import 'package:fluffychat/personal/encryption/undecryptable_messages.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// "Waiting for this message" for an event this device cannot decrypt.
/// Shared by the ordinary and the merged conversation (both render through
/// `MessageContent`). Asks for the key once per session automatically and
/// offers "Try again" or "Verify session" when that is stuck.
class UndecryptableMessage extends StatefulWidget {
  final Event event;
  final Color textColor;

  const UndecryptableMessage(this.event, {super.key, required this.textColor});

  /// A key that arrived but leaves the message locked does not open it.
  static const keyApplyTimeout = Duration(seconds: 6);

  @override
  State<UndecryptableMessage> createState() => _UndecryptableMessageState();
}

class _UndecryptableMessageState extends State<UndecryptableMessage> {
  UndecryptableMessages? _tracker;
  ValueListenable<KeyRecoveryStage?>? _stage;
  Timer? _applyTimer;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(UndecryptableMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.event;
    final event = widget.event;
    if (old.eventId != event.eventId ||
        old.room.id != event.room.id ||
        !identical(old.room.client, event.room.client) ||
        old.content['session_id'] != event.content['session_id']) {
      _bind();
    }
  }

  void _bind() {
    _stage?.removeListener(_stageChanged);
    _applyTimer?.cancel();
    final tracker = _tracker = UndecryptableMessages.of(
      widget.event.room.client,
    );
    _stage = tracker.watch(widget.event)..addListener(_stageChanged);
    _stageChanged();
    final event = widget.event;
    // Rows are built during list layout; start (and announce) the request
    // after this frame so no other widget is marked dirty mid-layout.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.event, event)) {
        tracker.ensureRequested(event);
      }
    });
  }

  void _stageChanged() {
    _applyTimer?.cancel();
    if (_stage?.value != KeyRecoveryStage.keyReceived) return;
    final event = widget.event;
    // Still on screen this long after its key arrived: that key does not
    // open this message. A decrypted event replaces this widget instead.
    _applyTimer = Timer(UndecryptableMessage.keyApplyTimeout, () {
      if (mounted) _tracker?.keyDidNotApply(event);
    });
  }

  @override
  void dispose() {
    _stage?.removeListener(_stageChanged);
    _applyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stage = _stage;
    if (stage == null) return const SizedBox.shrink();
    return ValueListenableBuilder<KeyRecoveryStage?>(
      valueListenable: stage,
      builder: (context, value, _) => WaitingMessageView(
        stage: value,
        textColor: widget.textColor,
        onRetry: () => _tracker?.retry(widget.event),
        onVerify: () => unawaited(
          openEncryptionRecovery(context, widget.event.room.client),
        ),
      ),
    );
  }
}
