// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/ui/notion/notion.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:material_ui/material_ui.dart';

import 'round_capture_controller.dart';

/// The composer's record button in video mode, with Telegram's gestures:
///
/// * a quick tap (released before [RoundCaptureGestureController.holdDelay])
///   switches back to voice messages ([onToggleMode]);
/// * holding records a round video; the pointer keeps driving the
///   [RoundCaptureGestureController] while the recorder route is on top:
///   slide toward the start edge to cancel, swipe up to lock, release to send.
///
/// Without [onToggleMode] a tap records hands-free. Screen readers always get
/// hands-free recording on activation and a separate "switch" action.
class RoundRecordButton extends StatefulWidget {
  final Future<void> Function(RoundCaptureGestureController gesture) onRecord;
  final VoidCallback? onToggleMode;
  const RoundRecordButton({
    super.key,
    required this.onRecord,
    this.onToggleMode,
  });
  @override
  State<RoundRecordButton> createState() => _RoundRecordButtonState();
}

class _RoundRecordButtonState extends State<RoundRecordButton> {
  RoundCaptureGestureController? _gesture;
  Timer? _holdTimer;
  int? _pointer;
  Offset _origin = Offset.zero;
  bool _busy = false;
  bool _heldPointerActive = false;
  bool _pressed = false;
  static const double _size = 56;
  static const double _spinnerSize = 22;

  Future<void> _begin(bool held) async {
    if (_busy || !mounted) return;
    _busy = true;
    _heldPointerActive = held;
    final box = context.findRenderObject() as RenderBox?;
    final anchor = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final gesture = RoundCaptureGestureController(
      held: true,
      anchor: anchor,
      cancelDistance: RoundCaptureGestureController.cancelDistanceFor(
        MediaQuery.sizeOf(context).width,
      ),
    );
    if (!held) gesture.lock();
    _gesture = gesture;
    setState(() {});
    try {
      await widget.onRecord(gesture);
    } finally {
      if (identical(_gesture, gesture)) _gesture = null;
      gesture.dispose();
      _busy = false;
      _heldPointerActive = false;
      _pressed = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _gesture?.cancel();
    super.dispose();
  }

  /// Visual press feedback only.
  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  void _down(PointerDownEvent event) {
    if (_busy || _pointer != null || event.buttons & kPrimaryButton == 0) {
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _setPressed(true);
    _holdTimer = Timer(RoundCaptureGestureController.holdDelay, () {
      _holdTimer = null;
      if (_pointer != null) unawaited(_begin(true));
    });
  }

  void _move(PointerMoveEvent event) {
    final gesture = _gesture;
    if (event.pointer != _pointer || gesture == null || !_heldPointerActive) {
      return;
    }
    final delta = event.position - _origin;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final before = gesture.phase;
    gesture.move(dx: rtl ? -delta.dx : delta.dx, dy: delta.dy);
    if (before == RoundCaptureGesturePhase.holding &&
        gesture.phase == RoundCaptureGesturePhase.locked) {
      // Telegram ticks when the recording locks.
      NotionHaptics.longPress();
    }
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _setPressed(false);
    final timer = _holdTimer;
    if (timer != null) {
      timer.cancel();
      _holdTimer = null;
      final toggle = widget.onToggleMode;
      if (toggle != null) {
        NotionHaptics.longPress();
        toggle();
      } else {
        unawaited(_begin(false));
      }
      return;
    }
    if (_heldPointerActive) _gesture?.release();
    _heldPointerActive = false;
  }

  void _cancelPointer(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _holdTimer?.cancel();
    _holdTimer = null;
    _setPressed(false);
    if (_heldPointerActive) _gesture?.interrupt();
    _heldPointerActive = false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = !_busy && _pressed || _heldPointerActive;
    final duration = NotionMotion.of(context, NotionMotion.quick);
    final toggle = widget.onToggleMode;
    return Semantics(
      label:
          'Record a round video. Hold to record and release to send, '
          'slide up to lock.'
          '${toggle == null ? '' : ' Tap to switch to voice messages.'}',
      button: true,
      enabled: !_busy,
      onTap: _busy ? null : () => unawaited(_begin(false)),
      customSemanticsActions: toggle == null || _busy
          ? null
          : {
              const CustomSemanticsAction(label: 'Switch to voice messages'):
                  toggle,
            },
      excludeSemantics: true,
      child: Tooltip(
        message: 'Record a round video',
        // Long press records; the tooltip must never cover the capture.
        triggerMode: TooltipTriggerMode.manual,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _cancelPointer,
          child: GestureDetector(
            // Claims drags so a page gesture cannot steal the hold.
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {},
            child: SizedBox.square(
              dimension: _size,
              child: Center(
                child: _busy && !_heldPointerActive
                    ? const SizedBox.square(
                        dimension: _spinnerSize,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : AnimatedScale(
                        // Same press feedback as the voice button.
                        scale: active ? 1.12 : 1,
                        duration: duration,
                        child: AnimatedContainer(
                          duration: duration,
                          width: NotionSize.touchTarget,
                          height: NotionSize.touchTarget,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: active
                                ? colors.onSurface
                                : colors.onSurface.withAlpha(0),
                          ),
                          child: Icon(
                            Icons.videocam_outlined,
                            size: NotionSize.iconLg,
                            color: active ? colors.surface : colors.onSurface,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
