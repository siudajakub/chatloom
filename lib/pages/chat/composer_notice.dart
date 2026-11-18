// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// A short, transient notice from a composer action (a round video that
/// could not start, for example), shown just above the composer.
///
/// The theme's floating snackbar sits at the bottom of the chat's scaffold,
/// which is exactly where the composer is: it covered "+", emoji and the
/// editor and looked like the composer had turned into an error. A mounted
/// [ComposerNoticeStrip] shows the text above the composer instead and hides
/// it after [ComposerNoticeStrip.visibleFor]; without one (no composer on
/// screen) it falls back to the snackbar.
abstract final class ComposerNotice {
  static final ValueNotifier<(int, String)?> _current = ValueNotifier(null);
  static int _strips = 0;
  static int _serial = 0;

  /// The notice being shown, for tests.
  @visibleForTesting
  static String? get current => _current.value?.$2;

  static void show(BuildContext context, String message) {
    if (_strips > 0) {
      _current.value = (++_serial, message);
      return;
    }
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  static void _dismiss(int serial) {
    if (_current.value?.$1 == serial) _current.value = null;
  }
}

class ComposerNoticeStrip extends StatefulWidget {
  const ComposerNoticeStrip({super.key});

  static const Duration visibleFor = Duration(seconds: 5);

  @override
  State<ComposerNoticeStrip> createState() => _ComposerNoticeStripState();
}

class _ComposerNoticeStripState extends State<ComposerNoticeStrip> {
  Timer? _timer;
  (int, String)? _shown;

  @override
  void initState() {
    super.initState();
    ComposerNotice._strips++;
    // A notice from before this composer existed is stale.
    ComposerNotice._current.value = null;
    ComposerNotice._current.addListener(_changed);
  }

  @override
  void dispose() {
    ComposerNotice._current.removeListener(_changed);
    ComposerNotice._strips--;
    _timer?.cancel();
    super.dispose();
  }

  void _changed() {
    final value = ComposerNotice._current.value;
    _timer?.cancel();
    if (value != null) {
      _timer = Timer(
        ComposerNoticeStrip.visibleFor,
        () => ComposerNotice._dismiss(value.$1),
      );
    }
    if (mounted) setState(() => _shown = value ?? _shown);
  }

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final current = ComposerNotice._current.value;
    final text = (current ?? _shown)?.$2 ?? '';
    return NotionSizeReveal(
      visible: current != null,
      duration: NotionMotion.short,
      alignment: AlignmentDirectional.bottomStart,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NotionSpace.sm,
          NotionSpace.xxs,
          NotionSpace.sm,
          0,
        ),
        child: Semantics(
          liveRegion: true,
          container: true,
          // No blur: the notice reveals and hides (glass never animates).
          child: NotionGlassPanel(
            key: const ValueKey('composer-notice'),
            blur: false,
            overlay: false,
            borderRadius: NotionGlass.panelRadius,
            padding: const EdgeInsetsDirectional.only(
              start: NotionSpace.sm,
              end: NotionSpace.xxs,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: NotionSize.iconSm,
                  color: notion.colors.textSecondary,
                ),
                const SizedBox(width: NotionSpace.xs),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: NotionSpace.xs,
                    ),
                    child: Text(text, style: notion.typography.callout),
                  ),
                ),
                NotionIconButton(
                  icon: Icons.close,
                  label: 'Dismiss',
                  onPressed: current == null
                      ? null
                      : () => ComposerNotice._dismiss(current.$1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
