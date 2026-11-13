// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/instagram_share.dart';

/// Only presentation metadata. Never a signed CDN URL or an authentication token.
class ReelMetadata {
  final Uri url;
  final String? caption;
  const ReelMetadata({required this.url, this.caption});

  String get network => url.host.contains('instagr') ? 'Instagram' : 'Facebook';
  String get linkLabel => caption ?? 'Open reel in $network';

  static String? captionText(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text.substring(0, text.length.clamp(0, 16000));
  }

  static Uri? permalink(Object? value) {
    if (value is! String || value.length > 4096) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return null;
    }
    const domains = {
      'instagram.com',
      'instagr.am',
      'facebook.com',
      'fb.com',
      'fb.watch',
      'fb.me',
    };
    if (!domains.any(
      (host) => uri.host == host || uri.host.endsWith('.$host'),
    )) {
      return null;
    }
    return InstagramShare.fromUrl(value)?.url ?? uri;
  }

  static ReelMetadata? fromContent(Map<String, dynamic> content) {
    final url = permalink(content['external_url']);
    if (url == null) return null;
    String? caption;
    for (final key in [
      'com.beeper.meta.caption_body_text',
      'com.beeper.meta.full_post_title',
    ]) {
      caption ??= captionText(content[key]);
    }
    final body = content['body'];
    if (caption == null &&
        body is String &&
        content['filename'] != null &&
        body != content['filename']) {
      final withoutUrl =
          InstagramShare.fromUrl(url.toString())?.withoutLink(body) ??
          body.replaceAll('${content['external_url']}', '').trim();
      caption = captionText(withoutUrl);
    }
    return ReelMetadata(url: url, caption: caption);
  }

  static ReelMetadata fromInstagramResponse(
    InstagramShare share,
    Map response, {
    String? fallbackCaption,
  }) {
    final canonical = response['canonical_url'];
    // Metadata must not change the post or turn the caption into an arbitrary link.
    final url = canonical == null
        ? share.url
        : InstagramShare.fromUrl('$canonical')?.url;
    if (url != share.url) {
      throw const FormatException('Mismatched Instagram post');
    }
    return ReelMetadata(
      url: share.url,
      caption: captionText(response['caption']) ?? captionText(fallbackCaption),
    );
  }
}
