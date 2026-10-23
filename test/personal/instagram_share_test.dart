// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/instagram_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes public permalinks in messages from any network', () {
    for (final kind in ['reel', 'reels', 'p', 'tv']) {
      final share = InstagramShare.fromText(
        'Watch this: https://m.instagram.com/$kind/Ab_12-/?igsh=tracking',
      );
      expect(share, isNotNull);
      expect(share!.url.query, isEmpty);
      expect(share.embedUrl.path, endsWith('/embed/'));
    }
    expect(
      InstagramShare.fromText('(https://instagram.com/p/Ab12).')!.url.path,
      '/p/Ab12/',
    );
    expect(
      InstagramShare.fromText(
        'https://www.instagram.com/author/reel/Ab12/',
      )!.reel,
      isTrue,
    );
  });
  test('ignores quoted originals and chooses the new message link', () {
    expect(
      InstagramShare.fromText('> https://instagram.com/p/Quoted/\n\nhello'),
      isNull,
    );
    expect(
      InstagramShare.fromText(
        '> https://instagram.com/p/Quoted/\n\nhttps://instagram.com/reel/New/',
      )!.url.path,
      '/reel/New/',
    );
  });
  test('rejects lookalike hosts, credentials, malformed paths and invalid story IDs', () {
    for (final url in [
      'https://instagram.com.evil.test/p/Ab12/',
      'https://evil.test/instagram.com/p/Ab12/',
      'https://user@instagram.com/p/Ab12/',
      'https://instagram.com:444/p/Ab12/',
      'https://instagram.com/p/Ab12/extra/',
      'https://instagram.com/p/%3Cscript%3E/',
      'https://instagram.com/p/%FF/',
      'https://instagram.com/stories/author/not-a-number/',
      'https://instagram.com/author/',
      'javascript:alert(1)',
    ]) {
      expect(InstagramShare.fromUrl(url), isNull, reason: url);
    }
  });
  test('recognizes active stories and highlights without tracking parameters', () {
    for (final path in [
      '/stories/author/123456789/',
      '/stories/highlights/18001704114005607/',
    ]) {
      final share = InstagramShare.fromUrl(
        'https://www.instagram.com$path?hl=en',
      );
      expect(share, isNotNull);
      expect(share!.url.path, path);
      expect(share.url.query, isEmpty);
    }
  });

}
