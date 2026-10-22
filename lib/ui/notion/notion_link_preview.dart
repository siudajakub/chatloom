// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_tokens.dart';

/// A link preview inside a message bubble (Telegram, Messenger, WhatsApp):
/// an opaque card with the page's image, site, title and description.
///
/// Presentation only: data and callbacks. The bridges deliver the preview
/// (`com.beeper.linkpreviews`); nothing here fetches the URL. Colours come
/// from the bubble ([fill], [textColor], [mutedColor], typically
/// `ConversationReplyQuote.colorsFor`), so it reads on own and incoming
/// bubbles and on private chat palettes. No blur: it scrolls with content.
///
/// ```dart
/// NotionLinkPreviewCard(
///   title: 'Article', site: 'example.org', fill: colors.fill,
///   textColor: colors.text, mutedColor: muted, onTap: open,
/// )
/// ```
class NotionLinkPreviewCard extends StatelessWidget {
  const NotionLinkPreviewCard({
    super.key,
    this.title,
    this.description,
    this.site,
    this.image,
    this.imageAspectRatio,
    required this.fill,
    required this.textColor,
    required this.mutedColor,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
  });

  final String? title;
  final String? description;

  /// Site name or domain, above the title.
  final String? site;

  /// The page's image (already loaded or a placeholder), drawn edge to edge
  /// at the top of the card.
  final Widget? image;

  /// Width / height of [image]; clamped to [minImageAspect]–[maxImageAspect]
  /// (tall images are cropped to a square, very wide ones to 16:9).
  final double? imageAspectRatio;

  final Color fill;
  final Color textColor;
  final Color mutedColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  /// Widest card; narrower bubbles make it narrower.
  static const double maxWidth = 300;
  static const double minImageAspect = 1;
  static const double maxImageAspect = 16 / 9;
  static const int titleLines = 2;
  static const int descriptionLines = 3;

  @override
  Widget build(BuildContext context) {
    final title = this.title?.trim();
    final description = this.description?.trim();
    final site = this.site?.trim();
    final image = this.image;
    final aspect = (imageAspectRatio ?? maxImageAspect).clamp(
      minImageAspect,
      maxImageAspect,
    );
    final texts = <Widget>[
      if (site != null && site.isNotEmpty)
        Text(
          site,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: NotionType.caption.copyWith(color: mutedColor),
        ),
      if (title != null && title.isNotEmpty)
        Text(
          title,
          maxLines: titleLines,
          overflow: TextOverflow.ellipsis,
          style: NotionType.callout.copyWith(
            color: textColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (description != null && description.isNotEmpty)
        Text(
          description,
          maxLines: descriptionLines,
          overflow: TextOverflow.ellipsis,
          style: NotionType.footnote.copyWith(color: textColor),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth.clamp(0.0, maxWidth)
            : maxWidth;
        return Semantics(
          button: onTap != null,
          label: semanticLabel,
          child: SizedBox(
            width: width,
            child: ClipRRect(
              borderRadius: NotionRadius.mdAll,
              child: Material(
                color: fill,
                child: InkWell(
                  onTap: onTap,
                  onLongPress: onLongPress,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (image != null)
                        AspectRatio(aspectRatio: aspect, child: image),
                      if (texts.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(NotionSpace.sm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            spacing: NotionSpace.xxs,
                            children: texts,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
