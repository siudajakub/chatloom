// SPDX-License-Identifier: AGPL-3.0-or-later
// UX-25/FT-18: chat switching order for the Mac keyboard shortcuts.
import 'package:chatloom/pages/chat_list/inbox_keyboard_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('next/previous follow the list and stop at its ends', () {
    expect(inboxNeighbour(length: 0, current: null, delta: 1), isNull);
    expect(inboxNeighbour(length: 5, current: null, delta: 1), 0);
    expect(inboxNeighbour(length: 5, current: null, delta: -1), 4);
    expect(inboxNeighbour(length: 5, current: 2, delta: 1), 3);
    expect(inboxNeighbour(length: 5, current: 2, delta: -1), 1);
    expect(inboxNeighbour(length: 5, current: 4, delta: 1), isNull);
    expect(inboxNeighbour(length: 5, current: 0, delta: -1), isNull);
  });

  test('next unread continues from the top and skips the open chat', () {
    final unread = {1, 3};
    bool matches(int i) => unread.contains(i);
    expect(inboxNextMatching(length: 5, current: null, matches: matches), 1);
    expect(inboxNextMatching(length: 5, current: 1, matches: matches), 3);
    expect(inboxNextMatching(length: 5, current: 3, matches: matches), 1);
    expect(
      inboxNextMatching(length: 5, current: 1, matches: (i) => i == 1),
      isNull,
    );
    expect(
      inboxNextMatching(length: 0, current: null, matches: matches),
      isNull,
    );
  });
}
