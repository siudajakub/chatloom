// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_tokens.dart';

/// One timed word of a [NotionTranscriptLine]: when it is spoken and its
/// UTF-16 range in the line's text.
@immutable
class NotionTranscriptWord {
  const NotionTranscriptWord({
    required this.start,
    required this.textStart,
    required this.textEnd,
  });

  final Duration start;
  final int textStart, textEnd;
}

/// One line of a [NotionSyncedTranscript]: current from [start] until the
/// next line starts. [words] (optional, in order) highlight word by word.
@immutable
class NotionTranscriptLine {
  const NotionTranscriptLine({
    required this.start,
    required this.text,
    this.words = const [],
  });

  final Duration start;
  final String text;
  final List<NotionTranscriptWord> words;
}

/// A transcript that follows playback like Apple Music lyrics, over the dark
/// media stage: the line being spoken is bright at full size, past lines are
/// dimmed, upcoming lines muted and a little smaller. The list glides so the
/// current line sits at [anchor] (the upper third); top and bottom edges
/// fade out. With word timings the current line lights up word by word.
///
/// Tapping a line calls [onSeek] with its start. While the user scrolls,
/// following pauses and resumes [followHold] after the list comes to rest
/// (a controller timeline, no timer), or at once on a tap.
///
/// Data and callbacks only: [position] is the player's position (it may
/// tick at any rate; the list rebuilds only when the current line changes,
/// and only the current line when its word changes). Transform and opacity
/// only; under reduced motion the line switches and the list jumps without
/// animation. Needs a bounded height (an `Expanded` slot).
///
/// ```dart
/// NotionSyncedTranscript(
///   lines: lines,
///   position: positionNotifier,
///   onSeek: player.seek,
///   caption: 'Approximate timing',
/// )
/// ```
class NotionSyncedTranscript extends StatefulWidget {
  const NotionSyncedTranscript({
    super.key,
    required this.lines,
    required this.position,
    this.onSeek,
    this.caption,
    this.color = NotionMediaColors.onScrim,
    this.style = lineStyle,
    this.anchor = defaultAnchor,
    this.followHold = defaultFollowHold,
  });

  final List<NotionTranscriptLine> lines;
  final ValueListenable<Duration> position;
  final ValueChanged<Duration>? onSeek;

  /// A muted note above the first line (e.g. that times are estimated).
  final String? caption;

  /// Text colour; [NotionMediaColors.onScrim] over the media stage.
  final Color color;
  final TextStyle style;

  /// Where the current line's top rests, as a fraction of the height.
  final double anchor;

  /// How long following waits after the user scrolled.
  final Duration followHold;

  /// Lyrics size: between `heading` and `title`, bold.
  static const lineStyle = TextStyle(
    fontFamily: NotionType.family,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.25,
  );

  static const double defaultAnchor = .3;
  static const Duration defaultFollowHold = Duration(seconds: 3);

  /// Resting opacity of lines already spoken and of lines still to come.
  static const double pastOpacity = .34;
  static const double upcomingOpacity = .56;

  /// Words of the current line not spoken yet.
  static const double unspokenOpacity = .5;

  /// Resting scale of every line but the current one.
  static const double inactiveScale = .96;

  /// Height of each edge fade (at most a quarter of the view).
  static const double edgeFade = 48;

  /// Index of the line current at [position]: the last line that started
  /// at or before it, -1 before the first line.
  static int indexAt(List<NotionTranscriptLine> lines, Duration position) =>
      _lastAtOrBefore(lines.length, (i) => lines[i].start, position);

  /// Index of the word of [line] spoken at [position], -1 before its first.
  static int wordAt(NotionTranscriptLine line, Duration position) =>
      _lastAtOrBefore(line.words.length, (i) => line.words[i].start, position);

  @override
  State<NotionSyncedTranscript> createState() => _NotionSyncedTranscriptState();
}

int _lastAtOrBefore(int length, Duration Function(int) startOf, Duration at) {
  var low = 0, high = length - 1, found = -1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (startOf(middle) <= at) {
      found = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return found;
}

class _NotionSyncedTranscriptState extends State<NotionSyncedTranscript>
    with TickerProviderStateMixin {
  final _scroll = ScrollController();

  /// The current line; the list rebuilds only when it changes.
  final _active = ValueNotifier<int>(-1);

  /// The current word of the current line; only that line listens.
  final _word = ValueNotifier<int>(-1);

  /// One emphasis timeline for the whole list: the current line rises along
  /// it while the line it replaced settles back.
  late final AnimationController _shift = AnimationController(
    vsync: this,
    duration: NotionMotion.medium,
    value: 1,
  );
  late final CurvedAnimation _emphasis = CurvedAnimation(
    parent: _shift,
    curve: NotionMotion.standard,
  );

  /// The wait before following resumes; made on the first user scroll.
  AnimationController? _hold;

  List<GlobalKey> _keys = const [];
  int _leaving = -1;
  bool _following = true;
  bool _reduced = false;
  bool _deferred = false;
  bool _revealScheduled = false;
  Size? _viewport;

  @override
  void initState() {
    super.initState();
    _keys = _newKeys();
    widget.position.addListener(_onPosition);
    _settle(widget.position.value);
  }

  List<GlobalKey> _newKeys() => [
    for (var i = 0; i < widget.lines.length; i++) GlobalKey(),
  ];

  @override
  void didUpdateWidget(covariant NotionSyncedTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    if (!listEquals(oldWidget.lines, widget.lines)) {
      if (oldWidget.lines.length != widget.lines.length) _keys = _newKeys();
      _settle(widget.position.value);
      _scheduleReveal();
    }
    _hold?.duration = widget.followHold;
  }

  /// Takes the line and word at [position] without motion.
  void _settle(Duration position) {
    final index = NotionSyncedTranscript.indexAt(widget.lines, position);
    _leaving = -1;
    _shift.value = 1;
    _active.value = index;
    _word.value = index < 0
        ? -1
        : NotionSyncedTranscript.wordAt(widget.lines[index], position);
  }

  void _onPosition() {
    if (!mounted) return;
    // A player may report while a frame is being built; never rebuild a
    // listener mid-build, take the value once the frame is done.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_deferred) return;
      _deferred = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _deferred = false;
        _onPosition();
      });
      return;
    }
    final position = widget.position.value;
    final index = NotionSyncedTranscript.indexAt(widget.lines, position);
    if (index != _active.value) {
      _leaving = _active.value;
      _active.value = index;
      if (_reduced) {
        _shift.value = 1;
      } else {
        _shift.forward(from: 0);
      }
      if (_following) _reveal(index, animate: true);
    }
    _word.value = index < 0
        ? -1
        : NotionSyncedTranscript.wordAt(widget.lines[index], position);
  }

  /// Scrolls so line [index] (the first line before any is current) rests
  /// at the anchor. Only this list scrolls, never an enclosing page view.
  void _reveal(int index, {required bool animate}) {
    if (!_scroll.hasClients || widget.lines.isEmpty) return;
    final target = _keys[index.clamp(0, widget.lines.length - 1)];
    final box = target.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final position = _scroll.position;
    final offset = viewport
        .getOffsetToReveal(box, widget.anchor)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((offset - position.pixels).abs() < .5) return;
    if (!animate || _reduced) {
      _scroll.jumpTo(offset);
      return;
    }
    unawaited(
      _scroll.animateTo(
        offset,
        duration: NotionMotion.long,
        curve: NotionMotion.standard,
      ),
    );
  }

  /// After the next layout: put the current line at the anchor at once (the
  /// first frame, a new size, new lines).
  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted && _following) _reveal(_active.value, animate: false);
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification is! UserScrollNotification) {
      return false;
    }
    if (notification.direction == ScrollDirection.idle) {
      if (!_following) _startHold();
    } else {
      _following = false;
      _hold?.stop();
    }
    return false;
  }

  void _startHold() {
    final hold = _hold ??=
        AnimationController(vsync: this, duration: widget.followHold)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) _resume();
          });
    hold.forward(from: 0);
  }

  void _resume() {
    if (!mounted || _following) return;
    _following = true;
    _reveal(_active.value, animate: true);
  }

  void _seek(int index) {
    _hold?.stop();
    _following = true;
    _reveal(index, animate: true);
    widget.onSeek?.call(widget.lines[index].start);
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    _emphasis.dispose();
    _shift.dispose();
    _hold?.dispose();
    _scroll.dispose();
    _active.dispose();
    _word.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _reduced = NotionMotion.reduced(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.hasBoundedHeight
            ? constraints.biggest
            : Size(constraints.maxWidth, MediaQuery.sizeOf(context).height / 2);
        if (_viewport != size) {
          _viewport = size;
          _scheduleReveal();
        }
        final height = size.height;
        final fade = height <= 0
            ? 0.0
            : math.min(NotionSyncedTranscript.edgeFade, height / 4) / height;
        final caption = widget.caption;
        return SizedBox(
          height: constraints.hasBoundedHeight ? null : height,
          child: RepaintBoundary(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [
                  Color(0x00FFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0x00FFFFFF),
                ],
                stops: [0, fade, 1 - fade, 1],
              ).createShader(bounds),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: EdgeInsets.only(
                    top: height * widget.anchor,
                    bottom: height * (1 - widget.anchor),
                  ),
                  child: ValueListenableBuilder<int>(
                    valueListenable: _active,
                    builder: (context, active, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (caption != null)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: NotionSpace.xs,
                            ),
                            child: Text(
                              caption,
                              style: NotionType.caption.copyWith(
                                color: widget.color.withValues(
                                  alpha:
                                      widget.color.a *
                                      NotionSyncedTranscript.upcomingOpacity,
                                ),
                              ),
                            ),
                          ),
                        for (var i = 0; i < widget.lines.length; i++)
                          _line(context, i, active),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _line(BuildContext context, int index, int active) {
    final line = widget.lines[index];
    final current = index == active;
    final base = index < active
        ? NotionSyncedTranscript.pastOpacity
        : NotionSyncedTranscript.upcomingOpacity;
    // The current line rises along the shared timeline, the line it
    // replaced settles back; every other line rests without a layer.
    final Animation<double>? emphasis;
    if (current) {
      emphasis = _emphasis;
    } else if (index == _leaving) {
      emphasis = ReverseAnimation(_emphasis);
    } else {
      emphasis = null;
    }
    final color = widget.color;
    final Widget text;
    if (current && line.words.isNotEmpty) {
      text = ValueListenableBuilder<int>(
        valueListenable: _word,
        builder: (context, word, _) =>
            Text.rich(_spans(line, word, color), style: widget.style),
      );
    } else {
      text = Text(
        line.text,
        style: widget.style.copyWith(
          // Lines at rest carry their opacity in the colour (no layer).
          color: emphasis == null
              ? color.withValues(alpha: color.a * base)
              : color,
        ),
      );
    }
    final alignment = Directionality.of(context) == TextDirection.rtl
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final Widget body = emphasis == null
        ? Transform.scale(
            scale: NotionSyncedTranscript.inactiveScale,
            alignment: alignment,
            child: text,
          )
        : FadeTransition(
            opacity: Tween<double>(begin: base, end: 1).animate(emphasis),
            child: ScaleTransition(
              scale: Tween<double>(
                begin: NotionSyncedTranscript.inactiveScale,
                end: 1,
              ).animate(emphasis),
              alignment: alignment,
              child: text,
            ),
          );
    final seek = widget.onSeek;
    return KeyedSubtree(
      key: _keys[index],
      child: Semantics(
        button: seek != null,
        selected: current,
        onTapHint: seek == null ? null : 'Play from here',
        child: NotionTapTarget(
          behavior: HitTestBehavior.opaque,
          onTap: seek == null ? null : () => _seek(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
            child: body,
          ),
        ),
      ),
    );
  }

  /// Spoken words (up to and including [word]) in full colour, the rest
  /// muted; text between timed words follows the word before it.
  TextSpan _spans(NotionTranscriptLine line, int word, Color color) {
    final text = line.text;
    final spoken = word < 0
        ? 0
        : line.words[word].textEnd.clamp(0, text.length);
    final muted = color.withValues(
      alpha: color.a * NotionSyncedTranscript.unspokenOpacity,
    );
    return TextSpan(
      children: [
        if (spoken > 0)
          TextSpan(
            text: text.substring(0, spoken),
            style: TextStyle(color: color),
          ),
        if (spoken < text.length)
          TextSpan(
            text: text.substring(spoken),
            style: TextStyle(color: muted),
          ),
      ],
    );
  }
}
