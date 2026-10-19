// SPDX-FileCopyrightText: 2026 Personal Chat contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Web has no shared-heap isolates; decode inline as upstream does.
Future<T> runSyncBodyDecode<T>(T Function() decode) => Future.sync(decode);
