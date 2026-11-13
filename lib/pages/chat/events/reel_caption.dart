// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/reel_metadata.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:material_ui/material_ui.dart';

class ReelCaption extends StatefulWidget {
  final ReelMetadata metadata;
  final Color? linkColor;
  final VoidCallback? onOpen;
  const ReelCaption({
    super.key,
    required this.metadata,
    this.linkColor,
    this.onOpen,
  });

  @override
  State<ReelCaption> createState() => _ReelCaptionState();
}

class _ReelCaptionState extends State<ReelCaption> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Padding(
    padding: NotionBubble.padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          link: true,
          child: NotionTapTarget(
            onTap:
                widget.onOpen ??
                () => UrlLauncher(
                  context,
                  widget.metadata.url.toString(),
                ).launchUrl(),
            child: Text(
              widget.metadata.linkLabel,
              key: const ValueKey('reel-caption-link'),
              maxLines: _expanded ? null : 4,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: context.notion.typography.body.copyWith(
                color: widget.linkColor ?? context.notion.colors.accent,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
        if ((widget.metadata.caption?.length ?? 0) > 240)
          NotionButton.ghost(
            label: _expanded ? 'Hide description' : 'Show description',
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
      ],
    ),
  );
}
