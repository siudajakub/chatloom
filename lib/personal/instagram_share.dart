// SPDX-License-Identifier: AGPL-3.0-or-later
/// A public post permalink. Never pass arbitrary message URLs to a WebView.
class InstagramShare {
  final Uri url;
  final bool reel;
  const InstagramShare._(this.url, this.reel);

  Uri get embedUrl => url.replace(path: '${url.path}embed/');

  static InstagramShare? fromText(String text) {
    // Matrix reply fallbacks quote the original. Preview only the new text.
    final body = text
        .split('\n')
        .where((line) => !line.startsWith('>'))
        .join('\n');
    for (final match in RegExp(
      r"""https?://[^\s<>"']+""",
      caseSensitive: false,
    ).allMatches(body)) {
      final share = fromUrl(
        match.group(0)!.replaceFirst(RegExp(r'[).,;!?]+$'), ''),
      );
      if (share != null) {
        return share;
      }
    }
    return null;
  }

  static InstagramShare? fromUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (!const {
      'instagram.com',
      'www.instagram.com',
      'm.instagram.com',
      'instagr.am',
      'www.instagr.am',
    }.contains(host)) {
      return null;
    }
    final List<String> parts;
    try {
      parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    } on FormatException {
      // Invalid UTF-8 in an incoming URL must not break the conversation.
      return null;
    }
    if (parts.length == 3 &&
        parts[0] == 'stories' &&
        RegExp(r'^[0-9]+$').hasMatch(parts[2])) {
      return InstagramShare._(
        Uri.https('www.instagram.com', '/stories/${parts[1]}/${parts[2]}/'),
        false,
      );
    }
    // Instagram also shares /username/reel/shortcode/ links.
    final offset = parts.length == 3 && parts[1] == 'reel' ? 1 : 0;
    if (parts.length != offset + 2) {
      return null;
    }
    final kind = parts[offset];
    final code = parts[offset + 1];
    if (!const {'p', 'reel', 'reels', 'tv'}.contains(kind) ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(code)) {
      return null;
    }
    final canonicalKind = kind == 'reels' ? 'reel' : kind;
    return InstagramShare._(
      Uri.https('www.instagram.com', '/$canonicalKind/$code/'),
      kind == 'reel' || kind == 'reels',
    );
  }
}
