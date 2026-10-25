// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// The soft keyboard's last height per orientation (Telegram `kbd_height`,
/// Signal's stored IME height per orientation), as the distance from the
/// screen's bottom edge to the keyboard's top. Kept in memory and, best
/// effort, in the app's preferences so the first swap after a restart
/// already matches.
abstract final class ComposerKeyboardMetrics {
  static final _heights = <Orientation, double>{};
  static bool _loaded = false;

  static String _key(Orientation o) =>
      'pl.personal.composer.keyboard_height.${o.name}';

  static double? heightFor(Orientation orientation) {
    if (!_loaded) {
      _loaded = true;
      for (final o in Orientation.values) {
        try {
          final stored = AppSettings.store.getDouble(_key(o));
          if (stored != null && stored > 0) _heights[o] = stored;
        } catch (_) {
          // Preferences not ready (tests, early start): memory only.
        }
      }
    }
    return _heights[orientation];
  }

  static void record(Orientation orientation, double height) {
    final previous = heightFor(orientation);
    if (previous != null && (previous - height).abs() < 1) return;
    _heights[orientation] = height;
    try {
      AppSettings.store.setDouble(_key(orientation), height);
    } catch (_) {
      // Memory only.
    }
  }

  @visibleForTesting
  static void reset() {
    _heights.clear();
    _loaded = true;
  }
}

/// The composer's emoji/GIF/sticker panel area at the keyboard's height,
/// swapping with the keyboard without moving the composer (Telegram,
/// Signal).
///
/// The page resizes for the keyboard, so the panel takes the room the
/// keyboard leaves: its height is `keyboard − max(inset, navigation bar)`
/// at every frame of the keyboard's own animation. Keyboard → panel: the
/// panel is shown at once and is uncovered while the keyboard slides away.
/// Panel → keyboard: the panel stays until the keyboard covers its place,
/// then goes in one frame. Without a keyboard (or on desktop) it slides
/// open and closed. The content is laid out once at the full height and
/// only clipped while the area changes, so nothing relayouts per frame.
class ComposerPanelSlot extends StatefulWidget {
  const ComposerPanelSlot({
    super.key,
    required this.visible,
    required this.inputFocus,
    required this.builder,
    this.searchFocus,
    this.softKeyboard,
  });

  /// The host's panel state (`showEmojiPicker`).
  final bool visible;

  /// The composer's text field: when it takes focus while the panel
  /// closes, the keyboard is coming and the panel waits for it.
  final FocusNode inputFocus;

  /// Focus of a search field inside the panel. While it is focused the
  /// keyboard is open under the panel, which keeps a compact height.
  final FocusNode? searchFocus;

  /// Builds the content for a height.
  final Widget Function(BuildContext context, double height) builder;

  /// Whether the platform has a soft keyboard (default: Android and iOS).
  final bool? softKeyboard;

  @override
  State<ComposerPanelSlot> createState() => _ComposerPanelSlotState();
}

enum _Phase { closed, open, yielding }

class _ComposerPanelSlotState extends State<ComposerPanelSlot>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// A bottom inset this much above the navigation bar is a keyboard.
  static const _keyboardThreshold = 80.0;

  /// How long panel → keyboard waits for a keyboard that never comes
  /// (hardware keyboard), measured on frame timestamps, not a timer.
  static const _keyboardGrace = Duration(milliseconds: 600);

  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: NotionMotion.long,
    reverseDuration: NotionMotion.short,
  )..addStatusListener(_revealStatus);
  late final CurvedAnimation _revealCurve = CurvedAnimation(
    parent: _reveal,
    curve: NotionMotion.emphasized,
    reverseCurve: NotionMotion.exitFast,
  );

  _Phase _phase = _Phase.closed;

  /// Raw keyboard inset and navigation bar padding (logical pixels).
  double _inset = 0, _padding = 0;
  Size _size = Size.zero;
  Orientation _orientation = Orientation.portrait;

  /// Steadiness check: the inset being watched and since when (frame time).
  double? _steadyProbe;
  Duration? _steadySince;
  bool _steadyArmed = false;

  /// How long the inset must stay put to count as a resting keyboard.
  static const _steadyWindow = Duration(milliseconds: 120);

  /// Frame timestamp when panel → keyboard started waiting.
  Duration? _yieldStart;

  /// The content of the last build, reused while only the keyboard moves
  /// (the slot rebuilds per keyboard frame; the panel does not).
  Widget? _content;
  double? _contentHeight;

  bool get _soft => widget.softKeyboard ?? PlatformInfos.isMobile;
  bool get _searching => widget.searchFocus?.hasFocus ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.searchFocus?.addListener(_searchFocusChanged);
    if (widget.visible) {
      _phase = _Phase.open;
      _reveal.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readMetrics();
  }

  @override
  void didUpdateWidget(ComposerPanelSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _content = null;
    if (oldWidget.searchFocus != widget.searchFocus) {
      oldWidget.searchFocus?.removeListener(_searchFocusChanged);
      widget.searchFocus?.addListener(_searchFocusChanged);
    }
    if (oldWidget.visible == widget.visible) return;
    if (widget.visible) {
      _open();
    } else {
      _close();
    }
  }

  void _open() {
    _phase = _Phase.open;
    _yieldStart = null;
    // Swapping in for a keyboard: the keyboard's slide is the motion.
    if (_keyboardUp || NotionMotion.reduced(context)) {
      _reveal.value = 1;
    } else {
      _reveal.forward();
    }
  }

  void _close() {
    final keyboardComing = _soft && (widget.inputFocus.hasFocus || _keyboardUp);
    if (keyboardComing && _reveal.value > 0) {
      // The keyboard takes the panel's place; drop the panel once it has.
      _phase = _Phase.yielding;
      _yieldStart = null;
      _armYieldWatch();
      return;
    }
    _phase = _Phase.closed;
    if (NotionMotion.reduced(context) || _keyboardUp) {
      _reveal.value = 0;
    } else {
      _reveal.reverse();
    }
  }

  void _revealStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  void _searchFocusChanged() {
    if (mounted) setState(() => _content = null);
  }

  bool get _keyboardUp => _inset > _padding + _keyboardThreshold;

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final before = _inset;
    final size = _size;
    _readMetrics();
    if (before != _inset) {
      _armSteadyCheck();
      if (_phase == _Phase.yielding) _checkYield();
      setState(() {});
    } else if (size != _size) {
      // Rotation or window resize: the panel height follows.
      setState(() => _content = null);
    }
  }

  void _readMetrics() {
    final view = View.maybeOf(context);
    if (view == null) return;
    final dpr = view.devicePixelRatio;
    _inset = view.viewInsets.bottom / dpr;
    _padding = view.viewPadding.bottom / dpr;
    _size = view.physicalSize / dpr;
    _orientation = _size.width > _size.height
        ? Orientation.landscape
        : Orientation.portrait;
  }

  /// Records the keyboard height once it has stopped moving (the inset
  /// stayed the same for [_steadyWindow] of frame time, so a frame of the
  /// keyboard's own animation never counts): the keyboard may change size
  /// (another IME, a suggestion strip) and its last resting height is the
  /// one the panel matches. Frames are requested only until then.
  void _armSteadyCheck() {
    if (_steadyArmed) return;
    _steadyArmed = true;
    _steadyProbe = null;
    _steadySince = null;
    _steadyFrame();
  }

  void _steadyFrame() {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) {
          _steadyArmed = false;
          return;
        }
        final now = SchedulerBinding.instance.currentFrameTimeStamp;
        if (_steadyProbe != _inset || _steadySince == null) {
          _steadyProbe = _inset;
          _steadySince = now;
        } else if (now - _steadySince! >= _steadyWindow) {
          _steadyArmed = false;
          _steady();
          return;
        }
        _steadyFrame();
      })
      ..scheduleFrame();
  }

  void _steady() {
    // Only a keyboard some field asked for (not one that is closing).
    final typing =
        widget.inputFocus.hasFocus || (widget.searchFocus?.hasFocus ?? false);
    if (_keyboardUp && _soft && typing) {
      ComposerKeyboardMetrics.record(_orientation, math.max(_inset, _padding));
    }
    if (_phase == _Phase.yielding && _keyboardUp) _finishYield();
  }

  void _checkYield() {
    if (_space(_panelHeight) <= 0.5) _finishYield();
  }

  /// Waits (on frame timestamps) for a keyboard after panel → keyboard; a
  /// keyboard that does not show within [_keyboardGrace] means there is
  /// none (hardware keyboard), and the panel closes like on desktop.
  void _armYieldWatch() {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || _phase != _Phase.yielding) return;
        if (_inset > _padding) return; // The keyboard is moving.
        final now = SchedulerBinding.instance.currentFrameTimeStamp;
        final start = _yieldStart ??= now;
        if (now - start >= _keyboardGrace) {
          setState(() {
            _phase = _Phase.closed;
            _reveal.value = 0;
          });
          return;
        }
        _armYieldWatch();
      })
      ..scheduleFrame();
  }

  void _finishYield() {
    if (_phase != _Phase.yielding) return;
    setState(() {
      _phase = _Phase.closed;
      _reveal.value = 0;
    });
  }

  /// The panel's full height: the remembered keyboard minus the navigation
  /// bar (which the page pads anyway), or a fallback before any keyboard
  /// was seen.
  double get _panelHeight {
    if (!_soft) {
      return math.min(360.0, math.max(240.0, _size.height * .4));
    }
    final keyboard = ComposerKeyboardMetrics.heightFor(_orientation);
    if (keyboard != null && keyboard > _padding + _keyboardThreshold) {
      return keyboard - _padding;
    }
    final fraction = _orientation == Orientation.portrait ? .4 : .5;
    return (_size.height * fraction).clamp(200.0, 400.0);
  }

  /// The compact height while the panel's own search field has the
  /// keyboard.
  double get _searchHeight {
    final available = _size.height - math.max(_inset, _padding);
    return math.min(_panelHeight, math.max(160.0, available * .45));
  }

  /// The room the keyboard leaves for the panel right now.
  double _space(double panel) {
    if (!_soft) return panel;
    final keyboard = panel + _padding;
    return math.max(0.0, keyboard - math.max(_inset, _padding));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.searchFocus?.removeListener(_searchFocusChanged);
    _revealCurve.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.closed && _reveal.isDismissed) {
      return const SizedBox.shrink();
    }
    final searching = _searching && _phase == _Phase.open;
    final height = searching ? _searchHeight : _panelHeight;
    final space = searching ? height : _space(height);
    if (_content == null || _contentHeight != height) {
      _contentHeight = height;
      _content = RepaintBoundary(
        child: SizedBox(height: height, child: widget.builder(context, height)),
      );
    }
    final content = _content!;
    return SizeTransition(
      sizeFactor: _revealCurve,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: space,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: height,
            maxHeight: height,
            child: content,
          ),
        ),
      ),
    );
  }
}
