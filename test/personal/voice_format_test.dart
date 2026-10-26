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
