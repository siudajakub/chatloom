// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A link preview a bridge attached to a message (`com.beeper.linkpreviews`,
/// MSC4095): WhatsApp, Meta/Instagram and Telegram send them for shared
/// links. Parsed from the event only; the client never fetches the URL.
class BridgedLinkPreview {
  const BridgedLinkPreview({
    required this.url,
    this.title,
    this.description,
    this.siteName,
    this.image,
    this.imageEncryption,
    this.imageBlurhash,
    this.imageWidth,
    this.imageHeight,
  });

  static const contentKey = 'com.beeper.linkpreviews';

  /// The link the preview belongs to (`matched_url`, else `og:url`).
  final String url;
  final String? title;
  final String? description;
  final String? siteName;

  /// `mxc://` of the image; with [imageEncryption] an encrypted attachment.
  final Uri? image;
  final Map<String, Object?>? imageEncryption;
  final String? imageBlurhash;
  final int? imageWidth;
  final int? imageHeight;

  /// Site name, else the host without `www.`.
  String get site {
    final name = siteName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  double? get imageAspectRatio {
    final w = imageWidth, h = imageHeight;
    return w != null && h != null && w > 0 && h > 0 ? w / h : null;
  }

  static String? _string(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// `IntOrString` in mautrix: a number or a numeric string.
  static int? _int(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static bool _webUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }

  /// The previews of [content] that have a web link and something to show.
  static List<BridgedLinkPreview> fromContent(Map<String, Object?> content) {
    final raw = content[contentKey];
    if (raw is! List) return const [];
    final previews = <BridgedLinkPreview>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = item.cast<String, Object?>();
      final url = _string(map, 'matched_url') ?? _string(map, 'og:url');
      if (url == null || !_webUrl(url)) continue;
      final imageValue = _string(map, 'og:image');
      final image = imageValue == null ? null : Uri.tryParse(imageValue);
      final encryption = map['beeper:image:encryption'];
      final preview = BridgedLinkPreview(
        url: url,
        title: _string(map, 'og:title'),
        description: _string(map, 'og:description'),
        siteName: _string(map, 'og:site_name'),
        image: image != null && image.scheme == 'mxc' ? image : null,
        imageEncryption: encryption is Map
            ? encryption.cast<String, Object?>()
            : null,
        imageBlurhash: _string(map, 'matrix:image:blurhash'),
        imageWidth: _int(map, 'og:image:width'),
        imageHeight: _int(map, 'og:image:height'),
      );
      if (preview.title == null &&
          preview.description == null &&
          preview.image == null) {
        continue;
      }
      previews.add(preview);
    }
    return previews;
  }
}

/// The first bridged preview of [event] as a [NotionLinkPreviewCard] inside
/// the bubble; nothing when the event has none. The image loads through the
/// Matrix media path (decrypted locally when encrypted) and is left out when
/// timeline thumbnails are off.
class LinkPreviewAttachment extends StatelessWidget {
  const LinkPreviewAttachment({
    super.key,
    required this.event,
    required this.preview,
    required this.textColor,
  });

  final Event event;
  final BridgedLinkPreview preview;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final image = preview.image;
    final aspect =
        (preview.imageAspectRatio ?? NotionLinkPreviewCard.maxImageAspect)
            .clamp(
              NotionLinkPreviewCard.minImageAspect,
              NotionLinkPreviewCard.maxImageAspect,
            );
    const width = NotionLinkPreviewCard.maxWidth;
    final height = width / aspect;
    final fill = textColor.withValues(alpha: .1);
    Widget placeholder(BuildContext context) {
      final blurhash = preview.imageBlurhash;
      return blurhash == null
          ? ColoredBox(color: fill)
          : BlurHash(
              blurhash: blurhash,
              width: width,
              height: height,
              fit: BoxFit.cover,
            );
    }

    final showImage =
        image != null && AppSettings.showThumbnailsInTimeline.value;
    return NotionLinkPreviewCard(
      title: preview.title,
      description: preview.description,
      site: preview.site,
      fill: fill,
      textColor: textColor,
      mutedColor: textColor.withValues(alpha: .72),
      imageAspectRatio: aspect,
      semanticLabel: 'Link preview: ${preview.title ?? preview.site}',
      image: showImage
          ? MxcImage(
              uri: image,
              encryption: preview.imageEncryption,
              client: event.room.client,
              cacheKey: 'linkpreview:$image',
              cacheName: event.room.id,
              isThumbnail: preview.imageEncryption == null,
              width: width,
              height: height,
              fit: BoxFit.cover,
              placeholder: placeholder,
              usePlaceholderOnError: true,
            )
          : null,
      onTap: () => UrlLauncher(context, preview.url).launchUrl(),
    );
  }
}
