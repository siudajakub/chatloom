// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'flows/auth_flows.dart';
import 'flows/basic_messaging.dart';
import 'flows/login_and_chat_backup.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('FluffyChat Integration Tests', () {
    testWidgets('Login and logout flow', loginAndChatBackup);
    testWidgets('Basic Messaging', basicMessaging);
    testWidgets('Final logout', finalLogout);
  });
}
