// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/widgets.dart' show AppLifecycleState;

/// The app remains visible under the notification shade or a system dialog.
bool mobileSyncRunsIn(AppLifecycleState? state) =>
    state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
