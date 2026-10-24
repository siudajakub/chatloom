// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// Native names shown under the English language name, in this button's
/// menu and in the Settings → Transcriptions default-language picker.
const notionTranscriptionNativeNames = <String, String>{
  'pl': 'Polski',
  'hy': 'Հայերեն',
};

/// Short code shown in the language segment: "Auto", "PL", "EN", "HY".
String notionTranscriptionLanguageCode(String? language) =>
    language == null ? 'Auto' : language.toUpperCase();

/// Full English name of a transcription language; null is automatic.
String notionTranscriptionLanguageName(String? language) => language == null
    ? 'Automatic'
    : transcriptionLanguages[language] ?? language.toUpperCase();

/// A chosen transcription language; [code] null is automatic. A record so
/// that "Automatic" differs from a dismissed menu.
typedef TranscriptionLanguageChoice = ({String? code});

/// Glass menu entries ([showNotionMenu]) for every supported transcription
/// language, with a check on [selected]. Shared by the split button and the
/// transcript menu; keys are `transcription-language-<code|auto>`.
List<NotionMenuEntry<TranscriptionLanguageChoice>>
notionTranscriptionLanguageEntries({required String? selected}) => [
  for (final language in <String?>[null, ...transcriptionLanguages.keys])
    NotionMenuEntry<TranscriptionLanguageChoice>(
      key: ValueKey('transcription-language-${language ?? 'auto'}'),
      value: (code: language),
      label: notionTranscriptionLanguageName(language),
      subtitle: notionTranscriptionNativeNames[language],
      selected: language == selected,
    ),
];

/// Opens the language menu at [anchorContext]; null when dismissed.
Future<TranscriptionLanguageChoice?> showTranscriptionLanguageMenu(
  BuildContext anchorContext, {
  required String? selected,
}) => showNotionMenu<TranscriptionLanguageChoice>(
  anchorContext,
  semanticLabel: 'Transcription language',
  width: 220,
  entries: notionTranscriptionLanguageEntries(selected: selected),
);

/// Outlined split pill: the left segment starts (or retries) a manual
/// transcription; the right segment picks its language. Running jobs use
/// the inline progress and cancellation controls in the transcript panel.
///
/// Visual height 36 (grows with the text scale), hit height at least 48. [foregroundColor] adapts the pill to the
/// bubble it sits on (incoming/outgoing); it defaults to `onSurface`.
class NotionTranscribeSplitButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? language;
  final VoidCallback? onTranscribe;
  final ValueChanged<String?>? onLanguageSelected;
  final Color? foregroundColor;

  const NotionTranscribeSplitButton({
    super.key,
    this.label = 'Transcribe',
    this.icon = Icons.notes_rounded,
    this.language,
    this.onTranscribe,
    this.onLanguageSelected,
    this.foregroundColor,
  });

  /// Pill height at the default text scale.
  static const double visualHeight = 36;

  /// Pill height for [scaler]: the label line plus 8 dp above and below.
  static double scaledHeight(TextScaler scaler) =>
      math.max(visualHeight, scaler.scale(20) + 2 * NotionSpace.xs);

  @override
  Widget build(BuildContext context) {
    final foreground =
        foregroundColor ?? Theme.of(context).colorScheme.onSurface;
    final line = foreground.withValues(alpha: .24);
    final height = scaledHeight(MediaQuery.textScalerOf(context));
    const radius = Radius.circular(NotionRadius.md);
    final directional = Directionality.of(context) == TextDirection.ltr;
    final startShape = RoundedRectangleBorder(
      borderRadius: directional
          ? const BorderRadius.horizontal(left: radius)
          : const BorderRadius.horizontal(right: radius),
    );
    final endShape = RoundedRectangleBorder(
      borderRadius: directional
          ? const BorderRadius.horizontal(right: radius)
          : const BorderRadius.horizontal(left: radius),
    );
    ButtonStyle segment(OutlinedBorder shape) => TextButton.styleFrom(
      foregroundColor: foreground,
      disabledForegroundColor: foreground.withValues(alpha: .38),
      overlayColor: foreground,
      minimumSize: Size(visualHeight, height),
      tapTargetSize: MaterialTapTargetSize.padded,
      padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
      shape: shape,
      textStyle: NotionType.footnote.copyWith(fontWeight: FontWeight.w500),
    );

    final primary = TextButton(
      key: const ValueKey('transcribe-primary'),
      style: segment(startShape),
      onPressed: onTranscribe,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );

    final trailing = Builder(
      builder: (anchor) => TextButton(
        key: const ValueKey('transcribe-language'),
        style: segment(endShape).copyWith(
          padding: const WidgetStatePropertyAll(
            EdgeInsetsDirectional.only(
              start: NotionSpace.xs,
              end: NotionSpace.xxs,
            ),
          ),
        ),
        onPressed: onLanguageSelected == null
            ? null
            : () async {
                final choice = await showTranscriptionLanguageMenu(
                  anchor,
                  selected: language,
                );
                if (choice != null) onLanguageSelected?.call(choice.code);
              },
        child: Semantics(
          label:
              'Transcription language: ${notionTranscriptionLanguageName(language)}',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                notionTranscriptionLanguageCode(language),
                textDirection: TextDirection.ltr,
              ),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more_rounded, size: NotionSize.iconSm),
            ],
          ),
        ),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          Positioned.fill(
            child: Center(
              child: SizedBox(
                key: const ValueKey('transcribe-pill'),
                height: height,
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: foreground.withValues(alpha: .06),
                    border: Border.all(color: line),
                    borderRadius: const BorderRadius.all(radius),
                  ),
                ),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: primary),
              SizedBox(
                height: 20,
                child: VerticalDivider(width: 1, thickness: 1, color: line),
              ),
              trailing,
            ],
          ),
        ],
      ),
    );
  }
}
