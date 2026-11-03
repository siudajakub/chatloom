// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'contracts.dart';
import 'transcription.dart' show sha256Hex;

/// No provider credential or remote message identifier is part of the text
/// sent for summarisation. Everything travels through the private journal.
enum SummaryScopeKind { messages, hours, days, all }

enum SummaryDetail { brief, standard, detailed }

class SummaryException implements Exception {
  final String code;
  const SummaryException(this.code);
  @override
  String toString() => 'SummaryException($code)';
}

class SummaryCancelledException extends SummaryException {
  const SummaryCancelledException() : super('cancelled');
}

class SummaryCancellation {
  bool _cancelled = false;
  final _completion = Completer<void>();
  Future<void> get whenCancelled => _completion.future;
  bool get isCancelled => _cancelled;
  bool get cancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completion.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const SummaryCancelledException();
  }
}

class SummaryRequest {
  final SummaryScopeKind scope;
  final int amount;
  final SummaryDetail detail;
  final String language;
  const SummaryRequest({
    this.scope = SummaryScopeKind.messages,
    this.amount = 100,
    this.detail = SummaryDetail.standard,
    this.language = 'pl',
  });

  bool get isValid =>
      (language == 'pl' || language == 'en') &&
      (scope == SummaryScopeKind.all ||
          (amount >= 1 &&
              amount <=
                  switch (scope) {
                    SummaryScopeKind.messages => 10000,
                    SummaryScopeKind.hours => 8760,
                    SummaryScopeKind.days => 3650,
                    SummaryScopeKind.all => 1,
                  }));

  Map<String, dynamic> toJson() => {
    'scope': scope.name,
    'amount': amount,
    'detail': detail.name,
    'language': language,
  };
  factory SummaryRequest.fromJson(Map<String, dynamic> json) {
    try {
      final value = SummaryRequest(
        scope: SummaryScopeKind.values.byName(json['scope'] as String),
        amount: json['amount'] as int,
        detail: SummaryDetail.values.byName(json['detail'] as String),
        language: json['language'] as String,
      );
      if (!value.isValid) throw const SummaryException('invalid_request');
      return value;
    } on SummaryException {
      rethrow;
    } catch (_) {
      throw const SummaryException('invalid_request');
    }
  }
  @override
  String toString() => 'SummaryRequest(${scope.name}, ${detail.name})';
}

class SummaryMessage {
  final DateTime timestamp;
  final String sender;
  final String text;
  const SummaryMessage({
    required this.timestamp,
    required this.sender,
    required this.text,
  });
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'sender': sender,
    'text': text,
  };
  factory SummaryMessage.fromJson(Map<String, dynamic> json) => SummaryMessage(
    timestamp: DateTime.parse(json['timestamp'] as String),
    sender: json['sender'] as String,
    text: json['text'] as String,
  );
  @override
  String toString() => 'SummaryMessage(redacted)';
}

class SummarySource {
  final List<SummaryMessage> messages;
  final bool complete;
  final int omittedMessages;
  final String? coverageNote;
  SummarySource({
    required List<SummaryMessage> messages,
    required this.complete,
    this.omittedMessages = 0,
    this.coverageNote,
  }) : messages = List.unmodifiable(messages);
  Map<String, dynamic> toJson() => {
    'messages': messages.map((m) => m.toJson()).toList(),
    'complete': complete,
    'omittedMessages': omittedMessages,
    if (coverageNote != null) 'coverageNote': coverageNote,
  };
  factory SummarySource.fromJson(Map<String, dynamic> json) {
    try {
      final messages = (json['messages'] as List)
          .map(
            (value) => SummaryMessage.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList();
      final omitted = json['omittedMessages'] as int? ?? 0;
      if (messages.isEmpty ||
          messages.length > 10000 ||
          omitted < 0 ||
          messages.any((m) => m.text.trim().isEmpty || m.sender.length > 255) ||
          (json['coverageNote'] as String? ?? '').length > 2000) {
        throw const SummaryException('invalid_source');
      }
      for (var i = 1; i < messages.length; i++) {
        if (messages[i].timestamp.isBefore(messages[i - 1].timestamp)) {
          throw const SummaryException('invalid_source');
        }
      }
      return SummarySource(
        messages: messages,
        complete: json['complete'] as bool,
        omittedMessages: omitted,
        coverageNote: json['coverageNote'] as String?,
      );
    } on SummaryException {
      rethrow;
    } catch (_) {
      throw const SummaryException('invalid_source');
    }
  }
  @override
  String toString() => 'SummarySource(${messages.length} messages, redacted)';
}

/// Result only; selected source text and transport identifiers are never echoed.
class SummaryResult {
  final String text;
  final String model;
  final int messageCount;
  final DateTime startedAt;
  final DateTime endedAt;
  final bool complete;
  final double? estimatedCostUsd;
  final String? coverageNote;
  const SummaryResult({
    required this.text,
    required this.model,
    required this.messageCount,
    required this.startedAt,
    required this.endedAt,
    required this.complete,
    this.estimatedCostUsd,
    this.coverageNote,
  });
  Map<String, dynamic> toJson() => {
    'text': text,
    'model': model,
    'messageCount': messageCount,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'complete': complete,
    if (estimatedCostUsd != null) 'estimatedCostUsd': estimatedCostUsd,
    if (coverageNote != null) 'coverageNote': coverageNote,
  };
  factory SummaryResult.fromJson(Map<String, dynamic> json) => SummaryResult(
    text: json['text'] as String,
    model: json['model'] as String,
    messageCount: json['messageCount'] as int,
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: DateTime.parse(json['endedAt'] as String),
    complete: json['complete'] as bool,
    estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble(),
    coverageNote: json['coverageNote'] as String?,
  );
  @override
  String toString() => 'SummaryResult($messageCount messages, redacted)';
}

/// Immutable input manifest. The generous but finite byte cap bounds both
/// journal replication and provider spend; exceeding it always fails explicitly.
class SummaryUpload {
  static const maxSourceBytes = 400000;
  static const maxParts = 100;
  static const partBytes = 12000;
  final String id;
  final Map<String, dynamic> manifest;
  final List<Map<String, dynamic>> parts;
  SummaryUpload._(this.id, this.manifest, this.parts);
  String partEntity(int index) => summaryPartEntity(id, index);
  static String summaryPartEntity(String id, int index) =>
      'summary-source:$id:$index';

  factory SummaryUpload.create({
    required String id,
    required ConversationRef conversation,
    required SummaryRequest request,
    required SummarySource source,
  }) {
    if (!validSummaryId(id) || !request.isValid) {
      throw const SummaryException('invalid_request');
    }
    if (source.messages.isEmpty) throw const SummaryException('no_messages');
    // Use the same schema checks on each side of the trust boundary.
    SummarySource.fromJson(source.toJson());
    final encoded = jsonEncode(source.toJson());
    final bytes = utf8.encode(encoded);
    if (bytes.length > maxSourceBytes) {
      throw const SummaryException('source_too_large');
    }
    final digest = sha256Hex(bytes);
    final texts = <String>[];
    var start = 0;
    while (start < bytes.length) {
      var end = start + partBytes;
      if (end > bytes.length) end = bytes.length;
      while (end < bytes.length && (bytes[end] & 0xc0) == 0x80) {
        end--;
      }
      texts.add(utf8.decode(bytes.sublist(start, end)));
      start = end;
    }
    if (texts.length > maxParts)
      throw const SummaryException('source_too_large');
    return SummaryUpload._(
      id,
      {
        'id': id,
        'conversation': conversation.toJson(),
        'request': request.toJson(),
        'partCount': texts.length,
        'sourceDigest': digest,
        'sourceBytes': bytes.length,
      },
      [
        for (var i = 0; i < texts.length; i++)
          {
            'summaryId': id,
            'index': i,
            'count': texts.length,
            'sha256': digest,
            'text': texts[i],
          },
      ],
    );
  }
}

bool validSummaryId(String value) =>
    RegExp(r'^summary:[a-zA-Z0-9_-]{8,128}$').hasMatch(value);
