import 'package:chatloom/personal/media/voice_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_core/bridge_capabilities.dart';

void main() {
  BridgeRoomCapabilities caps(Map<String, int> mimes) =>
      BridgeRoomCapabilities.fromState({
        'file': {
          'org.matrix.msc3245.voice': {'mime_types': mimes},
        },
      });
  test('WhatsApp requires qualified Opus, Telegram retains Opus', () {
    expect(preferOpusVoice(caps({opusVoiceMime: 2, 'audio/ogg': 0})), isTrue);
    expect(preferOpusVoice(caps({'audio/ogg': 2, 'audio/mp4': 2})), isTrue);
  });
  test('Instagram and Messenger prefer native AAC over Ogg conversion', () {
    for (final ogg in [-2, 1]) {
      expect(
        preferOpusVoice(caps({'audio/mp4': 2, 'audio/ogg': ogg})),
        isFalse,
      );
    }
    expect(preferOpusVoice(BridgeRoomCapabilities.fromState(null)), isTrue);
  });
  group('per-network voice codec (bridge capability declarations)', () {
    // The voice MIME maps each bridge declares (docs/voice-recording.md);
    // ffmpeg turns their "convertible" entries from -2 into 1.
    const ffmpeg = 1, noFfmpeg = -2;
    final networks = <String, (Map<String, int>, bool)>{
      'Telegram': ({'audio/ogg': 2, 'audio/mpeg': 2, 'audio/mp4': 2}, true),
      'WhatsApp': ({opusVoiceMime: 2, 'audio/ogg': 0}, true),
      'Messenger/Instagram': ({'audio/mp4': 2, 'audio/ogg': ffmpeg}, false),
      'Messenger/Instagram without ffmpeg': (
        {'audio/mp4': 2, 'audio/ogg': noFfmpeg},
        false,
      ),
      // Ogg/Opus is remuxed into WebM; AAC would be copied into WebM and fail.
      'Slack': (
        {'audio/ogg': ffmpeg, webmOpusVoiceMime: 2, 'audio/mp4': 2},
        true,
      ),
      // Without ffmpeg the bridge takes AAC as a Slack audio clip directly.
      'Slack without ffmpeg': (
        {'audio/ogg': noFfmpeg, webmOpusVoiceMime: 2, 'audio/mp4': 2},
        false,
      ),
      // AAC must be ADTS (audio/aac); the bridge re-encodes Ogg/Opus to it.
      'Signal': ({'audio/aac': 2, 'audio/ogg': ffmpeg}, true),
    };
    for (final MapEntry(key: network, value: (mimes, opus))
        in networks.entries) {
      test('$network records ${opus ? 'Ogg/Opus' : 'AAC in MP4'}', () {
        expect(preferOpusVoice(caps(mimes)), opus);
      });
    }
    test('a room without declarations keeps Opus', () {
      expect(preferOpusVoice(BridgeRoomCapabilities.fromState(null)), isTrue);
      expect(preferOpusVoice(caps({})), isTrue);
    });
  });
  test('Opus MIME is based on the identification packet, never the name', () {
    final bytes = List<int>.filled(47, 0);
    bytes.setRange(0, 4, 'OggS'.codeUnits);
    bytes[26] = 1;
    bytes[27] = 19;
    bytes.setRange(28, 36, 'OpusHead'.codeUnits);
    expect(voiceRecordingMime(bytes, 'audio/ogg'), opusVoiceMime);
    bytes[28] = 0;
    expect(voiceRecordingMime(bytes, 'audio/ogg'), 'audio/ogg');
    expect(voiceRecordingMime([1, 2], 'audio/mp4'), 'audio/mp4');
  });
  test('Android AAC recordings are audio/mp4, not sniffed video/mp4', () {
    for (final brand in ['mp42', 'isom', 'M4A ']) {
      final bytes = [0, 0, 0, 0x18, ...'ftyp$brand'.codeUnits, 0, 0, 0, 0];
      expect(voiceRecordingMime(bytes, 'video/mp4'), 'audio/mp4');
    }
  });
}
