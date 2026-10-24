// SPDX-License-Identifier: AGPL-3.0-or-later
// Stickers are about half the screen's short side, as in Telegram (MD-15).
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('phones: half the short side, between 128 and 200', () {
    // Pixel 8 (412 dp): Telegram's ~205 dp, capped at 200.
    expect(
      ConversationMedia.stickerSideFor(const Size(412, 915), desktop: false),
      200,
    );
    // A small phone (360 dp): 180.
    expect(
      ConversationMedia.stickerSideFor(const Size(360, 780), desktop: false),
      180,
    );
    // Landscape uses the short side too.
    expect(
      ConversationMedia.stickerSideFor(const Size(780, 360), desktop: false),
      180,
    );
    // Tiny windows never go below the old fixed size.
    expect(
      ConversationMedia.stickerSideFor(const Size(200, 300), desktop: false),
      128,
    );
  });

  test('desktop and wide windows: at most 180', () {
    expect(
      ConversationMedia.stickerSideFor(const Size(1440, 900), desktop: true),
      180,
    );
    expect(
      ConversationMedia.stickerSideFor(const Size(420, 800), desktop: true),
      180,
    );
    // A tablet.
    expect(
      ConversationMedia.stickerSideFor(const Size(800, 1280), desktop: false),
      180,
    );
    expect(
      ConversationMedia.stickerSideFor(const Size(300, 700), desktop: true),
      150,
    );
  });

  test('the frame keeps the aspect on the long side', () {
    expect(ConversationMedia.stickerFrame(200), const Size(200, 200));
    expect(
      ConversationMedia.stickerFrame(200, width: 512, height: 256),
      const Size(200, 100),
    );
    expect(
      ConversationMedia.stickerFrame(200, width: 256, height: 512),
      const Size(100, 200),
    );
    // A very wide sticker keeps a usable short edge.
    expect(
      ConversationMedia.stickerFrame(200, width: 1000, height: 10),
      const Size(200, 32),
    );
    expect(
      ConversationMedia.stickerFrame(200, width: 0, height: 10),
      const Size(200, 200),
    );
  });
}
