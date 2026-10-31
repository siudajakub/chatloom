// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'opus_container.dart';

/// A voice note remuxed for sending: the Ogg/Opus file and its exact length
/// from the last granule position.
@immutable
class RemuxedVoice {
  final String path;
  final Duration duration;
  const RemuxedVoice(this.path, this.duration);
}

/// Turns the recorder's CAF file at the first path into an Ogg/Opus file at
/// the second one (see [remuxCafVoiceToOgg]).
typedef VoiceRemux = Future<RemuxedVoice> Function(String caf, String ogg);

/// The Ogg bytes and length of a remuxed, validated CAF file; null while the
/// recorder is still writing it.
(Uint8List, int)? _remux((Uint8List, bool) input) {
  final (caf, acceptOpenData) = input;
  try {
    final ogg = cafOpusToOgg(caf, acceptOpenData: acceptOpenData);
    // Never send what our own strict reader would not accept.
    final info = readOggOpus(ogg);
    return (ogg, info.duration.inMicroseconds);
  } on CafIncompleteException {
    return null;
  }
}

/// Remuxes the Opus CAF file the macOS recorder wrote at [cafPath] into
/// Ogg/Opus at [oggPath], losslessly, and validates the result (checksums,
/// granules, end of stream). The recorder finishes the file asynchronously
/// after it reported the stop, so an unfinished file is read again for up to
/// [patience]. Throws when the file is not usable Opus.
Future<RemuxedVoice> remuxCafVoiceToOgg(
  String cafPath,
  String oggPath, {
  Duration patience = const Duration(seconds: 3),
  Duration retryEvery = const Duration(milliseconds: 100),
}) async {
  final clock = Stopwatch()..start();
  int? previousLength;
  var unchanged = 0;
  while (true) {
    final caf = await File(cafPath).readAsBytes();
    unchanged = caf.length == previousLength ? unchanged + 1 : 0;
    previousLength = caf.length;
    // A data chunk left at an open size is accepted once the file stopped
    // growing for a few reads and its packet table fits the data.
    final result = await compute(_remux, (caf, unchanged >= 3));
    if (result != null) {
      final (ogg, micros) = result;
      await File(oggPath).writeAsBytes(ogg, flush: true);
      return RemuxedVoice(oggPath, Duration(microseconds: micros));
    }
    if (clock.elapsed >= patience) {
      throw const CafIncompleteException(
        'The recorder did not finish the file',
      );
    }
    await Future<void>.delayed(retryEvery);
  }
}

/// The CAF file Apple's player needs for an Ogg/Opus voice note. Throws for
/// anything but mono or stereo Ogg/Opus.
Future<Uint8List> oggVoiceToCaf(Uint8List ogg) => compute(oggOpusToCaf, ogg);

/// Whether [bytes] start with an Ogg page (any MIME label).
bool isOggData(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x4F &&
    bytes[1] == 0x67 &&
    bytes[2] == 0x67 &&
    bytes[3] == 0x53;
