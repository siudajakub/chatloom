// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import '../storage/storage_failure.dart';

/// Web has no native plaintext leases; refuse before any file is created.
class PrivateDirectories {
  static bool create(Directory directory) =>
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
  static bool processMayBeAlive(int process) =>
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
}
