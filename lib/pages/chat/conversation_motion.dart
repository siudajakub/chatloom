import 'package:flutter/widgets.dart';

/// Motion policy shared by conversation components. The platform flag is
/// intentionally separate: iOS Reduce Motion need not set disableAnimations.
abstract final class ConversationMotion {
  static bool reduced(BuildContext context) =>
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false) ||
      WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .reduceMotion;
}

/// Only the timeline knows whether an entry is genuinely new. History, paging,
/// decryption and reaction updates must leave [animate] false.
class ConversationMessageEntrance extends StatefulWidget {
  const ConversationMessageEntrance({
    super.key,
    required this.child,
    required this.identity,
    this.animate = false,
  });

  final Widget child;
  final Object identity;
  final bool animate;

  @override
  State<ConversationMessageEntrance> createState() =>
      _ConversationMessageEntranceState();
}

class _ConversationMessageEntranceState
    extends State<ConversationMessageEntrance>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _start();
    } else if (ConversationMotion.reduced(context)) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(ConversationMessageEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) _start();
  }

  void _start() {
    if (widget.animate && !ConversationMotion.reduced(context)) {
      _controller.forward(from: 0);
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (ConversationMotion.reduced(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final progress = Curves.easeOutCubic.transform(_controller.value);
      return Opacity(
        opacity: progress,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - progress)),
          child: Transform.scale(scale: .97 + .03 * progress, child: child),
        ),
      );
    },
  );
}
