// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';

/// Lossless Opus remuxing between Apple's Core Audio Format (CAF), which
/// the macOS recorder writes, and Ogg (RFC 7845), which bridges, Telegram
/// and WhatsApp expect for voice notes. The Opus packets are copied
/// unchanged; only the container around them is rewritten.
///
/// Replaces `ogg_caf_converter` 0.1.4, whose CAF → Ogg path read the CAF
/// packet table byte by byte instead of as variable-length integers, wrote
/// a CRC from a table truncated to 8 bits, marked the first audio page as a
/// continuation (libogg drops its first packet), never terminated a packet
/// whose size is a multiple of 255, and took the frames per packet as the
/// pre-skip. Its Ogg → CAF path stored packet sizes in bytes (every packet
/// of 256 bytes or more was cut) and split packets that span pages.
/// See docs/voice-recording.md.

/// Ogg/Opus granule positions always count 48 kHz samples.
const opusGranuleRate = 48000;

/// The encoder delay libopus reports at 48 kHz (`OPUS_GET_LOOKAHEAD`),
/// used as the pre-skip when the CAF file does not state its priming.
const defaultOpusPreSkip = 312;

/// A CAF file that the recorder has not finished writing: its audio data
/// still has an open size or its packet table is missing or short. Reading
/// it again a little later may succeed.
class CafIncompleteException extends FormatException {
  const CafIncompleteException(super.message);
}

/// Samples per channel at 48 kHz in one Opus [packet] (RFC 6716 §3.1).
/// Throws [FormatException] for a packet a decoder would reject.
int opusPacketSamples(List<int> packet) {
  if (packet.isEmpty) throw const FormatException('Empty Opus packet');
  final toc = packet[0];
  final config = toc >> 3;
  final int frame;
  if (config < 12) {
    // SILK: 10, 20, 40, 60 ms.
    frame = const [480, 960, 1920, 2880][config & 3];
  } else if (config < 16) {
    // Hybrid: 10, 20 ms.
    frame = config.isEven ? 480 : 960;
  } else {
    // CELT: 2.5, 5, 10, 20 ms.
    frame = const [120, 240, 480, 960][config & 3];
  }
  final int frames;
  switch (toc & 3) {
    case 0:
      frames = 1;
    case 1:
    case 2:
      frames = 2;
    default:
      if (packet.length < 2) {
        throw const FormatException('Truncated Opus packet');
      }
      frames = packet[1] & 0x3F;
      if (frames == 0) throw const FormatException('Opus packet of 0 frames');
  }
  final samples = frame * frames;
  if (samples > 5760) {
    throw const FormatException('Opus packet longer than 120 ms');
  }
  return samples;
}

/// The Opus stream of a CAF file ([readCafOpus]).
class CafOpus {
  /// The stream's nominal rate (`mSampleRate`); frame counts below use it.
  final double sampleRate;
  final int channels;

  /// Frames per packet from the description, 0 when it varies.
  final int framesPerPacket;
  final int primingFrames, remainderFrames;

  /// The `OpusHead` packet when the magic cookie holds one (ffmpeg's CAF);
  /// Apple's cookie has another layout and is ignored.
  final Uint8List? opusHead;
  final List<Uint8List> packets;

  const CafOpus({
    required this.sampleRate,
    required this.channels,
    required this.framesPerPacket,
    required this.primingFrames,
    required this.remainderFrames,
    required this.opusHead,
    required this.packets,
  });

  int _to48k(int frames) =>
      math.max(0, (frames * opusGranuleRate / sampleRate).round());

  /// The Ogg pre-skip: the CAF priming frames, else the cookie's pre-skip,
  /// else libopus' encoder delay.
  int get preSkip {
    final priming = _to48k(primingFrames);
    if (priming > 0 && priming <= 0xFFFF) return priming;
    final head = opusHead;
    if (head != null) {
      final skip = head[10] | head[11] << 8;
      if (skip > 0) return skip;
    }
    return defaultOpusPreSkip;
  }

  /// Samples (48 kHz) the encoder appended after the end of the audio.
  int get endPadding => _to48k(remainderFrames);
}

int _readVarint(Uint8List bytes, List<int> cursor, int end) {
  var value = 0;
  for (var i = 0; i < 5; i++) {
    final at = cursor[0];
    if (at >= end) throw const CafIncompleteException('Short packet table');
    final byte = bytes[at];
    cursor[0] = at + 1;
    value = (value << 7) | (byte & 0x7F);
    if (byte & 0x80 == 0) return value;
  }
  throw const FormatException('Packet table entry too long');
}

String _fourCc(Uint8List bytes, int at) =>
    String.fromCharCodes(bytes.sublist(at, at + 4));

/// Parses the Opus stream of a CAF file. Throws [CafIncompleteException]
/// while the recorder is still finishing the file and [FormatException] for
/// anything that is not mono or stereo Opus in CAF. [acceptOpenData] reads
/// a data chunk of open size (-1) as complete when its packet table fits;
/// only for a file that stopped changing.
CafOpus readCafOpus(Uint8List bytes, {bool acceptOpenData = false}) {
  // The recorder creates the file before it writes the header.
  if (bytes.length < 8) throw const CafIncompleteException('Short CAF file');
  if (_fourCc(bytes, 0) != 'caff') {
    throw const FormatException('Not a CAF file');
  }
  final view = ByteData.sublistView(bytes);
  if (view.getUint16(4) != 1) {
    throw const FormatException('Unsupported CAF version');
  }
  ByteData? desc;
  ByteData? pakt;
  Uint8List? cookie;
  int? dataStart, dataEnd;
  var dataOpen = false;
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final type = _fourCc(bytes, offset);
    final size = view.getInt64(offset + 4);
    final body = offset + 12;
    if (type == 'data') {
      // An open size (-1) is only valid for a last data chunk.
      final end = size < 0 ? bytes.length : body + size;
      if (size < 0 || end > bytes.length) dataOpen = true;
      if (size >= 0 && size < 4) {
        throw const FormatException('Short CAF data chunk');
      }
      dataStart = body + 4; // edit count
      dataEnd = math.min(end, bytes.length);
      if (size < 0) break;
      offset = end;
      continue;
    }
    if (size < 0 || body + size > bytes.length) {
      throw const CafIncompleteException('Truncated CAF chunk');
    }
    switch (type) {
      case 'desc':
        if (size < 32) throw const FormatException('Short CAF description');
        desc = ByteData.sublistView(bytes, body, body + 32);
      case 'pakt':
        if (size < 24) throw const CafIncompleteException('Short packet table');
        pakt = ByteData.sublistView(bytes, body, body + size);
      case 'kuki':
        cookie = bytes.sublist(body, body + size);
    }
    offset = body + size;
  }
  if (desc == null) throw const FormatException('CAF without description');
  final sampleRate = desc.getFloat64(0);
  final format = String.fromCharCodes(
    desc.buffer.asUint8List(desc.offsetInBytes + 8, 4),
  );
  final bytesPerPacket = desc.getUint32(16);
  final framesPerPacket = desc.getUint32(20);
  final channels = desc.getUint32(24);
  if (format != 'opus') throw FormatException('CAF holds $format, not Opus');
  if (!(sampleRate > 0)) throw const FormatException('Invalid sample rate');
  if (channels < 1 || channels > 2) {
    throw FormatException('Unsupported channel count $channels');
  }
  if (dataStart == null || dataEnd == null || dataEnd < dataStart) {
    throw const CafIncompleteException('CAF without audio data');
  }
  final packets = <Uint8List>[];
  var primingFrames = 0, remainderFrames = 0;
  if (bytesPerPacket > 0) {
    // Constant bit rate: no packet table needed.
    if (framesPerPacket == 0) {
      throw const FormatException('CBR CAF without frames per packet');
    }
    for (var at = dataStart; at + bytesPerPacket <= dataEnd;) {
      packets.add(bytes.sublist(at, at + bytesPerPacket));
      at += bytesPerPacket;
    }
    if (pakt != null) {
      primingFrames = pakt.getInt32(16);
      remainderFrames = pakt.getInt32(20);
    }
  } else {
    if (pakt == null) throw const CafIncompleteException('No packet table');
    final count = pakt.getInt64(0);
    primingFrames = pakt.getInt32(16);
    remainderFrames = pakt.getInt32(20);
    if (count < 0) throw const FormatException('Invalid packet count');
    final table = pakt.buffer.asUint8List(
      pakt.offsetInBytes,
      pakt.lengthInBytes,
    );
    final cursor = [24];
    var at = dataStart;
    for (var i = 0; i < count; i++) {
      final size = _readVarint(table, cursor, table.length);
      if (framesPerPacket == 0) _readVarint(table, cursor, table.length);
      if (at + size > dataEnd) {
        throw const CafIncompleteException('Audio data shorter than table');
      }
      packets.add(bytes.sublist(at, at + size));
      at += size;
    }
  }
  if (dataOpen && !acceptOpenData) {
    // The table and the data agree, but the recorder has not closed the
    // data chunk: more packets may still follow.
    throw const CafIncompleteException('CAF data chunk still open');
  }
  if (packets.isEmpty) throw const FormatException('CAF without packets');
  for (final packet in packets) {
    opusPacketSamples(packet);
  }
  final head =
      cookie != null &&
          cookie.length >= 19 &&
          String.fromCharCodes(cookie.sublist(0, 8)) == 'OpusHead'
      ? cookie
      : null;
  return CafOpus(
    sampleRate: sampleRate,
    channels: channels,
    framesPerPacket: framesPerPacket,
    primingFrames: math.max(0, primingFrames),
    remainderFrames: math.max(0, remainderFrames),
    opusHead: head,
    packets: packets,
  );
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var r = i << 24;
    for (var j = 0; j < 8; j++) {
      r = (r & 0x80000000) != 0 ? (r << 1) ^ 0x04C11DB7 : r << 1;
      r &= 0xFFFFFFFF;
    }
    table[i] = r;
  }
  return table;
}();

/// The Ogg page checksum (CRC-32, polynomial 0x04C11DB7, no reflection).
int oggCrc(Uint8List page) {
  var crc = 0;
  for (final byte in page) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) & 0xFF) ^ byte];
  }
  return crc;
}

class _OggWriter {
  final int serial;
  final BytesBuilder out = BytesBuilder(copy: false);
  final List<int> _lacing = [];
  final BytesBuilder _body = BytesBuilder();
  int _sequence = 0, _granule = -1, _pageSamples = 0;

  /// Granule position of the last page written that carried one.
  int lastPageGranule = 0;
  bool _continued = false, _started = false;

  _OggWriter(this.serial);

  /// Appends [packet], ending at [granule]. A page holds at most about a
  /// second of audio, like opusenc; [flushAfter] closes it after this packet
  /// and [last] keeps it open for [finish].
  void add(
    Uint8List packet, {
    required int granule,
    int samples = 0,
    bool flushAfter = false,
    bool last = false,
  }) {
    final lacing = [
      for (var i = 0; i < packet.length ~/ 255; i++) 255,
      packet.length % 255,
    ];
    if (_lacing.isNotEmpty && _lacing.length + lacing.length > 255) {
      _flush();
    }
    var used = 0, offset = 0;
    while (true) {
      final take = math.min(255 - _lacing.length, lacing.length - used);
      final bytes = lacing
          .sublist(used, used + take)
          .fold<int>(0, (sum, v) => sum + v);
      _lacing.addAll(lacing.sublist(used, used + take));
      _body.add(Uint8List.sublistView(packet, offset, offset + bytes));
      used += take;
      offset += bytes;
      if (used == lacing.length) break;
      // Only a packet above 64 KB spans pages; Opus packets never do.
      _flush(endsInPacket: true);
    }
    _granule = granule;
    _pageSamples += samples;
    if (!last && (flushAfter || _pageSamples >= opusGranuleRate)) _flush();
  }

  void _flush({bool endsInPacket = false, bool last = false}) {
    if (_lacing.isEmpty && !last) return;
    final body = _body.takeBytes();
    final header = ByteData(27 + _lacing.length);
    for (var i = 0; i < 4; i++) {
      header.setUint8(i, 'OggS'.codeUnitAt(i));
    }
    header.setUint8(4, 0);
    header.setUint8(
      5,
      (_continued ? 0x01 : 0) | (_started ? 0 : 0x02) | (last ? 0x04 : 0),
    );
    header.setInt64(6, _granule, Endian.little);
    header.setUint32(14, serial, Endian.little);
    header.setUint32(18, _sequence++, Endian.little);
    header.setUint32(22, 0, Endian.little);
    header.setUint8(26, _lacing.length);
    for (var i = 0; i < _lacing.length; i++) {
      header.setUint8(27 + i, _lacing[i]);
    }
    final page = Uint8List(header.lengthInBytes + body.length)
      ..setRange(0, header.lengthInBytes, header.buffer.asUint8List())
      ..setRange(
        header.lengthInBytes,
        header.lengthInBytes + body.length,
        body,
      );
    ByteData.sublistView(page).setUint32(22, oggCrc(page), Endian.little);
    out.add(page);
    if (_granule != -1) lastPageGranule = _granule;
    _started = true;
    _continued = endsInPacket;
    _granule = -1;
    _pageSamples = 0;
    _lacing.clear();
  }

  /// Closes the stream: the last page carries the end-of-stream flag and
  /// [finalGranule] (end trimming, RFC 7845 §4.4).
  Uint8List finish(int finalGranule) {
    _granule = finalGranule;
    _flush(last: true);
    return out.takeBytes();
  }
}

/// The `OpusHead` identification packet (RFC 7845 §5.1), channel mapping
/// family 0 (mono or stereo).
Uint8List opusHeadPacket({
  required int channels,
  required int preSkip,
  required int inputSampleRate,
  int outputGain = 0,
}) {
  final head = ByteData(19);
  const magic = 'OpusHead';
  for (var i = 0; i < magic.length; i++) {
    head.setUint8(i, magic.codeUnitAt(i));
  }
  head.setUint8(8, 1);
  head.setUint8(9, channels);
  head.setUint16(10, preSkip, Endian.little);
  head.setUint32(12, inputSampleRate, Endian.little);
  head.setInt16(16, outputGain, Endian.little);
  head.setUint8(18, 0);
  return head.buffer.asUint8List();
}

Uint8List _opusTagsPacket(String vendor) {
  final vendorBytes = vendor.codeUnits;
  final tags = ByteData(8 + 4 + vendorBytes.length + 4);
  const magic = 'OpusTags';
  for (var i = 0; i < magic.length; i++) {
    tags.setUint8(i, magic.codeUnitAt(i));
  }
  tags.setUint32(8, vendorBytes.length, Endian.little);
  for (var i = 0; i < vendorBytes.length; i++) {
    tags.setUint8(12 + i, vendorBytes[i]);
  }
  tags.setUint32(12 + vendorBytes.length, 0, Endian.little);
  return tags.buffer.asUint8List();
}

/// A stable stream serial for [packets], so the same recording always
/// remuxes to the same bytes (a retried send keeps its digest).
int _serialFor(List<Uint8List> packets) {
  var hash = 0x811C9DC5;
  for (final packet in packets.take(64)) {
    for (final byte in packet.take(32)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
  }
  return hash;
}

/// Remuxes the Opus stream of a CAF file into Ogg/Opus (RFC 7845), packet
/// for packet. Throws like [readCafOpus].
Uint8List cafOpusToOgg(
  Uint8List caf, {
  int? serial,
  bool acceptOpenData = false,
}) {
  final stream = readCafOpus(caf, acceptOpenData: acceptOpenData);
  final preSkip = stream.preSkip;
  final writer = _OggWriter(serial ?? _serialFor(stream.packets));
  final head = stream.opusHead;
  final outputGain = head == null ? 0 : (head[16] | head[17] << 8).toSigned(16);
  writer.add(
    opusHeadPacket(
      channels: stream.channels,
      preSkip: preSkip,
      inputSampleRate: stream.sampleRate.round(),
      outputGain: outputGain,
    ),
    granule: 0,
    flushAfter: true,
  );
  writer.add(_opusTagsPacket('ChatLoom'), granule: 0, flushAfter: true);
  final samples = [for (final p in stream.packets) opusPacketSamples(p)];
  var granule = 0;
  for (var i = 0; i < stream.packets.length - 1; i++) {
    granule += samples[i];
    writer.add(stream.packets[i], granule: granule, samples: samples[i]);
  }
  // The last packet: trim the encoder's padding, but never below the
  // previous page's granule or the pre-skip.
  final total = granule + samples.last;
  writer.add(
    stream.packets.last,
    granule: total,
    samples: samples.last,
    last: true,
  );
  final trimmed = total - stream.endPadding;
  return writer.finish(
    trimmed >= math.max(writer.lastPageGranule, preSkip) ? trimmed : total,
  );
}

/// One Ogg/Opus stream as [readOggOpus] found it.
class OggOpus {
  final int channels, preSkip, inputSampleRate, outputGain;
  final List<Uint8List> packets;

  /// Decoded samples (48 kHz) of each packet in [packets].
  final List<int> packetSamples;
  final int finalGranule, pages;

  const OggOpus({
    required this.channels,
    required this.preSkip,
    required this.inputSampleRate,
    required this.outputGain,
    required this.packets,
    required this.packetSamples,
    required this.finalGranule,
    required this.pages,
  });

  int get totalSamples => packetSamples.fold(0, (sum, s) => sum + s);

  /// Playback length: the last granule minus the pre-skip.
  Duration get duration => Duration(
    microseconds:
        (math.max(0, finalGranule - preSkip) * 1000000) ~/ opusGranuleRate,
  );
}

/// Reads the first Ogg/Opus stream of [ogg]. With [strict] (our own
/// remuxed files) every page checksum, the page sequence, the stream flags
/// and every granule position must be exact; otherwise only the structure
/// needed to recover the packets is required (received files).
OggOpus readOggOpus(Uint8List ogg, {bool strict = true}) {
  final view = ByteData.sublistView(ogg);
  int? serial;
  var offset = 0, sequence = 0, pages = 0, lastGranule = 0;
  var sawEos = false;
  final packets = <Uint8List>[];
  final pending = BytesBuilder();
  var pendingOpen = false;
  // Per page with a granule: the packets completed so far, the granule.
  final pageGranules = <(int, int)>[];
  while (offset + 27 <= ogg.length) {
    if (_fourCc(ogg, offset) != 'OggS') {
      throw FormatException('No Ogg page at $offset');
    }
    final flags = ogg[offset + 5];
    final granule = view.getInt64(offset + 6, Endian.little);
    final pageSerial = view.getUint32(offset + 14, Endian.little);
    final pageSequence = view.getUint32(offset + 18, Endian.little);
    final segments = ogg[offset + 26];
    final bodyStart = offset + 27 + segments;
    if (bodyStart > ogg.length) throw const FormatException('Short Ogg page');
    var bodySize = 0;
    for (var i = 0; i < segments; i++) {
      bodySize += ogg[offset + 27 + i];
    }
    final end = bodyStart + bodySize;
    if (end > ogg.length) throw const FormatException('Short Ogg page');
    serial ??= pageSerial;
    if (pageSerial != serial) {
      if (strict) throw const FormatException('Several Ogg streams');
      offset = end;
      continue;
    }
    if (strict) {
      if (ogg[offset + 4] != 0) throw const FormatException('Ogg version');
      final page = Uint8List.fromList(ogg.sublist(offset, end));
      final stored = view.getUint32(offset + 22, Endian.little);
      ByteData.sublistView(page).setUint32(22, 0, Endian.little);
      if (oggCrc(page) != stored) {
        throw FormatException('Ogg CRC mismatch on page $pages');
      }
      if (pageSequence != sequence) {
        throw FormatException('Ogg page $pageSequence out of sequence');
      }
      if (((flags & 0x02) != 0) != (pages == 0)) {
        throw const FormatException('Ogg beginning-of-stream flag');
      }
      if (sawEos) throw const FormatException('Ogg page after end of stream');
      if (((flags & 0x01) != 0) != pendingOpen) {
        throw const FormatException('Ogg continuation flag');
      }
    }
    if ((flags & 0x01) == 0 && pendingOpen) {
      // A new packet starts although the previous one did not end.
      pending.clear();
      pendingOpen = false;
    }
    sequence = pageSequence + 1;
    sawEos = (flags & 0x04) != 0;
    var at = bodyStart;
    var ended = false;
    for (var i = 0; i < segments; i++) {
      final lace = ogg[offset + 27 + i];
      pending.add(ogg.sublist(at, at + lace));
      at += lace;
      pendingOpen = lace == 255;
      if (lace < 255) {
        packets.add(pending.takeBytes());
        ended = true;
      }
    }
    if (granule != -1) {
      if (!ended && strict) {
        throw const FormatException('Granule on a page that ends no packet');
      }
      if (strict && granule < lastGranule) {
        throw const FormatException('Ogg granule positions go backwards');
      }
      lastGranule = granule;
      pageGranules.add((packets.length, granule));
    } else if (ended && strict) {
      throw const FormatException('Page ends a packet without a granule');
    }
    pages++;
    offset = end;
  }
  if (strict && offset != ogg.length) {
    throw const FormatException('Trailing bytes after the last Ogg page');
  }
  if (strict && !sawEos) throw const FormatException('No end-of-stream page');
  if (packets.length < 2) throw const FormatException('No Opus headers');
  final head = packets[0];
  if (head.length < 19 ||
      String.fromCharCodes(head.sublist(0, 8)) != 'OpusHead') {
    throw const FormatException('Missing OpusHead');
  }
  if (head[8] >> 4 != 0) throw const FormatException('OpusHead version');
  final headView = ByteData.sublistView(head);
  final channels = head[9];
  final family = head[18];
  if (channels < 1 || (family == 0 && channels > 2)) {
    throw FormatException('Unsupported channel count $channels');
  }
  if (family != 0) {
    throw FormatException('Unsupported channel mapping family $family');
  }
  if (packets[1].length < 16 ||
      String.fromCharCodes(packets[1].take(8).toList()) != 'OpusTags') {
    throw const FormatException('Missing OpusTags');
  }
  final audio = packets.sublist(2);
  if (audio.isEmpty) throw const FormatException('No Opus audio packets');
  final samples = [for (final p in audio) opusPacketSamples(p)];
  final preSkip = headView.getUint16(10, Endian.little);
  if (strict) {
    // Header pages carry granule 0 and audio pages the exact running total;
    // only the last page may be smaller (end trimming).
    var running = 0, counted = 0;
    for (final (index, (completed, granule)) in pageGranules.indexed) {
      while (counted < completed - 2) {
        running += samples[counted++];
      }
      final last = index == pageGranules.length - 1;
      final valid = completed <= 2
          ? granule == 0
          : (last ? granule <= running : granule == running);
      if (!valid) throw FormatException('Granule $granule, expected $running');
    }
    if (lastGranule < preSkip) {
      throw const FormatException('Stream shorter than its pre-skip');
    }
  }
  return OggOpus(
    channels: channels,
    preSkip: preSkip,
    inputSampleRate: headView.getUint32(12, Endian.little),
    outputGain: headView.getInt16(16, Endian.little),
    packets: audio,
    packetSamples: samples,
    finalGranule: lastGranule,
    pages: pages,
  );
}

void _writeVarint(BytesBuilder out, int value) {
  final groups = <int>[value & 0x7F];
  for (var rest = value >> 7; rest > 0; rest >>= 7) {
    groups.add(rest & 0x7F);
  }
  for (var i = groups.length - 1; i >= 0; i--) {
    out.addByte(groups[i] | (i > 0 ? 0x80 : 0));
  }
}

/// Remuxes an Ogg/Opus file into CAF for Apple's player (macOS cannot play
/// Ogg), packet for packet. The layout follows what `ogg_caf_converter`
/// wrote and AVPlayer plays (description, channel layout, data, packet
/// table without priming), with exact packet sizes and frame counts.
Uint8List oggOpusToCaf(Uint8List ogg) {
  final stream = readOggOpus(ogg, strict: false);
  final constant = stream.packetSamples.every(
    (s) => s == stream.packetSamples.first,
  );
  final out = BytesBuilder(copy: false);
  void chunk(String type, Uint8List body) {
    final header = ByteData(12);
    for (var i = 0; i < 4; i++) {
      header.setUint8(i, type.codeUnitAt(i));
    }
    header.setInt64(4, body.length);
    out
      ..add(header.buffer.asUint8List())
      ..add(body);
  }

  out.add([0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0]); // 'caff', version 1
  final desc = ByteData(32)
    ..setFloat64(0, opusGranuleRate.toDouble())
    ..setUint32(8, 0x6F707573) // 'opus'
    ..setUint32(12, 0)
    ..setUint32(16, 0)
    ..setUint32(20, constant ? stream.packetSamples.first : 0)
    ..setUint32(24, stream.channels)
    ..setUint32(28, 0);
  chunk('desc', desc.buffer.asUint8List());
  final layout = ByteData(12)
    // kCAFChannelLayoutTag_Mono / _Stereo.
    ..setUint32(0, stream.channels == 2 ? (101 << 16) | 2 : (100 << 16) | 1);
  chunk('chan', layout.buffer.asUint8List());
  final data = BytesBuilder(copy: false)..add(Uint8List(4)); // edit count
  for (final packet in stream.packets) {
    data.add(packet);
  }
  chunk('data', data.takeBytes());
  final table = BytesBuilder(copy: false);
  final header = ByteData(24)
    ..setInt64(0, stream.packets.length)
    ..setInt64(8, stream.totalSamples)
    ..setInt32(16, 0)
    ..setInt32(20, 0);
  table.add(header.buffer.asUint8List());
  for (final (i, packet) in stream.packets.indexed) {
    _writeVarint(table, packet.length);
    if (!constant) _writeVarint(table, stream.packetSamples[i]);
  }
  chunk('pakt', table.takeBytes());
  return out.takeBytes();
}
