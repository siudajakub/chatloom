// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/bridge_capabilities.dart';

const opusVoiceMime = 'audio/ogg; codecs=opus';

/// Only label a recording as Opus when its Ogg identification packet says so.
String voiceRecordingMime(List<int> bytes, String fallback) {
  if (bytes.length >= 36 && String.fromCharCodes(bytes.take(4)) == 'OggS') {
    final segments = bytes[26];
    final offset = 27 + segments;
    if (segments > 0 &&
        bytes.length >= offset + 8 &&
        String.fromCharCodes(bytes.sublist(offset, offset + 8)) == 'OpusHead') {
      return opusVoiceMime;
    }
  }
  return fallback;
}

/// Prefer native support over bridge conversion; retain Opus on unknown bridges.
bool preferOpusVoice(BridgeRoomCapabilities capabilities) {
  BridgeCapabilityEvidence evidence(String mime) => capabilities.evidence(
    BridgeFeature.voice,
    media: BridgeMediaRequest(
      mimeType: mime,
      sizeBytes: 0,
      durationSeconds: 0,
      width: 0,
      height: 0,
    ),
  );
  final opus = evidence(opusVoiceMime);
  final aac = evidence('audio/mp4');
  if (aac.result.allowed &&
      (!opus.result.allowed ||
          (aac.supportLevel ?? 0) > (opus.supportLevel ?? 0))) {
    return false;
  }
  return true;
}
