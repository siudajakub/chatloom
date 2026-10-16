// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'ports.dart';

const transcriptionMaxBytes = 25000000;
const transcriptionModel = 'gpt-transcribe';
const transcriptionPricePerMinute = 0.0045;
const _audioInputRestrictions = [
  '-protocol_whitelist',
  'file,pipe',
  '-format_whitelist',
  'ogg,mp3,wav,mov,aac,matroska,webm,flac',
];

class OpenAiTranscriber implements Transcriber {
  final String apiKey;
  final String temporaryRoot;
  final String ffmpeg;
  final String ffprobe;
  final Duration processTimeout;
  final bool requireCodecSandbox;
  final http.Client Function() clientFactory;
  OpenAiTranscriber(
    this.apiKey, {
    required this.temporaryRoot,
    String? ffmpeg,
    String? ffprobe,
    this.processTimeout = const Duration(minutes: 10),
    this.requireCodecSandbox = false,
    http.Client Function()? clientFactory,
  }) : ffmpeg = ffmpeg ?? Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg',
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
    final error = process.stderr.drain<void>();
    try {
      final exit = await process.exitCode.timeout(processTimeout);
      final text = await output;
      await error;
      cancel.check();
      if (exit != 0) throw const WorkerFailure('media_conversion_failed');
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
        final probe = await _run(ffprobe, [
          '-v',
          'error',
          ..._audioInputRestrictions,
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          input.path,
        ], cancel);
        final duration = double.tryParse((probe.stdout as String).trim());
        if (duration != null && duration.isFinite && duration > 0) {
          return duration;
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
      await input.writeAsBytes(audio.bytes, flush: true);
      final duration = await _probeDuration(input, cancel);
      final cost = duration / 60 * transcriptionPricePerMinute;
      estimate(duration, cost);
      // 15 min segments at 48 kbps are well below 25 MB. Metadata is removed.
      await _run(ffmpeg, [
        '-nostdin',
        '-v',
        'error',
        ..._audioInputRestrictions,
        '-i',
        input.path,
        '-map',
        '0:a:0',
        '-map_metadata',
        '-1',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '24000',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '48k',
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
      for (final chunk in chunks) {
        cancel.check();
        if (await chunk.length() > transcriptionMaxBytes) {
          throw const WorkerFailure('audio_chunk_too_large');
        }
        texts.add(await _upload(chunk, language, cancel));
      }
      return TranscriptionResult(texts.join('\n\n'), duration, cost);
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  Future<String> _upload(
    File file,
    String? language,
    Cancellation cancel,
  ) async {
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
            ..fields['model'] = transcriptionModel
            ..fields['response_format'] = 'json';
      if (language != null && language.isNotEmpty) {
        request.fields['languages[]'] = language;
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
        throw WorkerFailure(
          response.statusCode == 401
              ? 'openai_auth_failed'
              : response.statusCode == 429
              ? 'openai_rate_limited'
              : 'openai_rejected',
        );
      }
      final value = jsonDecode(body);
      final text = value is Map ? value['text'] : null;
      if (text is! String || text.trim().isEmpty) {
        throw const WorkerFailure('empty_transcript');
      }
      return text.trim();
    } on WorkerFailure {
      rethrow;
    } catch (_) {
      cancel.check();
      // No blind retry: provider may have completed and charged this request.
      throw const PaidRequestUnknown();
    } finally {
      client.close();
    }
  }
}
