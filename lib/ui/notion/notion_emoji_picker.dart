// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_emoji_search.dart';
import 'notion_glass.dart';
import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_reactions.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

export 'notion_emoji_search.dart';

/// Emoji picker geometry (DESIGN.md "Emoji picker").
abstract final class NotionEmojiSizes {
  /// Target cell; the grid fits as many columns as cells of this size.
  static const double cell = 46;

  /// Glyph size in the grid (Telegram's 30 pt in a 44–48 pt cell).
  static const double glyph = 30;

  /// Section header at 1× text scale (grows with the text).
  static const double header = 30;

  /// Category bar and its cells: full touch targets.
  static const double bar = NotionSize.touchTarget;

  /// The skin-tone pill: one cell per tone and the untoned emoji.
  static const double toneCell = 44;

  /// Fewest columns at any width (320 pt at 2× text still shows six).
  static const int minColumns = 5;
}

/// A titled group of a picker: a category, the recents, a network's
/// reactions. [id] keys its scroll position and bar cell.
@immutable
class NotionEmojiSection {
  const NotionEmojiSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.emoji,
  });

  final String id;
  final String title;
  final IconData icon;
  final List<NotionEmoji> emoji;
}

/// ChatLoom's emoji picker (Telegram/Messenger grade, Notion dark v2): a
/// search field that never moves, a category bar of 48 pt cells that
/// follows the scroll and jumps smoothly, sticky section headers, a fixed
/// extent grid of large glyphs that press like buttons, skin tones on
/// long-press (slide onto a tone while still holding, remembered through
/// [onTone]) and instant ranked search ([search]) with an empty state and
/// Enter picking the first result. [selected] marks emoji the user already
/// gave (own reactions). Data and callbacks only: the catalogue, recents
/// and remembered tones are the caller's.
///
/// No glass inside: it scrolls. The section headers and the tone pill are
/// opaque in [background] (default: the overlay glass tone, for sheets and
/// panels). Cells built by scrolling never animate; the switch between
/// categories and results fades through.
class NotionEmojiPicker extends StatefulWidget {
  const NotionEmojiPicker({
    super.key,
    required this.sections,
    required this.onSelected,
    this.search,
    this.usage = const {},
    this.selected = const {},
    this.tones = const {},
    this.onTone,
    this.categoryBar = true,
    this.focusNode,
    this.autofocus = false,
    this.hint = 'Search emoji',
    this.emptyLabel = 'No emoji found',
    this.background,
    this.controller,
  });

  /// Shown in this order; empty sections are skipped.
  final List<NotionEmojiSection> sections;

  /// The chosen glyph, with its skin tone.
  final ValueChanged<String> onSelected;

  /// Search over the whole set; null hides the field.
  final NotionEmojiSearch? search;

  /// How often the user picked each emoji (ranks search ties).
  final Map<String, int> usage;

  /// Emoji the user already gave; compared without variation selectors.
  final Set<String> selected;

  /// Remembered tone per emoji ([NotionEmojiSearch.key] → tone modifier).
  final Map<String, String> tones;

  /// A tone was chosen for an emoji (null: the untoned one).
  final void Function(String emoji, String? tone)? onTone;

  /// The category bar (off for a short, fixed set like a chat's reactions).
  final bool categoryBar;

  final FocusNode? focusNode;
  final bool autofocus;
  final String hint;
  final String emptyLabel;

  /// Opaque tone behind sticky headers; defaults to the overlay glass tone.
  final Color? background;

  /// Optional, to read or set the query from outside (tests, composer).
  final TextEditingController? controller;

  @override
  State<NotionEmojiPicker> createState() => NotionEmojiPickerState();
}

/// State of [NotionEmojiPicker]; [jumpTo] and [results] are public for
/// hosts and tests.
class NotionEmojiPickerState extends State<NotionEmojiPicker> {
  final _scroll = ScrollController();
  final _results = ScrollController();
  final _active = ValueNotifier<int>(0);
  TextEditingController? _ownQuery;
  TextEditingController get _query =>
      widget.controller ?? (_ownQuery ??= TextEditingController());

  /// Section start offsets of the last layout (fixed extents, no keys).
  List<double> _offsets = const [];
  List<NotionEmojiSection> _visible = const [];
  bool _jumping = false;
  String _lastQuery = '';
  List<NotionEmoji> _found = const [];

  // Skin tones: the emoji whose pill is open, where, and the finger.
  NotionEmoji? _toneFor;
  Rect _toneAnchor = Rect.zero;
  int? _toneHover;
  bool _toneHeld = false;
  final _stackKey = GlobalKey();

  /// Results of the current query (empty while not searching).
  List<NotionEmoji> get results => _found;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_track);
    _query.addListener(_queryChanged);
    _lastQuery = _query.text;
    _found = _computeResults(_lastQuery);
  }

  @override
  void didUpdateWidget(NotionEmojiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownQuery)?.removeListener(_queryChanged);
      _query.addListener(_queryChanged);
    }
    if (oldWidget.search != widget.search || oldWidget.usage != widget.usage) {
      _found = _computeResults(_query.text);
    }
  }

  @override
  void dispose() {
    _query.removeListener(_queryChanged);
    _ownQuery?.dispose();
    _scroll.dispose();
    _results.dispose();
    _active.dispose();
    super.dispose();
  }

  bool get _searching => _query.text.trim().isNotEmpty;

  List<NotionEmoji> _computeResults(String query) =>
      widget.search?.search(query, usage: widget.usage) ?? const [];

  void _queryChanged() {
    final text = _query.text;
    if (text == _lastQuery) return;
    final wasSearching = _lastQuery.trim().isNotEmpty;
    _lastQuery = text;
    setState(() {
      _found = _computeResults(text);
      _toneFor = null;
    });
    if (_results.hasClients && wasSearching) _results.jumpTo(0);
  }

  /// The glyph a cell shows: the remembered tone on a tone-taking emoji.
  String _glyph(NotionEmoji emoji) {
    if (!emoji.tones) return emoji.emoji;
    final tone = widget.tones[NotionEmojiSearch.key(emoji.emoji)];
    return tone == null
        ? emoji.emoji
        : NotionEmojiTones.apply(emoji.emoji, tone);
  }

  void _pick(String glyph) {
    if (_toneFor != null) setState(() => _toneFor = null);
    widget.onSelected(glyph);
  }

  void _submit(String _) {
    if (_found.isEmpty) return;
    _pick(_glyph(_found.first));
  }

  // ------------------------------------------------------------ categories

  void _track() {
    if (_jumping || !_scroll.hasClients || _offsets.isEmpty) return;
    final position = _scroll.position;
    var index = 0;
    if (position.pixels >= position.maxScrollExtent - 1 &&
        position.maxScrollExtent > 0) {
      index = _offsets.length - 1;
    } else {
      for (var i = 0; i < _offsets.length; i++) {
        if (_offsets[i] <= position.pixels + 1) index = i;
      }
    }
    _active.value = index;
  }

  /// Scrolls section [index] to the top (Telegram: the bar's tap). Far
  /// jumps land a screen short and glide the rest, so no frame builds the
  /// whole set in between; reduced motion jumps.
  Future<void> jumpTo(int index) async {
    if (_searching) {
      _query.clear();
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || !_scroll.hasClients || index >= _offsets.length) return;
    final position = _scroll.position;
    final target = _offsets[index].clamp(0.0, position.maxScrollExtent);
    _active.value = index;
    if (NotionMotion.reduced(context)) {
      _scroll.jumpTo(target);
      return;
    }
    final viewport = position.viewportDimension;
    final distance = target - position.pixels;
    _jumping = true;
    try {
      if (distance.abs() > viewport * 1.5) {
        _scroll.jumpTo(target - viewport * distance.sign * .75);
      }
      await _scroll.animateTo(
        target,
        duration: NotionMotion.medium,
        curve: NotionMotion.emphasized,
      );
    } finally {
      _jumping = false;
    }
  }

  // ------------------------------------------------------------ skin tones

  void _openTones(NotionEmoji emoji, BuildContext cell) {
    final stack = _stackKey.currentContext?.findRenderObject();
    final box = cell.findRenderObject();
    if (stack is! RenderBox || box is! RenderBox || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: stack);
    setState(() {
      _toneFor = emoji;
      _toneAnchor = topLeft & box.size;
      _toneHover = null;
      _toneHeld = true;
    });
  }

  void _closeTones() {
    if (_toneFor != null) setState(() => _toneFor = null);
  }

  List<String?> get _toneChoices => [null, ...NotionEmojiTones.all];

  Rect _tonePill(Size area) {
    final width =
        _toneChoices.length * NotionEmojiSizes.toneCell + 2 * NotionSpace.xxs;
    const height = NotionEmojiSizes.toneCell + 2 * NotionSpace.xxs;
    final left = (_toneAnchor.center.dx - width / 2).clamp(
      NotionSpace.xxs,
      math.max(NotionSpace.xxs, area.width - width - NotionSpace.xxs),
    );
    var top = _toneAnchor.top - height - NotionSpace.xxs;
    if (top < 0) top = _toneAnchor.bottom + NotionSpace.xxs;
    return Rect.fromLTWH(left.toDouble(), top, width, height);
  }

  int? _toneAt(Offset global) {
    final stack = _stackKey.currentContext?.findRenderObject();
    if (stack is! RenderBox || !stack.hasSize) return null;
    final local = stack.globalToLocal(global);
    final pill = _tonePill(stack.size).inflate(NotionSpace.sm);
    if (!pill.contains(local)) return null;
    final x = local.dx - pill.left - NotionSpace.sm - NotionSpace.xxs;
    final index = (x / NotionEmojiSizes.toneCell).floor();
    return index.clamp(0, _toneChoices.length - 1);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_toneHeld || _toneFor == null) return;
    final hover = _toneAt(event.position);
    if (hover != _toneHover) {
      if (hover != null) NotionHaptics.selection();
      setState(() => _toneHover = hover);
    }
  }

  void _pointerUp(PointerUpEvent event) {
    if (!_toneHeld) return;
    _toneHeld = false;
    final hover = _toneHover;
    if (hover != null) _chooseTone(hover);
  }

  void _chooseTone(int index) {
    final emoji = _toneFor;
    if (emoji == null) return;
    final tone = _toneChoices[index];
    widget.onTone?.call(emoji.emoji, tone);
    _pick(NotionEmojiTones.apply(emoji.emoji, tone));
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final background =
        widget.background ??
        notionGlassOpaque(context, notion.glass.overlayTint);
    _visible = [
      for (final section in widget.sections)
        if (section.emoji.isNotEmpty) section,
    ];
    final search = widget.search;
    return Listener(
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: (_) => _toneHeld = false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (search != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NotionSpace.xs,
                0,
                NotionSpace.xs,
                NotionSpace.xxs,
              ),
              child: _SearchField(
                controller: _query,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                hint: widget.hint,
                onSubmitted: _submit,
              ),
            ),
          if (widget.categoryBar && _visible.length > 1)
            _CategoryBar(sections: _visible, active: _active, onTap: jumpTo),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _body(context, constraints, background),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    BoxConstraints constraints,
    Color background,
  ) {
    const side = NotionSpace.xs;
    final inner = math.max(0.0, constraints.maxWidth - 2 * side);
    final columns = math.max(
      NotionEmojiSizes.minColumns,
      (inner / NotionEmojiSizes.cell).floor(),
    );
    final cell = inner / columns;
    final scaler = MediaQuery.textScalerOf(context);
    final header = math.max(
      NotionEmojiSizes.header,
      scaler.scale(NotionType.caption.fontSize!) * 1.4 + NotionSpace.sm,
    );
    // Fixed extents: section starts are arithmetic, no keys or layouts.
    final offsets = <double>[];
    var y = 0.0;
    for (final section in _visible) {
      offsets.add(y);
      y += header + (section.emoji.length / columns).ceil() * cell;
    }
    _offsets = offsets;
    final searching = _searching;
    final categories = CustomScrollView(
      controller: _scroll,
      slivers: [
        for (final section in _visible)
          SliverMainAxisGroup(
            key: ValueKey('emoji-section-${section.id}'),
            slivers: [
              PinnedHeaderSliver(
                child: _SectionHeader(
                  title: section.title,
                  height: header,
                  background: background,
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: side),
                sliver: _grid(section.emoji, columns, cell),
              ),
            ],
          ),
        const SliverToBoxAdapter(child: SizedBox(height: NotionSpace.xs)),
      ],
    );
    final body = Stack(
      key: _stackKey,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            ignoring: searching,
            child: ExcludeSemantics(
              excluding: searching,
              child: AnimatedOpacity(
                opacity: searching ? 0 : 1,
                duration: NotionMotion.of(context, NotionMotion.short),
                curve: NotionMotion.standard,
                child: categories,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: NotionFadeThrough(
            duration: NotionMotion.short,
            child: !searching
                ? const SizedBox.shrink(key: ValueKey('emoji-browse'))
                : _found.isEmpty
                ? _Empty(
                    key: const ValueKey('emoji-empty'),
                    label: widget.emptyLabel,
                  )
                : CustomScrollView(
                    key: const ValueKey('emoji-results'),
                    controller: _results,
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                          side,
                          NotionSpace.xxs,
                          side,
                          NotionSpace.xs,
                        ),
                        sliver: _grid(_found, columns, cell),
                      ),
                    ],
                  ),
          ),
        ),
        if (_toneFor != null) ...[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeTones,
              onPanStart: (_) => _closeTones(),
            ),
          ),
          _TonePill(
            rect: _tonePill(constraints.biggest),
            emoji: _toneFor!.emoji,
            choices: _toneChoices,
            hovered: _toneHover,
            selected: widget.tones[NotionEmojiSearch.key(_toneFor!.emoji)],
            background: background,
            onChoose: _chooseTone,
          ),
        ],
      ],
    );
    return body;
  }

  Widget _grid(List<NotionEmoji> emoji, int columns, double cell) {
    final selected = {
      for (final key in widget.selected) NotionReactions.normalize(key),
    };
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisExtent: cell,
      ),
      delegate: SliverChildBuilderDelegate((context, index) {
        final item = emoji[index];
        final glyph = _glyph(item);
        return _EmojiCell(
          glyph: glyph,
          extent: cell,
          selected: selected.contains(NotionReactions.normalize(glyph)),
          onTap: () => _pick(glyph),
          onLongPress: item.tones && widget.onTone != null
              ? (cellContext) => _openTones(item, cellContext)
              : null,
        );
      }, childCount: emoji.length),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.hint,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final String hint;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    // Escape clears a query first; an empty field lets the sheet close.
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.escape ||
          controller.text.isEmpty ||
          (controller.value.composing.isValid &&
              !controller.value.composing.isCollapsed)) {
        return KeyEventResult.ignored;
      }
      controller.clear();
      return KeyEventResult.handled;
    },
    child: TextField(
      key: const ValueKey('emoji-search'),
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      autocorrect: false,
      style: context.notion.typography.callout,
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: NotionSize.icon),
        // The clear button pops in once there is something to clear; the
        // field keeps its size either way.
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => NotionMorphSwitcher(
            rotate: false,
            child: value.text.isEmpty
                ? const SizedBox.square(
                    key: ValueKey('empty'),
                    dimension: NotionSize.icon,
                  )
                : IconButton(
                    key: const ValueKey('clear'),
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close, size: NotionSize.icon),
                    onPressed: () {
                      controller.clear();
                      focusNode?.requestFocus();
                    },
                  ),
          ),
        ),
      ),
    ),
  );
}

class _CategoryBar extends StatefulWidget {
  const _CategoryBar({
    required this.sections,
    required this.active,
    required this.onTap,
  });

  final List<NotionEmojiSection> sections;
  final ValueNotifier<int> active;
  final ValueChanged<int> onTap;

  @override
  State<_CategoryBar> createState() => _CategoryBarState();
}

class _CategoryBarState extends State<_CategoryBar> {
  final _strip = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.active.addListener(_follow);
  }

  @override
  void didUpdateWidget(_CategoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      oldWidget.active.removeListener(_follow);
      widget.active.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.active.removeListener(_follow);
    _strip.dispose();
    super.dispose();
  }

  /// A scrolling bar keeps the active cell in view.
  void _follow() {
    if (!_strip.hasClients) return;
    final position = _strip.position;
    const extent = NotionEmojiSizes.bar;
    final left = widget.active.value * extent;
    final viewport = position.viewportDimension;
    double? target;
    if (left < position.pixels) {
      target = left;
    } else if (left + extent > position.pixels + viewport) {
      target = left + extent - viewport;
    }
    if (target == null) return;
    target = target.clamp(0.0, position.maxScrollExtent);
    if (NotionMotion.reduced(context)) {
      _strip.jumpTo(target);
    } else {
      _strip.animateTo(
        target,
        duration: NotionMotion.short,
        curve: NotionMotion.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: NotionEmojiSizes.bar,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final count = widget.sections.length;
        final fits = count * NotionEmojiSizes.bar <= constraints.maxWidth;
        Widget cell(int i) => ValueListenableBuilder<int>(
          valueListenable: widget.active,
          builder: (context, active, _) => _CategoryCell(
            section: widget.sections[i],
            selected: active == i,
            onTap: () => widget.onTap(i),
          ),
        );
        if (fits) {
          return Row(
            children: [
              for (var i = 0; i < count; i++) Expanded(child: cell(i)),
            ],
          );
        }
        return ListView.builder(
          controller: _strip,
          scrollDirection: Axis.horizontal,
          itemExtent: NotionEmojiSizes.bar,
          itemCount: count,
          itemBuilder: (context, i) => cell(i),
        );
      },
    ),
  );
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final NotionEmojiSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final duration = NotionMotion.of(context, NotionMotion.quick);
    return Semantics(
      key: ValueKey('emoji-category-${section.id}'),
      button: true,
      selected: selected,
      label: section.title,
      excludeSemantics: true,
      child: Tooltip(
        message: section.title,
        child: NotionPressable(
          scale: NotionMotion.pressIcon,
          onTap: onTap,
          child: SizedBox(
            height: NotionEmojiSizes.bar,
            child: Center(
              child: AnimatedContainer(
                duration: duration,
                curve: NotionMotion.standard,
                width: NotionSize.touchTarget - NotionSpace.xs,
                height: NotionSize.touchTarget - NotionSpace.sm,
                decoration: BoxDecoration(
                  color: selected
                      ? notion.palette.accentTint
                      : Colors.transparent,
                  borderRadius: NotionRadius.pillAll,
                ),
                child: Icon(
                  section.icon,
                  size: NotionSize.icon,
                  color: selected
                      ? notion.colors.accent
                      : notion.colors.textTertiary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.height,
    required this.background,
  });

  final String title;
  final double height;
  final Color background;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: SizedBox(
      height: height,
      child: ColoredBox(
        color: background,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.notion.typography.sectionLabel,
            ),
          ),
        ),
      ),
    ),
  );
}

/// One grid cell: a big glyph that presses like a button; an own reaction
/// sits on the accent circle of the reaction bar.
class _EmojiCell extends StatelessWidget {
  const _EmojiCell({
    required this.glyph,
    required this.extent,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final String glyph;
  final double extent;
  final bool selected;
  final VoidCallback onTap;
  final void Function(BuildContext cell)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    Widget content = Center(
      child: Text(
        glyph,
        maxLines: 1,
        textAlign: TextAlign.center,
        // Emoji keep their size at any text scale; the grid is fixed.
        textScaler: TextScaler.noScaling,
        style: const TextStyle(fontSize: NotionEmojiSizes.glyph, height: 1.2),
      ),
    );
    if (selected) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.accent.withValues(alpha: .18),
        ),
        child: content,
      );
    }
    final longPress = onLongPress;
    return Semantics(
      button: true,
      selected: selected,
      label: glyph,
      excludeSemantics: true,
      child: NotionPressable(
        scale: NotionMotion.pressIcon,
        onTap: onTap,
        onLongPress: longPress == null ? null : () => longPress(context),
        child: SizedBox.square(dimension: extent, child: content),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(NotionSpace.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: NotionSize.iconLg,
            color: context.notion.colors.textTertiary,
          ),
          const SizedBox(height: NotionSpace.xs),
          Text(
            label,
            textAlign: TextAlign.center,
            style: context.notion.typography.calloutMuted,
          ),
        ],
      ),
    ),
  );
}

/// The skin tones of one emoji in an opaque pill over the grid (it sits on
/// scrolling content, so no blur), the remembered one marked.
class _TonePill extends StatelessWidget {
  const _TonePill({
    required this.rect,
    required this.emoji,
    required this.choices,
    required this.hovered,
    required this.selected,
    required this.background,
    required this.onChoose,
  });

  final Rect rect;
  final String emoji;
  final List<String?> choices;
  final int? hovered;
  final String? selected;
  final Color background;
  final ValueChanged<int> onChoose;

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    return Positioned.fromRect(
      rect: rect,
      child: NotionPop(
        bounce: false,
        from: NotionMotion.popoverFrom,
        child: Semantics(
          container: true,
          label: 'Skin tone',
          child: NotionGlassPanel(
            blur: false,
            borderRadius: NotionRadius.pillAll,
            padding: const EdgeInsets.all(NotionSpace.xxs),
            child: Row(
              children: [
                for (final (index, tone) in choices.indexed)
                  _ToneCell(
                    key: ValueKey('emoji-tone-$index'),
                    glyph: NotionEmojiTones.apply(emoji, tone),
                    hovered: hovered == index,
                    selected: tone == selected,
                    accent: notion.colors.accent,
                    onTap: () => onChoose(index),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToneCell extends StatelessWidget {
  const _ToneCell({
    super.key,
    required this.glyph,
    required this.hovered,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String glyph;
  final bool hovered;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: glyph,
    excludeSemantics: true,
    child: NotionPressable(
      scale: NotionMotion.pressIcon,
      onTap: onTap,
      child: SizedBox.square(
        dimension: NotionEmojiSizes.toneCell,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hovered
                ? context.notion.colors.selected
                : selected
                ? accent.withValues(alpha: .18)
                : Colors.transparent,
          ),
          child: Center(
            child: AnimatedScale(
              scale: hovered ? 1.2 : 1,
              duration: NotionMotion.of(context, NotionMotion.quick),
              curve: NotionMotion.standard,
              child: Text(
                glyph,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(
                  fontSize: NotionEmojiSizes.glyph - 4,
                  height: 1.2,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
