// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/chatloom_tester.dart';

extension ChatFlows on ChatLoomTester {
  static const String groupChatName = 'Test Group 01';

  Future<void> ensureGroupChatCreated() async {
    if (await isVisible(groupChatName)) return;
    await tapOn(FloatingActionButton);
    await tapOn('Create group');
    await enterText(TextField, groupChatName);
    await scrollUntilVisible('Create a group and invite users');
    await tapOn('Create a group and invite users');
    await waitFor('Invite contact');
    await goBack();
    await goBack();
  }
}
