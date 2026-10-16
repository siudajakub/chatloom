// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:http/http.dart' as http;

extension ToBytesWithProgress on http.ByteStream {
  /// Collects the data of this stream in a [Uint8List].
  Future<Uint8List> toBytesWithProgress(void Function(int)? onProgress) async {
    var length = 0;
    final bytes = BytesBuilder(copy: false);
    // A progress guard may reject cancelled or oversized media. Await-for
    // cancels the subscription and forwards that failure to the caller.
    await for (final chunk in this) {
      onProgress?.call(length += chunk.length);
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
