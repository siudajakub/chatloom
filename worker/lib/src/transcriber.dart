// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'ports.dart';
import 'transcript_timestamps.dart';

const transcriptionMaxBytes = 25000000;

/// The model name of the job contract (`TranscriptionJob.model`); the
/// provider model actually called is [OpenAiTranscriber.model].
const transcriptionModel = 'gpt-transcribe';
const transcriptionPricePerMinute = 0.0045;

/// Provider attempts per chunk when the provider (429/502/503, or the
/// network before any byte was sent) says definitively that the request was
/// not processed.
const transcriptionProviderAttempts = 3;

/// Speech models work at 16 kHz; mono MP3 at 32 kbit/s keeps uploads at
/// about 240 KB per minute (15-minute chunks of ~3.6 MB, far below 25 MB).
const transcriptionSampleRate = '16000';
const transcriptionBitrate = '32k';
const _audioInputRestrictions = [
  // Limit decoder threads as well as output encoder/filter threads below.
  // The default otherwise scales each conversion with all host CPU cores.
  '-threads',
  '1',
  '-protocol_whitelist',
  'file,pipe',
  '-format_whitelist',
  // mov covers mp4/m4a/m4v/3gp/3g2; matroska covers mkv/webm.
  'ogg,mp3,wav,mov,aac,matroska,webm,flac,avi,amr',
];

/// FFmpeg's diagnostics when the input has no audio stream at all, e.g. a
/// silent video or a GIF-style clip. Matched on bounded stderr only.
bool _noAudioStream(String stderr) =>
    stderr.contains('matches no streams') ||
    stderr.contains('does not contain any stream');

class OpenAiTranscriber implements Transcriber {
  final String apiKey;

  /// The provider model; with [TranscriptionModel.timestamps] the same
  /// request also returns segment and word timestamps (`verbose_json`).
  final TranscriptionModel model;
  final String temporaryRoot;
  final String ffmpeg;
  final String ffprobe;
  final Duration processTimeout;
  final bool requireCodecSandbox;
  final http.Client Function() clientFactory;

  /// Backoff wait between provider attempts (test seam).
  final Future<void> Function(Duration) sleep;
  OpenAiTranscriber(
    this.apiKey, {
    required this.temporaryRoot,
    this.model = TranscriptionModel.gptTranscribe,
    String? ffmpeg,
    String? ffprobe,
    this.processTimeout = const Duration(minutes: 10),
    this.requireCodecSandbox = false,
    http.Client Function()? clientFactory,
    Future<void> Function(Duration)? sleep,
  }) : sleep = sleep ?? Future<void>.delayed,
       ffmpeg = ffmpeg ?? Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg',
       ffprobe = ffprobe ?? Platform.environment['FFPROBE_PATH'] ?? 'ffprobe',
       clientFactory = clientFactory ?? http.Client.new;

  Future<ProcessResult> _run(
    String executable,
    List<String> arguments,
    Cancellation cancel, {
    bool countOutputBytes = false,
  }) async {
    cancel.check();
    final process = await Process.start(
      executable,
      arguments,
      includeParentEnvironment: false,
      environment: {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
    );
    var active = true;
    cancel.listen(() {
      if (active) process.kill(ProcessSignal.sigkill);
    });
    final output = countOutputBytes
        ? process.stdout.fold<int>(0, (count, bytes) => count + bytes.length)
        : process.stdout.transform(utf8.decoder).join();
    // Keep at most 4 KiB of diagnostics; only used to classify failures and
    // never logged (it may contain private file names).
    final diagnostics = BytesBuilder(copy: false);
    final error = process.stderr.forEach((chunk) {
      final room = 4096 - diagnostics.length;
      if (room > 0) {
        diagnostics.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
      }
    });
    try {
      final exit = await process.exitCode.timeout(processTimeout);
      final text = await output;
      await error;
      cancel.check();
      if (exit != 0) {
        final stderr = utf8.decode(
          diagnostics.takeBytes(),
          allowMalformed: true,
        );
        throw WorkerFailure(
          _noAudioStream(stderr) ? 'no_audio_track' : 'media_conversion_failed',
        );
      }
      return ProcessResult(process.pid, exit, text, '');
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await output;
      await error;
      throw const WorkerFailure('media_conversion_timeout');
    } finally {
      active = false;
    }
  }

  Future<double> _probeDuration(File input, Cancellation cancel) async {
    if (ffprobe.isNotEmpty) {
      try {
        // Container header only: stream types and duration, no decoding.
        final probe = await _run(ffprobe, [
          '-v',
          'error',
          ..._audioInputRestrictions,
          '-show_entries',
          'format=duration:stream=codec_type',
          '-of',
          'json',
          input.path,
        ], cancel);
        Object? parsed;
        try {
          parsed = jsonDecode(probe.stdout as String);
        } on FormatException {
          parsed = null;
        }
        if (parsed is Map) {
          final streams = parsed['streams'];
          // A video without any audio stream (silent clip, GIF-style loop)
          // is skipped here: nothing is converted or uploaded.
          if (streams is List &&
              !streams.any((s) => s is Map && s['codec_type'] == 'audio')) {
            throw const WorkerFailure('no_audio_track');
          }
          final format = parsed['format'];
          final raw = format is Map ? format['duration'] : null;
          final duration = raw is String ? double.tryParse(raw) : null;
          if (duration != null && duration.isFinite && duration > 0) {
            return duration;
          }
        }
      } on ProcessException catch (e) {
        // ENOENT means the optional ffprobe binary is absent. Permission and
        // other execution errors must remain visible, rather than be hidden.
        if (e.errorCode != 2) {
          throw const WorkerFailure('ffprobe_execution_failed');
        }
      }
    }
    // Count decoded PCM samples without retaining them. FFmpeg 6's final
    // progress timestamp can describe the start of its last audio packet and
    // undercount duration; a successful complete decode supplies exact samples.
    final decoded = await _run(
      ffmpeg,
      [
        '-nostdin',
        '-hide_banner',
        '-v',
        'error',
        '-filter_threads',
        '1',
        '-filter_complex_threads',
        '1',
        ..._audioInputRestrictions,
        '-i',
        input.path,
        '-map',
        '0:a:0',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-c:a',
        'pcm_s16le',
        '-threads',
        '1',
        '-f',
        's16le',
        'pipe:1',
      ],
      cancel,
      countOutputBytes: true,
    );
    final count = decoded.stdout as int;
    if (count == 0 || count.isOdd) {
      throw const WorkerFailure('invalid_audio_duration');
    }
    final duration = count / (16000 * 2);
    if (!duration.isFinite || duration <= 0) {
      throw const WorkerFailure('invalid_audio_duration');
    }
    return duration;
  }

  @override
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double, double) estimate,
  ) async {
    if (apiKey.isEmpty) throw const WorkerFailure('openai_key_missing');
    // Isolation is optional hardening; when requested, never pretend that the
    // current protocol restrictions are an implemented process sandbox.
    if (requireCodecSandbox) {
      throw const WorkerFailure('codec_sandbox_required');
    }
    final root = Directory(temporaryRoot);
    await root.create(recursive: true);
    final directory = await root.createTemp('audio-');
    try {
      final input = File('${directory.path}/source');
      // The media's only in-memory copy is released once it is on disk.
      await input.writeAsBytes(audio.takeBytes(), flush: true);
      final duration = await _probeDuration(input, cancel);
      final cost = duration / 60 * model.pricePerMinute;
      // Pre-upload gate: automatic-job limits throw here, before conversion
      // or any provider request; the finally block removes the plaintext.
      estimate(duration, cost);
      // Audio only (-vn/-sn/-dn: video, subtitles and data are never
      // decoded), mono 16 kHz MP3, 15 min segments well below 25 MB.
      // Metadata is removed.
      await _run(ffmpeg, [
        '-nostdin',
        '-v',
        'error',
        '-filter_threads',
        '1',
        '-filter_complex_threads',
        '1',
        ..._audioInputRestrictions,
        '-i',
        input.path,
        '-map',
        '0:a:0',
        '-map_metadata',
        '-1',
        '-vn',
        '-sn',
        '-dn',
        '-ac',
        '1',
        '-ar',
        transcriptionSampleRate,
        '-c:a',
        'libmp3lame',
        '-threads',
        '1',
        '-b:a',
        transcriptionBitrate,
        '-f',
        'segment',
        '-segment_time',
        '900',
        '-reset_timestamps',
        '1',
        '${directory.path}/chunk-%06d.mp3',
      ], cancel);
      final chunks =
          (await directory
                .list()
                .where((f) => f is File && f.path.endsWith('.mp3'))
                .cast<File>()
                .toList())
            ..sort((a, b) => a.path.compareTo(b.path));
      if (chunks.isEmpty) throw const WorkerFailure('empty_audio');
      final texts = <String>[];
      final stamps = <ChunkTimestamps?>[];
      for (final chunk in chunks) {
        cancel.check();
        if (await chunk.length() > transcriptionMaxBytes) {
          throw const WorkerFailure('audio_chunk_too_large');
        }
        try {
          final answer = await _upload(chunk, language, cancel);
          texts.add(answer.text);
          stamps.add(answer.timestamps);
        } on PaidRequestUnknown {
          rethrow;
        } on WorkerFailure catch (e) {
          // Earlier chunks were already charged: a later automatic retry of
          // the whole job would pay for them again, so it is final.
          if (texts.isNotEmpty && e.code != 'cancelled') {
            throw const WorkerFailure('openai_partial_failure');
          }
          rethrow;
        }
      }
      return TranscriptionResult(
        texts.join('\n\n'),
        duration,
        cost,
        // Timestamps come with the text of the same requests, never from a
        // second one; a transcript without them is still complete.
        timing: model.timestamps
            ? transcriptTimingRecord(texts, stamps, separator: '\n\n')
            : null,
      );
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  /// Uploads one chunk. Retries only answers that prove the request was not
  /// processed (429, 502 and 503 responses, or a connection that never
  /// opened). 500/504 and other 5xx, a timeout or a dropped connection after
  /// sending are paid uncertainty and never retried, so nothing is charged
  /// twice.
  Future<({String text, ChunkTimestamps? timestamps})> _upload(
    File file,
    String? language,
    Cancellation cancel,
  ) async {
    for (var attempt = 1; ; attempt++) {
      final outcome = await _uploadOnce(file, language, cancel);
      if (outcome.text case final text?) {
        return (text: text, timestamps: outcome.timestamps);
      }
      if (attempt >= transcriptionProviderAttempts) {
        throw WorkerFailure(outcome.failure!);
      }
      var wait = Duration(seconds: 1 << (attempt - 1));
      final retryAfter = outcome.retryAfter;
      if (retryAfter != null && retryAfter > wait) {
        wait = retryAfter > const Duration(seconds: 20)
            ? const Duration(seconds: 20)
            : retryAfter;
      }
      cancel.check();
      await sleep(wait);
      cancel.check();
    }
  }

  Future<
    ({
      String? text,
      ChunkTimestamps? timestamps,
      String? failure,
      Duration? retryAfter,
    })
  >
  _uploadOnce(File file, String? language, Cancellation cancel) async {
    final client = clientFactory();
    cancel.listen(client.close);
    try {
      cancel.check();
      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
            )
            ..headers['Authorization'] = 'Bearer $apiKey'
            ..fields['model'] = model.name;
      if (model.timestamps) {
        // One request: text plus segment and word times (whisper-1). The
        // multipart form repeats the array field, so the second value is
        // its own part (a plain field part, no file name).
        request.fields['response_format'] = 'verbose_json';
        request.fields['timestamp_granularities[]'] = 'segment';
        request.files.add(
          http.MultipartFile.fromString('timestamp_granularities[]', 'word'),
        );
        if (language != null && language.isNotEmpty) {
          request.fields['language'] = language;
        }
      } else {
        request.fields['response_format'] = 'json';
        if (language != null && language.isNotEmpty) {
          request.fields['languages[]'] = language;
        }
      }
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          filename: 'audio.mp3',
        ),
      );
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 5));
      final body = await response.stream.bytesToString().timeout(
        const Duration(minutes: 1),
      );
      cancel.check();
      if (response.statusCode != 200) {
        final code = response.statusCode == 401
            ? 'openai_auth_failed'
            : response.statusCode == 429
            ? 'openai_rate_limited'
            : response.statusCode >= 500
            ? 'openai_unavailable'
            : 'openai_rejected';
        // 500/504 (and other 5xx) can arrive after the provider processed
        // and billed the audio: paid uncertainty, never retried. Only
        // 429 and 502/503 (rejected before processing) are retried.
        if (response.statusCode >= 500 &&
            response.statusCode != 502 &&
            response.statusCode != 503) {
          throw const PaidRequestUnknown();
        }
        final retryable =
            response.statusCode == 429 ||
            response.statusCode == 502 ||
            response.statusCode == 503;
        if (!retryable) throw WorkerFailure(code);
        final seconds = int.tryParse(
          response.headers['retry-after']?.trim() ?? '',
        );
        return (
          text: null,
          timestamps: null,
          failure: code,
          retryAfter: seconds == null || seconds < 0
              ? null
              : Duration(seconds: seconds),
        );
      }
      final value = jsonDecode(body);
      final text = value is Map ? value['text'] : null;
      if (text is! String || text.trim().isEmpty) {
        throw const WorkerFailure('empty_transcript');
      }
      final trimmed = text.trim();
      ChunkTimestamps? timestamps;
      if (model.timestamps && value is Map) {
        try {
          timestamps = chunkTimestamps(value, trimmed);
        } catch (_) {
          // Unexpected timestamp shapes never cost the paid text.
          timestamps = null;
        }
      }
      return (
        text: trimmed,
        timestamps: timestamps,
        failure: null,
        retryAfter: null,
      );
    } on WorkerFailure {
      rethrow;
    } on SocketException catch (e) {
      cancel.check();
      // Refused connections and failed DNS lookups never reach the provider.
      if (_neverConnected(e)) {
        return (
          text: null,
          timestamps: null,
          failure: 'openai_unreachable',
          retryAfter: null,
        );
      }
      throw const PaidRequestUnknown();
    } catch (_) {
      cancel.check();
      // No blind retry: provider may have completed and charged this request.
      throw const PaidRequestUnknown();
    } finally {
      client.close();
    }
  }

  static bool _neverConnected(SocketException e) {
    const refused = {111, 101, 113}; // ECONNREFUSED, ENETUNREACH, EHOSTUNREACH
    return e.message.contains('Failed host lookup') ||
        refused.contains(e.osError?.errorCode);
  }
}
