// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The same authored grid is used for incoming and outgoing source events.
/// Sender/media widgets and their state remain owned by the existing client.
class NotionAuthoredMessageRow extends StatelessWidget {
  final Widget avatar;
  final String author;
  final String time;
  final Widget body;
  final Widget? actions;
  final String? source;
  const NotionAuthoredMessageRow({
    super.key,
    required this.avatar,
    required this.author,
    required this.time,
    required this.body,
    this.actions,
    this.source,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: NotionTokens.inset,
      vertical: 10,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox.square(dimension: 36, child: avatar),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NotionAuthorHeading(author: author, time: time, actions: actions),
              const SizedBox(height: 4),
              DefaultTextStyle.merge(style: NotionTokens.body, child: body),
              if (source != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    source!,
                    style: NotionTokens.caption.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class NotionAuthorHeading extends StatelessWidget {
  final String author;
  final String time;
  final Widget? leading;
  final Widget? actions;
  const NotionAuthorHeading({
    super.key,
    required this.author,
    required this.time,
    this.leading,
    this.actions,
  });
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ?leading,
            Text(
              author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            Text(
              time,
              style: NotionTokens.caption.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      ?actions,
    ],
  );
}

/// Quiet surface only: production callers supply their real editors, source
/// selector, recorder, attachment picker and durable send action.
class NotionComposer extends StatelessWidget {
  final Widget input;
  final List<Widget> actions;
  final Widget source;
  final Widget sendAction;
  const NotionComposer({
    super.key,
    required this.input,
    required this.actions,
    required this.source,
    required this.sendAction,
  });
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(NotionTokens.radius),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      color: Theme.of(context).colorScheme.surface,
    ),
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: input,
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Wrap(spacing: 0, runSpacing: 0, children: actions)),
            const SizedBox(width: 4),
            sendAction,
          ],
        ),
        Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 2), child: source),
      ],
    ),
  );
}

class NotionSendButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool busy;
  const NotionSendButton({super.key, this.onPressed, this.busy = false});
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('send_button'),
    tooltip: 'Send message',
    onPressed: busy ? null : onPressed,
    style: IconButton.styleFrom(
      minimumSize: const Size.square(48),
      backgroundColor: Theme.of(context).colorScheme.onSurface,
      foregroundColor: Theme.of(context).colorScheme.surface,
      disabledBackgroundColor: Theme.of(
        context,
      ).colorScheme.onSurface.withAlpha(90),
      disabledForegroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    icon: busy
        ? SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.surface,
            ),
          )
        : const Icon(Icons.arrow_upward, size: 24),
  );
}

/// Inline audio file block shared by the actual SDK player and captures.
class NotionAudioFileBlock extends StatelessWidget {
  final String duration;
  final double progress;
  final bool playing;
  final bool downloading;
  final double? downloadProgress;
  final VoidCallback? onPlay;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onDownload;
  final Widget? speedAction;
  const NotionAudioFileBlock({
    super.key,
    required this.duration,
    required this.progress,
    this.playing = false,
    this.downloading = false,
    this.downloadProgress,
    this.onPlay,
    this.onSeek,
    this.onDownload,
    this.speedAction,
  });
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(NotionTokens.radius),
    ),
    padding: const EdgeInsets.only(left: 10, right: 2, top: 6, bottom: 4),
    child: Row(
      children: [
        Tooltip(
          message: 'Download audio',
          child: InkWell(
            onTap: onDownload,
            child: const SizedBox(
              width: 44,
              height: 48,
              child: Icon(Icons.audio_file_outlined, size: 26),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Voice message',
                style: TextStyle(fontSize: 15, height: 1.3),
              ),
              Row(
                children: [
                  Text(
                    duration,
                    style: NotionTokens.caption.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 28,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 4,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 10,
                          ),
                        ),
                        child: Slider(
                          min: 0,
                          max: 1,
                          value: progress.clamp(0, 1).toDouble(),
                          semanticFormatterCallback: (value) =>
                              '${(value * 100).round()} percent',
                          onChanged: onSeek,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              ?speedAction,
            ],
          ),
        ),
        if (downloading)
          Padding(
            padding: const EdgeInsets.all(14),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: downloadProgress,
              ),
            ),
          )
        else
          NotionIconButton(
            icon: playing ? Icons.pause_outlined : Icons.play_arrow_outlined,
            label: playing ? 'Pause audio' : 'Play audio',
            onPressed: onPlay,
          ),
      ],
    ),
  );
}

/// Offset correction for a rendered event anchor. Reverse timelines increase
/// their screen Y when scroll offset increases.
double notionRestoredScrollOffset(
  double current,
  double beforeY,
  double afterY, {
  required bool reverse,
}) => current + (reverse ? beforeY - afterY : afterY - beforeY);

/// Manual request affordance. Rendering this action never starts a job.
class NotionTranscribeAction extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final bool busy;
  const NotionTranscribeAction({
    super.key,
    this.onPressed,
    this.label = 'Transcribe',
    this.busy = false,
  });
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(48, 44),
      alignment: Alignment.centerLeft,
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy) ...[
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    ),
  );
}
