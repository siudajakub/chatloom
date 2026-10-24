// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Flat secondary settings surface. It retains each inherited controller and
/// route while avoiding the older desktop card wrapper.
///
/// Motion: once the page push has settled, the sections of a [Column] child
/// rise in one after another (first appearance only, capped stagger); any
/// other child fades in as one block. Everything settles to identity.
class NotionSettingsBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final bool withScrolling;
  final EdgeInsets? innerPadding;

  /// The body sits under a glass header (`extendBodyBehindAppBar`): the
  /// rows scroll beneath it, so the header's height
  /// (`MediaQuery.paddingOf(context).top` inside the Scaffold) is added to
  /// the top padding instead of a top `SafeArea` (DESIGN.md "Glass").
  final bool glassHeader;
  const NotionSettingsBody({
    super.key,
    required this.child,
    this.maxWidth = 640,
    this.withScrolling = true,
    this.innerPadding,
    this.glassHeader = false,
  });

  /// Wraps the sections of [child] in staggered entrances.
  static Widget staggered(Widget child) {
    if (child is! Column) return NotionEntrance(child: child);
    return NotionEntranceScope(
      child: Column(
        key: child.key,
        mainAxisAlignment: child.mainAxisAlignment,
        mainAxisSize: child.mainAxisSize,
        crossAxisAlignment: child.crossAxisAlignment,
        textDirection: child.textDirection,
        verticalDirection: child.verticalDirection,
        textBaseline: child.textBaseline,
        spacing: child.spacing,
        children: [
          for (final section in child.children)
            // Flex children must stay direct children of the column.
            section is Flexible
                ? section
                : NotionEntrance(rise: NotionMotion.riseList, child: section),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final header = glassHeader ? MediaQuery.paddingOf(context).top : 0.0;
    final base = innerPadding ?? const EdgeInsets.fromLTRB(20, 12, 20, 32);
    final padding = base.copyWith(top: base.top + header);
    return SafeArea(
      top: !glassHeader,
      child: ListTileTheme.merge(
        contentPadding: EdgeInsets.zero,
        titleTextStyle: Theme.of(context).textTheme.bodyLarge!.copyWith(
          fontSize: 16,
          height: 1.4,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        subtitleTextStyle: Theme.of(context).textTheme.bodySmall!.copyWith(
          fontSize: 13,
          height: 1.4,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: withScrolling
                ? SingleChildScrollView(
                    padding: padding,
                    child: staggered(child),
                  )
                : Padding(
                    padding: padding,
                    // The header height is already in the padding: lists
                    // inside must not add it a second time.
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: glassHeader,
                      child: staggered(child),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class NotionSettingsScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  final bool withScrolling;

  /// Header actions, e.g. an add button.
  final List<Widget> actions;

  /// Whether the header shows a back button; by default only when the
  /// window is too narrow for the settings column.
  final bool? showBack;
  const NotionSettingsScaffold({
    super.key,
    required this.title,
    required this.child,
    this.withScrolling = true,
    this.actions = const [],
    this.showBack,
  });

  /// The settings sub-page header: glass like Settings root, Appearance
  /// and Networks; the rows scroll under it.
  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      title: Text(title),
      centerTitle: false,
      toolbarHeight: NotionTokens.headerHeight,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: const NotionGlassBar(),
      automaticallyImplyLeading:
          showBack ?? MediaQuery.sizeOf(context).width <= 840,
      actions: actions.isEmpty
          ? null
          : [...actions, const SizedBox(width: NotionSpace.xxs)],
    ),
    // Built under the Scaffold, so its top padding includes the header.
    body: NotionSettingsBody(
      withScrolling: withScrolling,
      glassHeader: true,
      child: child,
    ),
  );
}

/// Settings group heading. Delegates to the shared [NotionSectionHeader] so
/// every settings surface uses one RTL-safe header style.
class NotionSettingsSection extends StatelessWidget {
  final String title;
  const NotionSettingsSection(this.title, {super.key});
  @override
  Widget build(BuildContext context) => NotionSectionHeader(title: title);
}

/// Keeps descriptive toggles readable when text scaling consumes the row width.
class NotionSettingsToggle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const NotionSettingsToggle({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final activate = onChanged == null ? null : () => onChanged!(!value);
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: NotionTokens.body.copyWith(
            color: onChanged == null
                ? secondary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
        // A changed explanation (e.g. "Suppressed by Incognito") fades
        // through while the row eases to its new height.
        AnimatedSize(
          duration: NotionMotion.of(context, NotionMotion.medium),
          curve: NotionMotion.emphasized,
          alignment: AlignmentDirectional.topStart,
          child: NotionFadeThrough(
            child: subtitle == null
                ? const SizedBox(key: ValueKey('no-subtitle'), width: 0)
                : Text(
                    subtitle!,
                    key: ValueKey(subtitle),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: secondary,
                    ),
                  ),
          ),
        ),
      ],
    );
    final toggle = Switch.adaptive(value: value, onChanged: onChanged);
    return Semantics(
      label: title,
      hint: subtitle,
      toggled: value,
      enabled: onChanged != null,
      onTap: activate,
      child: ExcludeSemantics(
        child: NotionPressable(
          scale: NotionMotion.pressRow,
          enabled: activate != null,
          child: InkWell(
            canRequestFocus: false,
            onTap: activate,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    MediaQuery.textScalerOf(context).scale(16) > 22 &&
                        constraints.maxWidth < 480
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          copy,
                          Align(
                            alignment: Alignment.centerRight,
                            child: toggle,
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: copy),
                          const SizedBox(width: 12),
                          toggle,
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
