// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/automatic_push.dart';

/// Tests run as a build whose push gateway was set with
/// `--dart-define=CHATLOOM_PUSH_GATEWAY=...` (see docs/DEVELOPMENT.md).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugPushGatewayOrigin = 'https://push.example.invalid';
  await testMain();
}
