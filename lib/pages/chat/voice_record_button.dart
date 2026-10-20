// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton, kTouchSlop;
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:material_ui/material_ui.dart';

import 'conversation_motion.dart';
import 'notion_conversation.dart' show notionAudioTime;

/// Geometry of the held-recording affordances drawn above the composer.
abstract final class VoiceRecordLayout {
  /// The mic fill grows to this scale while held (drawn in the overlay, so
  /// the composer's glass clip never cuts it).
  static const double heldScale = 1.6;

  /// Lock pill above the mic: lock glyph over a chevron pointing up.
  static const double lockPillWidth = 36;
  static const double lockPillHeight = 72;

  /// Space between the held (scaled) mic and the pill.
  static const double lockGap = NotionSpace.xl;

  /// How far the pill follows the finger toward the lock.
  static const double lockTravel = NotionSpace.md;

  static const Duration enter = NotionMotion.quick;
}

enum VoiceRecordPhase {
  /// Nothing is held.
  idle,

  /// The pointer is down and the recorder is still starting.
  starting,

  /// The recorder runs while the pointer is held.
  holding,

  /// Hands-free: the caller's full recording controls take over.
  locked,

  /// A held recording was released for sending.
  released,

  /// The hold was cancelled or too short; nothing is sent.
  canceled,
}

/// Shared hold state between the composer's primary button and the overlay
/// that covers the field while a voice message is held.
///
/// Telegram's thresholds, shared with [RoundCaptureGestureController]
/// (lib/personal/round_video/round_capture_controller.dart): sliding
/// [cancelDistance] toward the start edge cancels, releasing past
/// [releaseCancelProgress] of it cancels, [lockDistance] up locks (ignored
/// once slid past [lockMaxCancelProgress]), release sends. It adds a minimum
/// length.
class VoiceRecordHold extends ChangeNotifier {
  /// Slide-to-cancel travel: 35 % of the layout width, at most 140 dp.
  static const double maxCancelDistance = 140;
  static const double lockDistance = 57;

  /// Releasing after sliding further than this fraction cancels.
  static const double releaseCancelProgress = 0.55;

  /// Locking is ignored once slid further than this fraction.
  static const double lockMaxCancelProgress = 0.3;

  static double cancelDistanceFor(double width) {
    final fraction = width * 0.35;
    return fraction > 0 && fraction < maxCancelDistance
        ? fraction
        : maxCancelDistance;
  }

  /// Set by the button from the layout width when a hold starts.
  double cancelDistance = maxCancelDistance;

  /// Shorter held recordings are discarded instead of sent.
  static const Duration minimumDuration = Duration(milliseconds: 800);

  VoiceRecordPhase _phase = VoiceRecordPhase.idle;
  double _dx = 0, _dy = 0;
  final Stopwatch _clock = Stopwatch();
  bool _disposed = false;

  VoiceRecordPhase get phase => _phase;

  /// True while the finger holds the button (the composer stays visible).
  bool get capturing =>
      _phase == VoiceRecordPhase.starting || _phase == VoiceRecordPhase.holding;

  /// Time recorded since the recorder actually started.
  Duration get elapsed => _clock.elapsed;

  /// Reading-direction offset toward cancel (negative) clamped to the limit.
  double get cancelOffset => _dx.clamp(-cancelDistance, 0).toDouble();
  double get cancelProgress => (-_dx / cancelDistance).clamp(0, 1).toDouble();
  double get lockProgress => (-_dy / lockDistance).clamp(0, 1).toDouble();

  /// Whether lifting the finger now discards instead of sending.
  bool get releaseCancels => cancelProgress > releaseCancelProgress;
  bool get canLock => cancelProgress <= lockMaxCancelProgress;

  void _set(VoiceRecordPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    if (phase != VoiceRecordPhase.holding) _clock.stop();
    if (!capturing) _dx = _dy = 0;
    if (!_disposed) notifyListeners();
  }

  void begin({bool locked = false}) {
    if (_phase != VoiceRecordPhase.idle) return;
    _clock
      ..stop()
      ..reset();
    _set(locked ? VoiceRecordPhase.locked : VoiceRecordPhase.starting);
  }

  /// The recorder confirmed it is running.
  void started() {
    if (_phase != VoiceRecordPhase.starting) return;
    _clock
      ..reset()
      ..start();
    _set(VoiceRecordPhase.holding);
  }

  /// [dx] is in reading direction: negative moves toward the start edge.
  void drag(double dx, double dy) {
    if (!capturing) return;
    _dx = dx;
    _dy = dy;
    if (!_disposed) notifyListeners();
  }

  void lock() {
    if (capturing) _set(VoiceRecordPhase.locked);
  }

  void release() {
    if (_phase == VoiceRecordPhase.holding) _set(VoiceRecordPhase.released);
  }

  void cancel() {
    if (capturing) _set(VoiceRecordPhase.canceled);
  }

  void reset() => _set(VoiceRecordPhase.idle);

  /// Silent reset for a newly mounted button after the hold already ended.
  void settle() {
    if (capturing) return;
    _phase = VoiceRecordPhase.idle;
    _dx = _dy = 0;
  }

  @override
  void dispose() {
    _disposed = true;
    _clock.stop();
    super.dispose();
  }
}

/// Primary composer action when the editor is empty, with Telegram's
/// gestures: hold to record, release to send (at least
/// [VoiceRecordHold.minimumDuration]), slide toward the start edge to cancel,
/// slide up to lock.
///
/// With [onToggleMode] (round video is available) recording starts only after
/// [holdDelay]; a quicker tap switches to video messages instead. Without it
/// recording starts on touch, and a quick tap is discarded with [onTapHint].
/// Screen readers start hands-free recording on activation.
class VoiceRecordButton extends StatefulWidget {
  final VoiceRecordHold hold;

  /// Starts the recorder; completes with whether it is actually recording.
  final Future<bool> Function() onStart;

  /// Stops and sends the held recording.
  final Future<void> Function() onSend;

  /// Discards the recording without sending anything.
  final VoidCallback onCancel;

  /// The recorder's own clock; defaults to the hold clock. Start, send and
  /// cancel feedback belongs to the recorder, only locking clicks here.
  final Duration Function()? recorded;
  final bool enabled;

  /// Tap switches the composer to round video messages.
  final VoidCallback? onToggleMode;

  /// A quick tap recorded nothing: explain how to record.
  final VoidCallback? onTapHint;

  /// A press released sooner than this without moving counts as a tap.
  static const Duration tapTimeout = Duration(milliseconds: 250);

  /// With [onToggleMode], a press held this long records (Telegram: 150 ms).
  static const Duration holdDelay = Duration(milliseconds: 150);

  const VoiceRecordButton({
    super.key,
    required this.hold,
    required this.onStart,
    required this.onSend,
    required this.onCancel,
    this.recorded,
    this.enabled = true,
    this.onToggleMode,
    this.onTapHint,
  });

  @override
  State<VoiceRecordButton> createState() => _VoiceRecordButtonState();
}

class _VoiceRecordButtonState extends State<VoiceRecordButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  int? _pointer;
  Offset _origin = Offset.zero;
  Duration _downAt = Duration.zero;
  bool _moved = false;
  bool _running = false;
  Timer? _holdTimer;

  VoiceRecordHold get _hold => widget.hold;

  Duration _recorded() => widget.recorded?.call() ?? _hold.elapsed;

  @override
  void initState() {
    super.initState();
    _hold.settle();
    _hold.addListener(_syncPortal);
    if (_hold.capturing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncPortal());
    }
  }

  @override
  void didUpdateWidget(VoiceRecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.hold, widget.hold)) {
      oldWidget.hold.removeListener(_syncPortal);
      widget.hold.addListener(_syncPortal);
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncPortal());
    }
  }

  /// Shows the held mic and lock pill only while the finger holds.
  void _syncPortal() {
    if (!mounted || _hold.capturing == _portal.isShowing) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncPortal());
      return;
    }
    _hold.capturing ? _portal.show() : _portal.hide();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _hold.removeListener(_syncPortal);
    if (_hold.capturing) {
      final hold = _hold;
      final cancel = widget.onCancel;
      final running = _running;
      // Never notify listeners while this tree is being finalized. A start
      // that is still pending sees the cancelled phase and discards itself.
      scheduleMicrotask(() {
        if (!hold.capturing) return;
        hold.cancel();
        if (running) {
          cancel();
          hold.reset();
        }
      });
    }
    super.dispose();
  }

  Future<void> _start() async {
    var ok = false;
    try {
      ok = await widget.onStart();
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      _running = false;
      _hold.reset();
      return;
    }
    _running = true;
    switch (_hold.phase) {
      case VoiceRecordPhase.starting:
        _hold.started();
      case VoiceRecordPhase.canceled:
        _discard();
      case VoiceRecordPhase.locked:
      case VoiceRecordPhase.idle:
      case VoiceRecordPhase.holding:
      case VoiceRecordPhase.released:
        break;
    }
  }

  void _discard() {
    _hold.cancel();
    if (_running) widget.onCancel();
    _running = false;
    _hold.reset();
  }

  void _down(PointerDownEvent event) {
    if (!widget.enabled ||
        _pointer != null ||
        _hold.phase != VoiceRecordPhase.idle ||
        event.buttons & kPrimaryButton == 0) {
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _moved = false;
    _downAt = event.timeStamp;
    _hold.cancelDistance = VoiceRecordHold.cancelDistanceFor(
      MediaQuery.sizeOf(context).width,
    );
    if (widget.onToggleMode != null) {
      // Telegram waits before recording so a tap can switch the mode.
      _holdTimer = Timer(VoiceRecordButton.holdDelay, _beginHold);
    } else {
      _beginHold();
    }
  }

  void _beginHold() {
    _holdTimer = null;
    if (_pointer == null || !mounted || _hold.phase != VoiceRecordPhase.idle) {
      return;
    }
    _hold.begin();
    unawaited(_start());
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer || !_hold.capturing) return;
    final delta = event.position - _origin;
    if (delta.distance > kTouchSlop) _moved = true;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final dx = rtl ? -delta.dx : delta.dx;
    _hold.drag(dx, delta.dy);
    if (-dx >= _hold.cancelDistance) {
      _pointer = null;
      if (_hold.phase == VoiceRecordPhase.holding) {
        _discard();
      } else {
        _hold.cancel();
      }
    } else if (-delta.dy >= VoiceRecordHold.lockDistance && _hold.canLock) {
      _pointer = null;
      NotionHaptics.longPress();
      _hold.lock();
    }
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    if (_holdTimer != null) {
      _holdTimer!.cancel();
      _holdTimer = null;
      NotionHaptics.longPress();
      widget.onToggleMode?.call();
      return;
    }
    final tap =
        !_moved && event.timeStamp - _downAt < VoiceRecordButton.tapTimeout;
    switch (_hold.phase) {
      case VoiceRecordPhase.starting:
        // The recorder is not ready yet: nothing worth sending.
        _hold.cancel();
        if (tap) widget.onTapHint?.call();
      case VoiceRecordPhase.holding:
        if (_hold.releaseCancels) {
          _discard();
        } else if (_recorded() >= VoiceRecordHold.minimumDuration) {
          _hold.release();
          _running = false;
          unawaited(
            widget.onSend().whenComplete(() {
              if (_hold.phase == VoiceRecordPhase.released) _hold.reset();
            }),
          );
        } else {
          // Too short: discarded silently, like Telegram.
          _discard();
          if (tap) widget.onTapHint?.call();
        }
      case VoiceRecordPhase.idle:
      case VoiceRecordPhase.locked:
      case VoiceRecordPhase.released:
      case VoiceRecordPhase.canceled:
        break;
    }
  }

  /// The system took the pointer. Unlike Telegram (which locks), a voice
  /// hold is discarded so the microphone never keeps running unnoticed.
  void _cancelPointer(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_hold.phase == VoiceRecordPhase.holding) {
      _discard();
    } else {
      _hold.cancel();
    }
  }

  void _tapHandsFree() {
    if (!widget.enabled || _hold.phase != VoiceRecordPhase.idle) return;
    _hold.begin(locked: true);
    unawaited(_start());
  }

  // Claims horizontal and vertical drags so a page gesture cannot steal them.
  void _claim(DragStartDetails _) {}

  /// Held mic (scaled fill) and the lock pill above it. Painted in the
  /// overlay so neither is clipped; it takes no hits and adds no semantics.
  Widget _heldOverlay(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduced = ConversationMotion.reduced(context);
    const height =
        VoiceRecordLayout.lockPillHeight +
        VoiceRecordLayout.lockGap +
        NotionSize.touchTarget;
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomCenter,
        followerAnchor: Alignment.bottomCenter,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: reduced ? 1 : 0, end: 1),
              duration: reduced ? Duration.zero : VoiceRecordLayout.enter,
              curve: NotionMotion.emphasized,
              builder: (context, enter, _) => SizedBox(
                width: NotionSize.touchTarget,
                height: height,
                child: Column(
                  children: [
                    ListenableBuilder(
                      listenable: _hold,
                      builder: (context, _) =>
                          _LockPill(progress: _hold.lockProgress, enter: enter),
                    ),
                    const SizedBox(height: VoiceRecordLayout.lockGap),
                    // Telegram: the held circle follows the finger toward
                    // cancel and shrinks to 70 % at the cancel distance.
                    ListenableBuilder(
                      listenable: _hold,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(
                          Directionality.of(context) == TextDirection.rtl
                              ? -_hold.cancelOffset
                              : _hold.cancelOffset,
                          0,
                        ),
                        child: Transform.scale(
                          scale:
                              (1 + (VoiceRecordLayout.heldScale - 1) * enter) *
                              (1 - 0.3 * _hold.cancelProgress),
                          child: child,
                        ),
                      ),
                      child: SizedBox.square(
                        dimension: NotionSize.touchTarget,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.onSurface,
                          ),
                          child: Icon(
                            Icons.mic_none_outlined,
                            size: NotionSize.iconLg,
                            color: colors.surface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final toggle = widget.enabled ? widget.onToggleMode : null;
    return Semantics(
      container: true,
      button: true,
      enabled: widget.enabled,
      label:
          'Record a voice message. Hold to record and release to send, '
          'slide up to lock.'
          '${toggle == null ? '' : ' Tap to switch to video messages.'}',
      onTap: widget.enabled ? _tapHandsFree : null,
      customSemanticsActions: toggle == null
          ? null
          : {
              const CustomSemanticsAction(label: 'Switch to video messages'):
                  toggle,
            },
      excludeSemantics: true,
      child: Tooltip(
        message: 'Record a voice message',
        triggerMode: TooltipTriggerMode.manual,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _cancelPointer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: widget.enabled ? _claim : null,
            child: CompositedTransformTarget(
              link: _link,
              child: OverlayPortal(
                controller: _portal,
                overlayChildBuilder: _heldOverlay,
                child: ListenableBuilder(
                  listenable: _hold,
                  builder: (context, _) {
                    // While held the overlay draws the enlarged fill on top.
                    final active = _hold.capturing;
                    return SizedBox.square(
                      dimension: NotionSize.touchTarget,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active ? colors.onSurface : Colors.transparent,
                        ),
                        child: Icon(
                          Icons.mic_none_outlined,
                          size: NotionSize.iconLg,
                          color: !widget.enabled
                              ? Theme.of(context).disabledColor
                              : active
                              ? colors.surface
                              : colors.onSurface,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Telegram-style lock hint: a pill with a lock over a chevron pointing up.
/// It rises with the finger and the lock closes past half the distance.
class _LockPill extends StatelessWidget {
  final double progress;
  final double enter;
  const _LockPill({required this.progress, required this.enter});

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final locking = progress >= 0.5;
    return Opacity(
      opacity: enter,
      child: Transform.translate(
        offset: Offset(
          0,
          (1 - enter) * VoiceRecordLayout.lockGap -
              progress * VoiceRecordLayout.lockTravel,
        ),
        child: Container(
          key: const Key('voice_lock_pill'),
          width: VoiceRecordLayout.lockPillWidth,
          height: VoiceRecordLayout.lockPillHeight,
          decoration: ShapeDecoration(
            color: colors.surface,
            shape: StadiumBorder(side: BorderSide(color: colors.border)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Icon(
                locking ? Icons.lock_outline : Icons.lock_open_outlined,
                size: NotionSize.icon,
                color: locking ? colors.text : colors.textSecondary,
              ),
              Opacity(
                opacity: 1 - progress,
                child: Icon(
                  Icons.keyboard_arrow_up,
                  size: NotionSize.icon,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Covers the composer field while a voice message is held: recording dot,
/// elapsed time and "slide to cancel" that follows the finger. The lock hint
/// is the pill above the held mic ([VoiceRecordButton]).
class VoiceRecordHoldOverlay extends StatelessWidget {
  final VoiceRecordHold hold;
  final Duration duration;

  const VoiceRecordHoldOverlay({
    super.key,
    required this.hold,
    required this.duration,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final time = notionAudioTime(duration);
    return Semantics(
      container: true,
      label:
          'Recording voice message, $time. Release to send, slide '
          '${rtl ? 'right' : 'left'} to cancel, slide up to lock.',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.all(NotionSize.border),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: colors.surfaceContainer,
            shape: const StadiumBorder(),
          ),
          child: ListenableBuilder(
            listenable: hold,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
              child: Row(
                children: [
                  const RecordingDot(active: true),
                  const SizedBox(width: NotionSpace.xs),
                  Text(
                    time,
                    style: NotionType.callout.copyWith(
                      color: colors.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: NotionSpace.sm),
                  Expanded(
                    child: Opacity(
                      opacity: 1 - hold.cancelProgress,
                      child: Transform.translate(
                        offset: Offset(
                          rtl ? -hold.cancelOffset : hold.cancelOffset,
                          0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.chevron_left,
                              size: NotionSize.iconSm,
                              color: colors.onSurfaceVariant,
                            ),
                            Flexible(
                              child: Text(
                                'Slide to cancel',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NotionType.footnote.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Red "on air" indicator. It pulses while recording, is static under reduced
/// motion and turns neutral while paused.
class RecordingDot extends StatefulWidget {
  final bool active;
  const RecordingDot({super.key, required this.active});

  @override
  State<RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RecordingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final animate = widget.active && !ConversationMotion.reduced(context);
    if (animate) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_pulse),
      child: Container(
        key: const Key('voice_recording_dot'),
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: widget.active ? colors.danger : colors.textTertiary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
