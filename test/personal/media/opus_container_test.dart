// Synthetic Opus packets and ffmpeg-generated CAF files only; no recordings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/opus_container.dart';
import 'package:chatloom/personal/media/voice_format.dart';
import 'package:chatloom/personal/media/voice_remux.dart';
import 'package:flutter_test/flutter_test.dart';

/// A CELT fullband packet: [toc] 0xF8 = 20 ms, 0xF0 = 10 ms; code 3 packets
/// (0xFB) carry their frame count in the second byte.
Uint8List packet(int size, {int toc = 0xF8, int seed = 0, int? frames}) {
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (i * 31 + seed * 7 + 3) & 0xFF;
  }
  bytes[0] = toc;
  if (frames != null) bytes[1] = frames;
  return bytes;
}

void _varint(BytesBuilder out, int value) {
  final groups = <int>[];
  do {
    groups.insert(0, value & 0x7F);
    value >>= 7;
  } while (value > 0);
  for (var i = 0; i < groups.length; i++) {
    out.addByte(groups[i] | (i < groups.length - 1 ? 0x80 : 0));
  }
}

/// A CAF file as Apple's and ffmpeg's writers lay it out.
Uint8List buildCaf(
  List<Uint8List> packets, {
  double sampleRate = 48000,
  int channels = 1,
  int framesPerPacket = 960,
  List<int>? frames,
  int priming = 0,
  int remainder = 0,
  Uint8List? cookie,
  String format = 'opus',
  bool openData = false,
  bool packetTable = true,
}) {
  final out = BytesBuilder();
  void chunk(String type, List<int> body, {int? size}) {
    out.add(ascii.encode(type));
    out.add(
      (ByteData(8)..setInt64(0, size ?? body.length)).buffer.asUint8List(),
    );
    out.add(body);
  }

  out.add([...ascii.encode('caff'), 0, 1, 0, 0]);
  final desc = ByteData(32)
    ..setFloat64(0, sampleRate)
    ..setUint32(20, framesPerPacket)
    ..setUint32(24, channels);
  final formatBytes = ascii.encode(format);
  for (var i = 0; i < 4; i++) {
    desc.setUint8(8 + i, formatBytes[i]);
  }
  chunk('desc', desc.buffer.asUint8List());
  if (cookie != null) chunk('kuki', cookie);
  final table = BytesBuilder()
    ..add(
      (ByteData(24)
            ..setInt64(0, packets.length)
            ..setInt64(8, 0)
            ..setInt32(16, priming)
            ..setInt32(20, remainder))
          .buffer
          .asUint8List(),
    );
  for (final (i, p) in packets.indexed) {
    _varint(table, p.length);
    if (framesPerPacket == 0) _varint(table, frames![i]);
  }
  final data = [0, 0, 0, 0, for (final p in packets) ...p];
  if (openData) {
    // Apple's layout while recording: the table first, data last and open.
    if (packetTable) chunk('pakt', table.takeBytes());
    chunk('free', Uint8List(16));
    chunk('data', data, size: -1);
  } else {
    chunk('data', data);
    if (packetTable) chunk('pakt', table.takeBytes());
  }
  return out.takeBytes();
}

/// CRC-32 of an Ogg page computed bit by bit (independent of the library's
/// table).
int bitwiseCrc(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80000000) != 0
          ? ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
          : (crc << 1) & 0xFFFFFFFF;
    }
  }
  return crc;
}

class _Page {
  final int flags, granule, serial, sequence;
  final List<int> lacing;
  const _Page(
    this.flags,
    this.granule,
    this.serial,
    this.sequence,
    this.lacing,
  );
}

/// An Ogg reader written for the test: checks every page's capture pattern,
/// CRC, flags, sequence and lacing, and returns the pages and the packets.
(List<_Page>, List<Uint8List>) parseOgg(Uint8List ogg) {
  final pages = <_Page>[];
  final packets = <Uint8List>[];
  final pending = <int>[];
  var offset = 0;
  while (offset < ogg.length) {
    expect(ascii.decode(ogg.sublist(offset, offset + 4)), 'OggS');
    expect(ogg[offset + 4], 0, reason: 'stream structure version');
    final view = ByteData.sublistView(ogg, offset);
    final count = ogg[offset + 26];
    final lacing = ogg.sublist(offset + 27, offset + 27 + count);
    final bodySize = lacing.fold<int>(0, (a, b) => a + b);
    final end = offset + 27 + count + bodySize;
    final page = Uint8List.fromList(ogg.sublist(offset, end));
    final stored = ByteData.sublistView(page).getUint32(22, Endian.little);
    ByteData.sublistView(page).setUint32(22, 0, Endian.little);
    expect(bitwiseCrc(page), stored, reason: 'CRC of page ${pages.length}');
    final flags = ogg[offset + 5];
    expect(
      (flags & 0x01) != 0,
      pending.isNotEmpty,
      reason: 'continuation flag of page ${pages.length}',
    );
    var at = offset + 27 + count;
    for (final lace in lacing) {
      pending.addAll(ogg.sublist(at, at + lace));
      at += lace;
      if (lace < 255) {
        packets.add(Uint8List.fromList(pending));
        pending.clear();
      }
    }
    pages.add(
      _Page(
        flags,
        view.getInt64(6, Endian.little),
        view.getUint32(14, Endian.little),
        view.getUint32(18, Endian.little),
        lacing,
      ),
    );
    offset = end;
  }
  expect(pending, isEmpty, reason: 'unterminated last packet');
  return (pages, packets);
}

/// Checks [ogg] against the packets it must carry: RFC 7845 headers, page
/// flags and sequence, granules equal to the decoded samples, end trimming
/// to [finalGranule] and the identical packets.
void expectValidOgg(
  Uint8List ogg,
  List<Uint8List> audio, {
  required int channels,
  required int preSkip,
  required int finalGranule,
  int inputSampleRate = 48000,
}) {
  final (pages, packets) = parseOgg(ogg);
  expect(pages.first.flags, 0x02, reason: 'beginning of stream');
  expect(pages.last.flags & 0x04, 0x04, reason: 'end of stream');
  for (final (i, page) in pages.indexed) {
    expect(page.sequence, i);
    expect(page.serial, pages.first.serial);
    expect(page.lacing.length, lessThanOrEqualTo(255));
    if (i > 0) expect(page.flags & 0x02, 0, reason: 'BOS only first');
    if (i < pages.length - 1) expect(page.flags & 0x04, 0);
  }
  // OpusHead and OpusTags each on their own page, granule 0.
  expect(pages[0].lacing, [19]);
  expect(pages[0].granule, 0);
  expect(pages[1].granule, 0);
  final head = ByteData.sublistView(packets[0]);
  expect(ascii.decode(packets[0].sublist(0, 8)), 'OpusHead');
  expect(packets[0][8], 1, reason: 'version');
  expect(packets[0][9], channels);
  expect(head.getUint16(10, Endian.little), preSkip);
  expect(head.getUint32(12, Endian.little), inputSampleRate);
  expect(head.getInt16(16, Endian.little), 0);
  expect(packets[0][18], 0, reason: 'mapping family');
  expect(ascii.decode(packets[1].sublist(0, 8)), 'OpusTags');
  expect(packets.sublist(2), audio, reason: 'packets are copied unchanged');
  // Granules: the running sample count where a packet ends, -1 elsewhere.
  var running = 0, done = 2, last = 0;
  for (final (i, page) in pages.indexed.skip(2)) {
    final ends = page.lacing.where((l) => l < 255).length;
    for (var k = 0; k < ends; k++) {
      running += opusPacketSamples(audio[done++ - 2]);
    }
    if (ends == 0) {
      expect(page.granule, -1);
      continue;
    }
    expect(page.granule, greaterThanOrEqualTo(last));
    last = page.granule;
    expect(
      page.granule,
      i == pages.length - 1 ? finalGranule : running,
      reason: 'granule of page $i',
    );
  }
  expect(done - 2, audio.length);
}

void main() {
  group('Opus packet duration (RFC 6716 TOC)', () {
    test('SILK, hybrid and CELT frame sizes', () {
      // config << 3 | code 0: one frame.
      const expected = {
        0: 480, 1: 960, 2: 1920, 3: 2880, // SILK NB
        11: 2880, // SILK WB 60 ms
        12: 480, 13: 960, 14: 480, 15: 960, // hybrid
        16: 120, 17: 240, 18: 480, 19: 960, // CELT NB
        31: 960, // CELT FB 20 ms
      };
      for (final MapEntry(key: config, value: samples) in expected.entries) {
        expect(opusPacketSamples([config << 3, 0]), samples, reason: '$config');
      }
    });
    test('two-frame and arbitrary-frame packets', () {
      expect(opusPacketSamples([0xF9, 0]), 1920);
      expect(opusPacketSamples([0xFA, 0]), 1920);
      expect(opusPacketSamples([0xFB, 3]), 2880);
      expect(opusPacketSamples([0xFB, 0x83]), 2880, reason: 'VBR flag');
      expect(opusPacketSamples([0x5B, 2]), 5760, reason: '2 × 60 ms');
    });
    test('packets a decoder rejects', () {
      for (final bad in [
        <int>[],
        [0xFB],
        [0xFB, 0],
        [0x5B, 3],
      ]) {
        expect(() => opusPacketSamples(bad), throwsFormatException);
      }
    });
  });

  group('CAF → Ogg/Opus', () {
    test('a VBR note: packets, CRC, granules, pre-skip, end of stream', () {
      final audio = [
        for (var i = 0; i < 120; i++) packet(60 + (i * 37) % 300, seed: i),
      ];
      final ogg = cafOpusToOgg(buildCaf(audio));
      expectValidOgg(
        ogg,
        audio,
        channels: 1,
        preSkip: defaultOpusPreSkip,
        finalGranule: 120 * 960,
      );
      final info = readOggOpus(ogg);
      expect(info.duration, const Duration(microseconds: 2393500));
      expect(info.pages, greaterThan(4), reason: 'about a second per page');
      expect(voiceRecordingMime(ogg, 'audio/x-caf'), opusVoiceMime);
    });

    test('lacing of 255-byte multiples and packets above 255 bytes', () {
      final audio = [
        for (final size in [1, 254, 255, 256, 509, 510, 511, 765, 1275, 255])
          packet(size, seed: size),
      ];
      final ogg = cafOpusToOgg(buildCaf(audio));
      expectValidOgg(
        ogg,
        audio,
        channels: 1,
        preSkip: 312,
        finalGranule: audio.length * 960,
      );
      final (pages, _) = parseOgg(ogg);
      // 255 bytes need a terminating 0 lacing value, 510 two 255s and a 0.
      expect(pages[2].lacing.take(6), [1, 254, 255, 0, 255, 1]);
    });

    test('a long note spreads over many full pages', () {
      // 1500 packets of 400 bytes (2 lacing values each): pages close at
      // one second (50 packets) before 255 lacing values.
      final audio = [for (var i = 0; i < 1500; i++) packet(400, seed: i)];
      final ogg = cafOpusToOgg(buildCaf(audio));
      expectValidOgg(
        ogg,
        audio,
        channels: 1,
        preSkip: 312,
        finalGranule: 1500 * 960,
      );
      expect(readOggOpus(ogg).duration.inMilliseconds, 30000 - 7);
    });

    test('60 ms code-3 packets and 10 ms packets with variable frames', () {
      final audio = [
        for (var i = 0; i < 20; i++) packet(300, toc: 0xFB, frames: 3, seed: i),
        for (var i = 0; i < 5; i++) packet(80, toc: 0xF0, seed: i),
      ];
      final ogg = cafOpusToOgg(
        buildCaf(
          audio,
          framesPerPacket: 0,
          frames: [for (final p in audio) opusPacketSamples(p)],
        ),
      );
      expectValidOgg(
        ogg,
        audio,
        channels: 1,
        preSkip: 312,
        finalGranule: 20 * 2880 + 5 * 480,
      );
    });

    test('priming, remainder and a 16 kHz description scale to 48 kHz', () {
      final audio = [for (var i = 0; i < 10; i++) packet(100, seed: i)];
      // Apple-style: priming 104 and remainder 100 at 16 kHz.
      final ogg = cafOpusToOgg(
        buildCaf(
          audio,
          sampleRate: 16000,
          framesPerPacket: 320,
          priming: 104,
          remainder: 100,
        ),
      );
      expectValidOgg(
        ogg,
        audio,
        channels: 1,
        preSkip: 312,
        inputSampleRate: 16000,
        finalGranule: 10 * 960 - 300,
      );
      expect(readOggOpus(ogg).inputSampleRate, 16000);
    });

    test('an oversized remainder is ignored rather than cut into pages', () {
      final audio = [for (var i = 0; i < 60; i++) packet(100, seed: i)];
      // The last page holds 10 packets (9600 samples): 20000 cannot be cut.
      final ogg = cafOpusToOgg(buildCaf(audio, remainder: 20000));
      expectValidOgg(
        ogg,
        audio,
        channels: 1,
        preSkip: 312,
        finalGranule: 60 * 960,
      );
    });

    test('an OpusHead cookie (ffmpeg) gives pre-skip and gain', () {
      final audio = [for (var i = 0; i < 5; i++) packet(90, seed: i)];
      final cookie = opusHeadPacket(
        channels: 2,
        preSkip: 3840,
        inputSampleRate: 44100,
        outputGain: -256,
      );
      final ogg = cafOpusToOgg(buildCaf(audio, channels: 2, cookie: cookie));
      final info = readOggOpus(ogg);
      expect(info.channels, 2);
      expect(info.preSkip, 3840);
      expect(info.outputGain, -256);
    });

    test('the same recording always remuxes to the same bytes', () {
      final audio = [for (var i = 0; i < 30; i++) packet(150, seed: i)];
      final caf = buildCaf(audio);
      expect(cafOpusToOgg(caf), cafOpusToOgg(caf));
    });

    test('an unfinished file waits; non-Opus and surround fail', () {
      final audio = [for (var i = 0; i < 5; i++) packet(90, seed: i)];
      final complete = buildCaf(audio);
      expect(
        () => readCafOpus(buildCaf(audio, openData: true)),
        throwsA(isA<CafIncompleteException>()),
      );
      expect(
        readCafOpus(
          buildCaf(audio, openData: true),
          acceptOpenData: true,
        ).packets,
        audio,
      );
      expect(
        () => readCafOpus(buildCaf(audio, packetTable: false)),
        throwsA(isA<CafIncompleteException>()),
      );
      expect(
        () => readCafOpus(complete.sublist(0, complete.length - 40)),
        throwsA(isA<CafIncompleteException>()),
      );
      for (final bad in [
        buildCaf(audio, format: 'aac '),
        buildCaf(audio, channels: 6),
        buildCaf([Uint8List(0)]),
        buildCaf([]),
        Uint8List.fromList(ascii.encode('RIFF0000WAVE')),
      ]) {
        expect(
          () => cafOpusToOgg(bad),
          throwsA(
            allOf(isFormatException, isNot(isA<CafIncompleteException>())),
          ),
        );
      }
    });

    test('the strict reader rejects a corrupted page', () {
      final audio = [for (var i = 0; i < 5; i++) packet(90, seed: i)];
      final ogg = cafOpusToOgg(buildCaf(audio));
      final corrupt = Uint8List.fromList(ogg)..[ogg.length - 3] ^= 1;
      expect(() => readOggOpus(corrupt), throwsFormatException);
      expect(readOggOpus(corrupt, strict: false).packets.length, 5);
    });
  });

  group('Ogg/Opus → CAF for the macOS player', () {
    test('round trip keeps every packet; constant frames per packet', () {
      final audio = [
        for (var i = 0; i < 200; i++) packet(40 + (i * 53) % 700, seed: i),
      ];
      final caf = oggOpusToCaf(cafOpusToOgg(buildCaf(audio)));
      final back = readCafOpus(caf);
      expect(back.packets, audio);
      expect(back.framesPerPacket, 960);
      expect(back.sampleRate, 48000);
      expect(back.channels, 1);
    });

    test('variable packet durations write per-packet frame counts', () {
      final audio = [
        packet(300, toc: 0xFB, frames: 3),
        packet(80, toc: 0xF0),
        packet(260),
      ];
      final caf = oggOpusToCaf(
        cafOpusToOgg(
          buildCaf(audio, framesPerPacket: 0, frames: [2880, 480, 960]),
        ),
      );
      final back = readCafOpus(caf);
      expect(back.framesPerPacket, 0);
      expect(back.packets, audio);
    });

    test('Ogg from other encoders: packets spanning pages', () {
      // A hand-made stream whose second audio packet (600 bytes) continues
      // from page 3 onto page 4, as libogg may write it.
      final audio = [packet(100), packet(600, seed: 1), packet(50, seed: 2)];
      final pages = BytesBuilder();
      var sequence = 0;
      void page(int flags, int granule, List<int> lacing, List<int> body) {
        final bytes = Uint8List(27 + lacing.length + body.length);
        final view = ByteData.sublistView(bytes);
        bytes.setRange(0, 4, ascii.encode('OggS'));
        bytes[5] = flags;
        view.setInt64(6, granule, Endian.little);
        view.setUint32(14, 7, Endian.little);
        view.setUint32(18, sequence++, Endian.little);
        bytes[26] = lacing.length;
        bytes.setRange(27, 27 + lacing.length, lacing);
        bytes.setRange(27 + lacing.length, bytes.length, body);
        view.setUint32(22, bitwiseCrc(bytes), Endian.little);
        pages.add(bytes);
      }

      final head = opusHeadPacket(
        channels: 1,
        preSkip: 312,
        inputSampleRate: 48000,
      );
      final tags = [...ascii.encode('OpusTags'), 1, 0, 0, 0, 0x41, 0, 0, 0, 0];
      page(0x02, 0, [19], head);
      page(0, 0, [tags.length], tags);
      page(0, 960, [100, 255, 255], [...audio[0], ...audio[1].take(510)]);
      page(0x05, 2880, [90, 50], [...audio[1].skip(510), ...audio[2]]);
      final ogg = pages.takeBytes();
      expect(readOggOpus(ogg).packets, audio);
      expect(readCafOpus(oggOpusToCaf(ogg)).packets, audio);
    });

    test('Ogg detection by bytes', () {
      expect(isOggData(ascii.encode('OggS\x00')), isTrue);
      expect(isOggData(ascii.encode('caff')), isFalse);
      expect(isOggData([0x4F]), isFalse);
    });
  });

  group('file remux', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('opus'));
    tearDown(() async => dir.delete(recursive: true));

    test('waits for the recorder to finish the file', () async {
      final audio = [for (var i = 0; i < 50; i++) packet(120, seed: i)];
      final caf = File('${dir.path}/voice.caf');
      // Stopped but not finalised: no packet table yet.
      await caf.writeAsBytes(buildCaf(audio, packetTable: false));
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 60),
          () => caf.writeAsBytes(buildCaf(audio)),
        ),
      );
      final result = await remuxCafVoiceToOgg(
        caf.path,
        '${dir.path}/voice.ogg',
        retryEvery: const Duration(milliseconds: 10),
      );
      expect(result.path, '${dir.path}/voice.ogg');
      expect(
        result.duration,
        const Duration(milliseconds: 993, microseconds: 500),
      );
      expectValidOgg(
        await File(result.path).readAsBytes(),
        audio,
        channels: 1,
        preSkip: 312,
        finalGranule: 50 * 960,
      );
    });

    test('an open data chunk that stopped growing is complete', () async {
      final audio = [for (var i = 0; i < 10; i++) packet(120, seed: i)];
      final caf = File('${dir.path}/voice.caf');
      await caf.writeAsBytes(buildCaf(audio, openData: true));
      final result = await remuxCafVoiceToOgg(
        caf.path,
        '${dir.path}/voice.ogg',
        retryEvery: const Duration(milliseconds: 5),
      );
      expect(readOggOpus(await File(result.path).readAsBytes()).packets, audio);
    });

    test(
      'gives up after its patience; a non-Opus file fails at once',
      () async {
        final caf = File('${dir.path}/voice.caf')
          ..writeAsBytesSync(buildCaf([packet(90)], packetTable: false));
        await expectLater(
          remuxCafVoiceToOgg(
            caf.path,
            '${dir.path}/voice.ogg',
            patience: const Duration(milliseconds: 50),
            retryEvery: const Duration(milliseconds: 10),
          ),
          throwsA(isA<CafIncompleteException>()),
        );
        final aac = File('${dir.path}/aac.caf')
          ..writeAsBytesSync(buildCaf([packet(90)], format: 'aac '));
        await expectLater(
          remuxCafVoiceToOgg(aac.path, '${dir.path}/aac.ogg'),
          throwsFormatException,
        );
      },
    );
  });

  group('ffmpeg/libopus CAF files (decoded by ffmpeg)', () {
    final ffmpeg = _tool('ffmpeg') && _tool('ffprobe');
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('opus'));
    tearDown(() async => dir.delete(recursive: true));

    // name, seconds, channels, extra encoder arguments.
    const cases = <(String, double, int, List<String>)>[
      ('64 kbit/s VBR voice note', 2, 1, ['-b:a', '64k']),
      // CBR 102 kbit/s: every 20 ms packet is exactly 255 bytes.
      ('255-byte packets', 3, 1, ['-b:a', '102k', '-vbr', 'off']),
      // 510-byte packets, stereo, about 8 pages.
      ('510-byte stereo packets', 8, 2, ['-b:a', '204k', '-vbr', 'off']),
      // 60 ms code-3 packets over many pages.
      ('60 ms frames', 12, 1, ['-b:a', '96k', '-frame_duration', '60']),
    ];
    for (final (name, seconds, channels, args) in cases) {
      test(name, skip: ffmpeg ? false : 'ffmpeg not installed', () async {
        final caf = '${dir.path}/in.caf';
        await _run('ffmpeg', [
          '-v', 'error', '-y', '-f', 'lavfi', //
          '-i', 'sine=frequency=440:duration=$seconds',
          '-ac', '$channels', '-ar', '48000', '-c:a', 'libopus', ...args, caf,
        ]);
        final result = await remuxCafVoiceToOgg(caf, '${dir.path}/out.ogg');
        final ogg = await File(result.path).readAsBytes();
        final source = readCafOpus(await File(caf).readAsBytes());
        expectValidOgg(
          ogg,
          source.packets,
          channels: channels,
          preSkip: 312,
          finalGranule: source.packets.fold(
            0,
            (sum, p) => sum + opusPacketSamples(p),
          ),
        );
        if (args.contains('102k')) {
          expect(source.packets.where((p) => p.length == 255), isNotEmpty);
        }
        final probe = jsonDecode(
          await _run('ffprobe', [
            '-v', 'error', '-print_format', 'json', '-show_streams', //
            result.path,
          ]),
        );
        final stream = (probe['streams'] as List).single as Map;
        expect(stream['codec_name'], 'opus');
        expect(stream['sample_rate'], '48000');
        expect(stream['channels'], channels);
        // Decoding prints nothing at "error" level and yields the length
        // the granules state, within one 20 ms frame of the source.
        final samples = await _decodedSamples(result.path, channels);
        expect(samples, result.duration.inMicroseconds * 48 ~/ 1000);
        expect(
          (samples - seconds * 48000).abs(),
          lessThanOrEqualTo(args.contains('60') ? 2880 : 960),
        );
        // Lossless: the CAF decodes to the same PCM plus the pre-skip.
        expect(await _decodedSamples(caf, channels), samples + 312);
      });
    }
  });
}

bool _tool(String name) {
  try {
    return Process.runSync(name, ['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<String> _run(String tool, List<String> args) async {
  final result = await Process.run(tool, args);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect('${result.stderr}'.trim(), isEmpty, reason: '$tool reported errors');
  return '${result.stdout}';
}

Future<int> _decodedSamples(String path, int channels) async {
  final result = await Process.run('ffmpeg', [
    '-v', 'error', '-xerror', '-i', path, '-f', 's16le', '-', //
  ], stdoutEncoding: null);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect('${result.stderr}'.trim(), isEmpty);
  return (result.stdout as List<int>).length ~/ (2 * channels);
}
