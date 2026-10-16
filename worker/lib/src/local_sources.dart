// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';
import 'ports.dart';

/// Explicit local-source adapter. Journal/crypto, identity and all conversation
/// writes remain with Matrix; this socket never receives a provider/API key.
class LocalSourceTransport implements FeatureTransport {
  final FeatureTransport matrix;
  final String socketPath;
  LocalSourceTransport(this.matrix, this.socketPath);
  bool local(SourceEventRef source) =>
      source.conversation.roomId.endsWith(':beeper.local');
  @override
  String get accountId => matrix.accountId;
  @override
  String get deviceId => matrix.deviceId;
  @override
  bool get verified => matrix.verified;

  Future<Uint8List> request(
    SourceEventRef source,
    String mode,
    Cancellation cancel,
  ) async {
    if (!verified ||
        source.conversation.accountId != accountId ||
        !local(source)) {
      throw const WorkerFailure('invalid_local_source_account');
    }
    final client = HttpClient();
    client.connectionFactory = (_, _, _) => Socket.startConnect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    cancel.listen(() => client.close(force: true));
    try {
      final req = await client
          .postUrl(Uri.parse('http://localhost/source'))
          .timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      final body = utf8.encode(
        jsonEncode({'source': source.toJson(), 'mode': mode}),
      );
      req.contentLength = body.length;
      req.add(body);
      final response = await req.close().timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) {
        throw const WorkerFailure('local_source_unavailable');
      }
      final limit = mode == 'metadata' ? 65536 : 250000000;
      if (response.contentLength < 0 || response.contentLength > limit) {
        throw const WorkerFailure('source_too_large');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(minutes: 3))) {
        cancel.check();
        if (bytes.length + chunk.length > limit) {
          throw const WorkerFailure('source_too_large');
        }
        bytes.add(chunk);
      }
      cancel.check();
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> metadata(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    final data =
        jsonDecode(utf8.decode(await request(source, 'metadata', cancel)))
            as Map<String, dynamic>;
    if (data['sourceKey'] != source.key || data['redacted'] is! bool) {
      throw const WorkerFailure('local_source_binding_mismatch');
    }
    return data;
  }

  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async {
    if (!local(source)) return matrix.sourceRedacted(source);
    try {
      return (await metadata(source, Cancellation()))['redacted'] as bool;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    if (!local(source)) return matrix.loadAudio(source, cancel);
    final before = await metadata(source, cancel);
    if (before['redacted'] == true) {
      throw const WorkerFailure('source_redacted');
    }
    if (before['transcriptionAllowed'] != true) {
      throw const WorkerFailure('protected_media');
    }
    final bytes = await request(source, 'audio', cancel);
    final after = await metadata(source, cancel);
    if (after['redacted'] == true) throw const WorkerFailure('source_redacted');
    if (after['transcriptionAllowed'] != true) {
      throw const WorkerFailure('protected_media');
    }
    return AudioSource(bytes, before['mimeType'] as String);
  }

  @override
  Future<String> send(
    SendTarget target,
    Map<String, dynamic> content,
    String transactionId,
  ) => matrix.send(target, content, transactionId);
  @override
  Future<void> readAfterAcceptedReply(SendTarget target) =>
      matrix.readAfterAcceptedReply(target);
  @override
  Future<bool> hasRepliedSince(ConversationRef conversation, DateTime since) =>
      matrix.hasRepliedSince(conversation, since);
}
