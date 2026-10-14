// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'round_capture_controller.dart';

class RoundRecordButton extends StatefulWidget {
  final Future<void> Function(RoundCaptureGestureController gesture) onRecord;
  const RoundRecordButton({super.key, required this.onRecord});
  @override
  State<RoundRecordButton> createState() => _RoundRecordButtonState();
}

class _RoundRecordButtonState extends State<RoundRecordButton> {
  RoundCaptureGestureController? _gesture;
  bool _busy = false;
  bool _heldPointerActive = false;
  Future<void> _begin(bool held) async {
    if (_busy) return;
    _busy = true;
    _heldPointerActive = held;
    final gesture = RoundCaptureGestureController(held: true);
    if (!held) gesture.lock();
    _gesture = gesture;
    if (mounted) setState(() {});
    try {
      await widget.onRecord(gesture);
    } finally {
      if (identical(_gesture, gesture)) _gesture = null;
      gesture.dispose();
      _busy = false;
      _heldPointerActive = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _gesture?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Record a video message. Hold to record or tap for hands-free recording.',
    button: true,
    enabled: !_busy,
    onTap: _busy ? null : () => unawaited(_begin(false)),
    child: Tooltip(
      message: 'Hold to record a round video',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _busy ? null : () => unawaited(_begin(false)),
        onLongPressStart: _busy ? null : (_) => unawaited(_begin(true)),
        onLongPressMoveUpdate: (details) => _gesture?.move(
          dx: details.offsetFromOrigin.dx,
          dy: details.offsetFromOrigin.dy,
        ),
        onLongPressEnd: (_) {
          if (_heldPointerActive) _gesture?.release();
          _heldPointerActive = false;
        },
        onLongPressCancel: () {
          if (_heldPointerActive) _gesture?.cancel();
          _heldPointerActive = false;
        },
        child: SizedBox(
          width: 56,
          height: 56,
          child: Center(
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.videocam_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
          ),
        ),
      ),
    ),
  );
}
