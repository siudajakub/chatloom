// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Flat secondary settings surface. It retains each inherited controller and
/// route while avoiding the older desktop card wrapper.
class NotionSettingsBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final bool withScrolling;
  final EdgeInsets? innerPadding;
  const NotionSettingsBody({
    super.key,
    required this.child,
    this.maxWidth = 640,
    this.withScrolling = true,
    this.innerPadding,
  });
  @override
  Widget build(BuildContext context) => SafeArea(
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
                  padding:
                      innerPadding ?? const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  child: child,
                )
              : Padding(
                  padding:
                      innerPadding ?? const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  child: child,
                ),
        ),
      ),
    ),
  );
}

class NotionSettingsScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  final bool withScrolling;
  const NotionSettingsScaffold({
    super.key,
    required this.title,
    required this.child,
    this.withScrolling = true,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title),
      centerTitle: false,
      toolbarHeight: NotionTokens.headerHeight,
      automaticallyImplyLeading: MediaQuery.sizeOf(context).width <= 840,
    ),
    body: NotionSettingsBody(withScrolling: withScrolling, child: child),
  );
}

class NotionSettingsSection extends StatelessWidget {
  final String title;
  const NotionSettingsSection(this.title, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        header: true,
        child: Text(title, style: NotionTokens.heading),
      ),
    ),
  );
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
        if (subtitle != null)
          Text(
            subtitle!,
            style: TextStyle(fontSize: 13, height: 1.4, color: secondary),
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
                        Align(alignment: Alignment.centerRight, child: toggle),
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
    );
  }
}
