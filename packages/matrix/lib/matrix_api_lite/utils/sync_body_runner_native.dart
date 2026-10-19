// SPDX-FileCopyrightText: 2026 Personal Chat contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:isolate';

/// The decoded graph is returned via `Isolate.exit`, without a second copy.
Future<T> runSyncBodyDecode<T>(T Function() decode) =>
    Isolate.run(decode, debugName: 'matrix_sync_decode');
