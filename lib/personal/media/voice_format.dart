// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/bridge_capabilities.dart';

const opusVoiceMime = 'audio/ogg; codecs=opus';

/// Only label a recording as Opus when its Ogg identification packet says so.
/// An MP4 recording is audio-only AAC: Android writes the generic `mp42`/`isom`
/// brands, which header sniffing reports as `video/mp4`, a type bridges
/// reject for voice.
String voiceRecordingMime(List<int> bytes, String fallback) {
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
    return 'audio/mp4';
  }
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

/// Opus in WebM: Slack's own voice clips (mautrix-slack lists it as fully
/// supported).
const webmOpusVoiceMime = 'audio/webm; codecs=opus';

/// Whether a voice note for a room with [capabilities] is recorded as
/// Ogg/Opus (true) or as AAC in MP4 (false). See docs/voice-recording.md.
///
/// Prefer native support over bridge conversion; retain Opus on unknown
/// bridges. A network whose own voice codec is Opus in another container
/// (Slack: WebM) keeps Opus while the bridge takes Ogg: it only remuxes
/// the stream, whereas an AAC note would need a re-encode it does not do.
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
  if (opus.result.allowed && evidence(webmOpusVoiceMime).supportLevel == 2) {
    return true;
  }
  final aac = evidence('audio/mp4');
  if (aac.result.allowed &&
      (!opus.result.allowed ||
          (aac.supportLevel ?? 0) > (opus.supportLevel ?? 0))) {
    return false;
  }
  return true;
}
