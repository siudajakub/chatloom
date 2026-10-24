// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_dialog_frame.dart';
import 'notion_entrance.dart';
import 'notion_glass.dart';
import 'notion_modal_routes.dart';
import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

/// Page template for every Notion screen: compact header, optional large page
/// title, centred content column with the page gutter.
///
/// Pass either [children] (scrolling list with the standard padding) or a
/// custom [body]. Keep the screen's own logic in its controller; this widget
/// is presentation only.
class NotionScaffold extends StatelessWidget {
  /// Compact header title. Omit to show only back/actions.
  final String? title;

  /// Large page title rendered at the top of the content.
  final String? pageTitle;

  /// Shows a back chevron when set.
  final VoidCallback? onBack;
  final String? backLabel;
  final List<Widget> actions;
  final List<Widget>? children;
  final Widget? body;
  final Widget? bottomBar;
  final Widget? floatingActionButton;
  final double maxWidth;
  final Key? scrollKey;

  const NotionScaffold({
    super.key,
    this.title,
    this.pageTitle,
    this.onBack,
    this.backLabel,
    this.actions = const [],
    this.children,
    this.body,
    this.bottomBar,
    this.floatingActionButton,
    this.maxWidth = NotionSize.contentMaxWidth,
    this.scrollKey,
  }) : assert(
         (children == null) != (body == null),
         'Pass exactly one of children or body',
       );

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    // A list page scrolls under a glass header (DESIGN.md "Glass"); a custom
    // [body] keeps the opaque header and is laid out below it.
    final glassHeader = body == null;
    final content =
        body ??
        Builder(
          // Inside the Scaffold the top padding includes the header.
          builder: (context) => ListView(
            key: scrollKey,
            padding: EdgeInsets.fromLTRB(
              NotionSpace.inset,
              NotionSpace.xs + MediaQuery.paddingOf(context).top,
              NotionSpace.inset,
              NotionSpace.xxl,
            ),
            children: [
              if (pageTitle != null)
                Padding(
                  padding: const EdgeInsets.only(
                    top: NotionSpace.md,
                    bottom: NotionSpace.xl,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(pageTitle!, style: tokens.typography.title),
                  ),
                ),
              ...children!,
            ],
          ),
        );
    return Scaffold(
      extendBodyBehindAppBar: glassHeader,
      appBar: AppBar(
        toolbarHeight: NotionSize.headerHeight,
        automaticallyImplyLeading: false,
        backgroundColor: glassHeader ? Colors.transparent : null,
        flexibleSpace: glassHeader ? const NotionGlassBar() : null,
        leading: onBack == null
            ? null
            // The press motion of `NotionIconButton` (UI-20), like the
            // conversation and Settings headers.
            : NotionPressable(
                scale: NotionMotion.pressIcon,
                child: IconButton(
                  tooltip:
                      backLabel ??
                      MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: onBack,
                  icon: const Icon(Icons.chevron_left),
                ),
              ),
        title: title == null ? null : Text(title!),
        actions: [
          ...actions,
          const SizedBox(width: NotionSpace.xxs),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: bottomBar == null,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: content,
          ),
        ),
      ),
      bottomNavigationBar: bottomBar,
      floatingActionButton: floatingActionButton,
    );
  }
}

/// Muted label above a group of rows.
class NotionSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  /// Defaults to a top gap that separates groups; rows below supply their own
  /// spacing.
  final EdgeInsetsGeometry padding;

  const NotionSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.only(
      top: NotionSpace.xl,
      bottom: NotionSpace.xxs,
    ),
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: context.notion.typography.sectionLabel),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

enum NotionButtonVariant {
  /// One per view: the main action.
  primary,

  /// Neutral bordered action.
  secondary,

  /// Text-only, for low emphasis and dialog cancel.
  ghost,

  /// Irreversible actions (delete, leave, sign out).
  destructive,
}

/// The only button primitive. Pick a [variant] instead of styling Material
/// buttons by hand.
class NotionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final NotionButtonVariant variant;
  final IconData? icon;

  /// Stretches to the available width (forms, sheets on phones).
  final bool expand;

  /// Shows a progress indicator and disables the button.
  final bool busy;

  const NotionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = NotionButtonVariant.secondary,
    this.icon,
    this.expand = false,
    this.busy = false,
  });

  const NotionButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.busy = false,
  }) : variant = NotionButtonVariant.primary;

  const NotionButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.busy = false,
  }) : variant = NotionButtonVariant.ghost;

  const NotionButton.destructive({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.busy = false,
  }) : variant = NotionButtonVariant.destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final pressed = busy ? null : onPressed;
    final foreground = switch (variant) {
      NotionButtonVariant.primary => context.notion.palette.onAccentFill,
      NotionButtonVariant.destructive => colors.danger,
      _ => colors.text,
    };
    final child = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final glyph = busy
        // The glyph morphs at once (the button is disabled while busy), so
        // the ring has no grace; it rests after the loop cap (UI-13).
        ? NotionDelayedSpinner(
            key: const ValueKey('busy'),
            size: NotionSize.iconSm,
            delay: Duration.zero,
            color: foreground,
          )
        : icon == null
        ? null
        : Icon(icon, key: ValueKey(icon), size: NotionSize.icon);
    final leading = glyph == null
        ? null
        : NotionMorphSwitcher(rotate: false, child: glyph);
    const padding = EdgeInsets.symmetric(horizontal: NotionSpace.md);
    final minimumSize = Size(expand ? double.infinity : 64, 40);
    final button = switch (variant) {
      NotionButtonVariant.primary => FilledButton.icon(
        onPressed: pressed,
        icon: leading,
        label: child,
        style: FilledButton.styleFrom(
          padding: padding,
          minimumSize: minimumSize,
        ),
      ),
      NotionButtonVariant.secondary => OutlinedButton.icon(
        onPressed: pressed,
        icon: leading,
        label: child,
        style: OutlinedButton.styleFrom(
          padding: padding,
          minimumSize: minimumSize,
        ),
      ),
      NotionButtonVariant.ghost => TextButton.icon(
        onPressed: pressed,
        icon: leading,
        label: child,
        style: TextButton.styleFrom(padding: padding, minimumSize: minimumSize),
      ),
      NotionButtonVariant.destructive => OutlinedButton.icon(
        onPressed: pressed,
        icon: leading,
        label: child,
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.danger,
          side: BorderSide(color: colors.danger.withValues(alpha: .5)),
          padding: padding,
          minimumSize: minimumSize,
        ),
      ),
    };
    return NotionPressable(enabled: pressed != null, child: button);
  }
}

/// Dialog body with Notion spacing. Use [showNotionDialog] to present it.
class NotionDialog extends StatelessWidget {
  final String title;

  /// Plain text body; use [content] for anything richer.
  final String? message;
  final Widget? content;

  /// Usually [NotionButton]s, rightmost is the confirming action.
  final List<Widget> actions;

  const NotionDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final typography = context.notion.typography;
    // A glass panel (dock tint + hairline, blur once the route settles) in
    // place of the opaque Material dialog surface.
    return NotionDialogFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: typography.headline),
          ),
          if (message != null) ...[
            const SizedBox(height: NotionSpace.xs),
            Text(message!, style: typography.calloutMuted),
          ],
          if (content != null) ...[
            const SizedBox(height: NotionSpace.md),
            Flexible(child: content!),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: NotionSpace.xl),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: NotionSpace.xs,
              runSpacing: NotionSpace.xs,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// Presents a [NotionDialog]. [actions] receives the dialog context so that
/// buttons can `Navigator.pop(context, value)`.
Future<T?> showNotionDialog<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget? content,
  List<Widget> Function(BuildContext context)? actions,
  bool barrierDismissible = true,
}) => showNotionCustomDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => NotionDialog(
    title: title,
    message: message,
    content: content,
    actions: actions?.call(context) ?? const [],
  ),
);

/// Two-button confirmation. Resolves to `true` only on confirm.
Future<bool> showNotionConfirmDialog({
  required BuildContext context,
  required String title,
  required String confirmLabel,
  String? message,
  String? cancelLabel,
  bool destructive = false,
}) async {
  final result = await showNotionDialog<bool>(
    context: context,
    title: title,
    message: message,
    actions: (context) => [
      NotionButton.ghost(
        label:
            cancelLabel ?? MaterialLocalizations.of(context).cancelButtonLabel,
        onPressed: () => Navigator.of(context).pop(false),
      ),
      NotionButton(
        label: confirmLabel,
        variant: destructive
            ? NotionButtonVariant.destructive
            : NotionButtonVariant.primary,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
  return result ?? false;
}

/// Bottom sheet body: drag handle, optional title, padded content.
class NotionSheet extends StatelessWidget {
  final String? title;
  final Widget child;

  /// The drag handle; off when the sheet is shown as a centred dialog on a
  /// wide desktop window (nothing to drag there).
  final bool showHandle;

  const NotionSheet({
    super.key,
    this.title,
    required this.child,
    this.showHandle = true,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return SafeArea(
      child: Padding(
        padding: NotionSpace.sheet,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHandle)
              Center(
                child: Container(
                  width: 36,
                  height: NotionSpace.xxs,
                  margin: const EdgeInsets.only(bottom: NotionSpace.sm),
                  decoration: BoxDecoration(
                    color: tokens.colors.border,
                    borderRadius: NotionRadius.pillAll,
                  ),
                ),
              ),
            if (title != null)
              NotionEntrance(
                afterRoute: false,
                rise: NotionMotion.riseSheet,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: NotionSpace.sm),
                  child: Semantics(
                    header: true,
                    child: Text(title!, style: tokens.typography.headline),
                  ),
                ),
              ),
            Flexible(
              child: NotionEntrance(
                index: title == null ? 0 : 1,
                afterRoute: false,
                rise: NotionMotion.riseSheet,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Presents [builder] inside a [NotionSheet].
///
/// Phones and tablets get the glass bottom sheet. A wide desktop window
/// (macOS, Linux, Windows at [NotionSize.sheetDialogMinWidth] or more) shows
/// the same content as a centred glass dialog ([NotionDialogFrame], at most
/// [NotionSize.sheetDialogMaxWidth] × [NotionSize.sheetDialogMaxHeight]) with
/// the dialog motion: a sheet sliding up from the bottom edge of a 1100 px
/// window reads as a phone port (MAC-18). [asDialog] overrides the choice.
Future<T?> showNotionSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  bool isDismissible = true,
  bool? asDialog,
}) {
  if (asDialog ?? notionSheetAsDialog(context)) {
    return showNotionCustomDialog<T>(
      context: context,
      barrierDismissible: isDismissible,
      // The same navigator as the bottom sheet, so callers that pop through
      // an outer context behave the same in both presentations.
      useRootNavigator: false,
      builder: (context) => NotionDialogFrame(
        padding: EdgeInsets.zero,
        maxWidth: NotionSize.sheetDialogMaxWidth,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: NotionSize.sheetDialogMaxHeight,
          ),
          child: NotionSheet(
            title: title,
            showHandle: false,
            child: builder(context),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: isDismissible,
    showDragHandle: false,
    sheetAnimationStyle: NotionMotion.sheetStyleOf(context),
    constraints: const BoxConstraints(maxWidth: NotionSize.contentMaxWidth),
    // The sheet is a glass panel: it blurs once settled and paints the opaque
    // tint while it slides or is dragged.
    backgroundColor: Colors.transparent,
    elevation: 0,
    shape: NotionShapes.sheet,
    builder: (context) => NotionGlassPanel(
      borderRadius: NotionGlass.sheetRadius,
      child: NotionSheet(title: title, child: builder(context)),
    ),
  );
}

/// Whether [showNotionSheet] presents as a centred dialog here: a pointer
/// platform (macOS, Linux, Windows) with a window at least
/// [NotionSize.sheetDialogMinWidth] wide.
bool notionSheetAsDialog(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return MediaQuery.sizeOf(context).width >= NotionSize.sheetDialogMinWidth;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// Centred placeholder for empty lists, missing content and soft errors.
class NotionEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;

  /// Usually a single [NotionButton].
  final Widget? action;

  const NotionEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: NotionSize.dialogMaxWidth),
        child: Padding(
          padding: const EdgeInsets.all(NotionSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NotionPop(
                from: .8,
                afterRoute: true,
                child: Icon(
                  icon,
                  size: NotionSize.avatar,
                  color: tokens.colors.textTertiary,
                ),
              ),
              const SizedBox(height: NotionSpace.md),
              NotionEntrance(
                index: 1,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: tokens.typography.bodyStrong,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: NotionSpace.xxs),
                NotionEntrance(
                  index: 2,
                  child: Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: tokens.typography.calloutMuted,
                  ),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: NotionSpace.lg),
                NotionEntrance(index: 3, child: action!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Text input with the label above the field (no floating label).
class NotionTextField extends StatelessWidget {
  final String? label;
  final String? hint;
  final String? helper;
  final String? error;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;
  final IconData? prefixIcon;
  final Widget? suffix;
  final bool obscureText;
  final bool autofocus;
  final bool enabled;
  final bool readOnly;
  final bool autocorrect;
  final int? minLines;
  final int maxLines;
  final int? maxLength;

  const NotionTextField({
    super.key,
    this.label,
    this.hint,
    this.helper,
    this.error,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.autofillHints,
    this.prefixIcon,
    this.suffix,
    this.obscureText = false,
    this.autofocus = false,
    this.enabled = true,
    this.readOnly = false,
    this.autocorrect = true,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      autofillHints: autofillHints,
      obscureText: obscureText,
      autofocus: autofocus,
      enabled: enabled,
      readOnly: readOnly,
      autocorrect: autocorrect,
      minLines: minLines,
      maxLines: obscureText ? 1 : maxLines,
      maxLength: maxLength,
      style: tokens.typography.callout,
      decoration: InputDecoration(
        hintText: hint,
        helperText: helper,
        errorText: error,
        prefixIcon: prefixIcon == null
            ? null
            : Icon(prefixIcon, size: NotionSize.icon),
        suffixIcon: suffix,
      ),
    );
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: NotionSpace.xxs + 2),
          child: Text(label!, style: tokens.typography.sectionLabel),
        ),
        field,
      ],
    );
  }
}
