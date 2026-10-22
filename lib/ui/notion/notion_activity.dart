// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Stops decorative animation app-wide while the user is not looking at the
/// app (PF-08): another app has focus (macOS window unfocused, Android
/// notification shade or system dialog, the other half of split screen), or
/// the window is occluded, minimised or closed.
///
/// While inactive:
/// * `TickerMode` is off below it: loops (typing dots, shimmer, spinners,
///   pulses), animated GIF/WebP frames (`Image` pauses under `TickerMode`)
///   and every other ticker stop scheduling frames;
/// * [NotionMotion.reduced] is true, so one-shot Notion motion that starts
///   now (a new message's entrance, a reveal) jumps to its end state instead
///   of waiting, invisible, for the ticker; loops paint their static frame.
///
/// Sync, sending, timers, platform video/audio playback and textures do not
/// use tickers and keep running. Scrolling an unfocused macOS window (wheel
/// or trackpad, which macOS delivers without focus) re-enables tickers for
/// [pointerGrace], so flings and overscroll settle normally.
///
/// Mount once above the navigator (`MaterialApp.builder`).
class NotionActivity extends StatefulWidget {
  const NotionActivity({super.key, required this.child, this.windowVisible});

  final Widget child;

  /// Whether the native window is on screen (macOS occlusion/minimise);
  /// null where the lifecycle alone decides.
  final ValueListenable<bool>? windowVisible;

  /// How long pointer activity in an inactive window keeps animation on.
  static const pointerGrace = Duration(seconds: 3);

  /// Whether the app is in front of the user. True without a [NotionActivity]
  /// above [context] (tests, goldens).
  static bool isActive(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_NotionActivityScope>()
          ?.active ??
      true;

  @override
  State<NotionActivity> createState() => _NotionActivityState();
}

class _NotionActivityState extends State<NotionActivity> {
  late final AppLifecycleListener _lifecycle;
  AppLifecycleState? _state;
  bool _pointer = false;
  Timer? _pointerTimer;

  @override
  void initState() {
    super.initState();
    _state = WidgetsBinding.instance.lifecycleState;
    _lifecycle = AppLifecycleListener(onStateChange: _onState);
    widget.windowVisible?.addListener(_changed);
  }

  @override
  void didUpdateWidget(NotionActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.windowVisible != widget.windowVisible) {
      oldWidget.windowVisible?.removeListener(_changed);
      widget.windowVisible?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _pointerTimer?.cancel();
    widget.windowVisible?.removeListener(_changed);
    _lifecycle.dispose();
    super.dispose();
  }

  void _onState(AppLifecycleState state) {
    if (state == _state) return;
    setState(() => _state = state);
  }

  void _changed() => setState(() {});

  bool get _foreground =>
      (_state == null || _state == AppLifecycleState.resumed) &&
      (widget.windowVisible?.value ?? true);

  void _onPointer(PointerEvent _) {
    if (_foreground) return;
    _pointerTimer?.cancel();
    _pointerTimer = Timer(NotionActivity.pointerGrace, () {
      if (mounted) setState(() => _pointer = false);
    });
    if (!_pointer) setState(() => _pointer = true);
  }

  @override
  Widget build(BuildContext context) {
    final active = _foreground || _pointer;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointer,
      onPointerSignal: _onPointer,
      onPointerPanZoomStart: _onPointer,
      onPointerPanZoomUpdate: _onPointer,
      child: TickerMode(
        enabled: active,
        child: _NotionActivityScope(active: active, child: widget.child),
      ),
    );
  }
}

class _NotionActivityScope extends InheritedWidget {
  const _NotionActivityScope({required this.active, required super.child});

  final bool active;

  @override
  bool updateShouldNotify(_NotionActivityScope oldWidget) =>
      active != oldWidget.active;
}
