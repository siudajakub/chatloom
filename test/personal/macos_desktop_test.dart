// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => PersonalPrivacy.surfaceUnlocked = true);

  test('a disposed inbox cannot remove its replacement search binding', () {
    final oldInbox = Object();
    final currentInbox = Object();
    var oldCalls = 0;
    var currentCalls = 0;
    MacDesktopCommands.bindSearch(oldInbox, () => oldCalls++);
    MacDesktopCommands.bindSearch(currentInbox, () => currentCalls++);
    MacDesktopCommands.unbindSearch(oldInbox);
    MacDesktopCommands.search();
    expect(oldCalls, 0);
    expect(currentCalls, 1);
    MacDesktopCommands.unbindSearch(currentInbox);
    MacDesktopCommands.search();
    expect(currentCalls, 1);
  });

  test('native and keyboard search cannot navigate through the app lock', () {
    final owner = Object();
    var calls = 0;
    MacDesktopCommands.bindSearch(owner, () => calls++);
    PersonalPrivacy.surfaceUnlocked = false;
    MacDesktopCommands.search();
    expect(calls, 0);
    PersonalPrivacy.surfaceUnlocked = true;
    MacDesktopCommands.search();
    expect(calls, 1);
    MacDesktopCommands.unbindSearch(owner);
  });
}
