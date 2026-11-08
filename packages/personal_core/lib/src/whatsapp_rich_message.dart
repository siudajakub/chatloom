// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

/// Bridge-provided display data. URL actions only open a browser; they are
/// never WhatsApp callback replies or permission to send a network action.
class WhatsAppInteractiveContent {
  static const contentKey = 'pl.personal.chat.whatsapp.interactive';
  static const maxBytes = 64 * 1024;
  static const maxActions = 20;

  final String body;
  final String? formattedBody;
  final List<WhatsAppUrlAction> actions;

  WhatsAppInteractiveContent._(this.body, this.formattedBody, this.actions);

  static WhatsAppInteractiveContent? fromContent(Map<String, dynamic> content) {
    final raw = content[contentKey];
    if (raw is! Map ||
        raw.length > 4 ||
        raw.keys.any(
          (key) => !{
            'schema_version',
            'body',
            'formatted_body',
            'actions',
          }.contains(key),
        )) {
      return null;
    }
    final body = raw['body'];
    final formatted = raw['formatted_body'];
    final actions = raw['actions'];
    if (raw['schema_version'] is! int ||
        raw['schema_version'] != 1 ||
        body is! String ||
        body.length > maxBytes ||
        (formatted != null && formatted is! String) ||
        (formatted is String && formatted.length > maxBytes) ||
        actions is! List ||
        actions.isEmpty ||
        actions.length > maxActions) {
      return null;
    }
    final parsed = <WhatsAppUrlAction>[];
    for (final action in actions) {
      if (action is! Map ||
          action.length != 3 ||
          action.keys.any((key) => !{'kind', 'label', 'url'}.contains(key))) {
        return null;
      }
      final label = action['label'];
      final url = action['url'];
      if (action['kind'] != 'url' ||
          label is! String ||
          label.trim().isEmpty ||
          label.length > 2048 ||
          label.runes.length > 1024 ||
          url is! String ||
          !WhatsAppUrlAction.isValidUrl(url)) {
        return null;
      }
      parsed.add(WhatsAppUrlAction._(label.trim(), url));
    }
    // Only bounded strings and the validated small action list reach the
    // encoder; arbitrary nested extension fields are rejected above.
    if (!_boundedJson(raw, maxBytes)) return null;
    return WhatsAppInteractiveContent._(
      body,
      formatted as String?,
      List.unmodifiable(parsed),
    );
  }
}

class WhatsAppUrlAction {
  final String label;
  final String url;
  const WhatsAppUrlAction._(this.label, this.url);

  /// Keep URL validation shared by the renderer, Copy link and forwarding.
  /// No decoding, redirect resolution or external request is performed.
  static bool isValidUrl(String value) {
    if (value.isEmpty || value.length > 16384 || value.runes.length > 8192) {
      return false;
    }
    if (_urlWhitespace.hasMatch(value) || value.contains(r'\')) return false;
    // Uri normalizes an empty userinfo (`https://@host`) away, so inspect
    // the original authority too before handing the exact URL to a browser.
    if (_urlUserInfo.hasMatch(value)) return false;
    try {
      if (_urlControls.hasMatch(Uri.decodeFull(value))) return false;
      final uri = Uri.tryParse(value);
      return uri != null &&
          {'http', 'https'}.contains(uri.scheme.toLowerCase()) &&
          uri.hasAuthority &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.authority.contains('@');
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }
}

final _urlWhitespace = RegExp(r'[\s\x00-\x1f\x7f-\x9f]');
final _urlControls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
final _urlUserInfo = RegExp(r'^https?://[^/?#]*@', caseSensitive: false);

bool _boundedJson(Object value, int maxBytes) {
  try {
    return utf8.encode(jsonEncode(value)).length <= maxBytes;
  } catch (_) {
    return false;
  }
}

/// A WhatsApp poll can be nested in an ordinary `m.room.message` when the
/// bridge's extev_polls option is off. Its original event type stays intact.
class WhatsAppPollSnapshot {
  static const startKey = 'org.matrix.msc3381.poll.start';
  static const responseKey = 'org.matrix.msc3381.poll.response';
  static const textKey = 'org.matrix.msc1767.text';

  final String question;
  final List<WhatsAppPollOption> options;
  final int maxSelections;

  WhatsAppPollSnapshot._(this.question, this.options, this.maxSelections);

  static WhatsAppPollSnapshot? fromContent(Map<String, dynamic> content) {
    final raw = content[startKey];
    if (raw is! Map || raw['kind'] != 'org.matrix.msc3381.poll.disclosed') {
      return null;
    }
    final question = raw['question'];
    final text = question is Map ? question[textKey] ?? question['body'] : null;
    final answers = raw['answers'];
    final max = raw['max_selections'];
    if (text is! String ||
        text.trim().isEmpty ||
        text.length > 2048 ||
        text.runes.length > 1024 ||
        answers is! List ||
        answers.length < 2 ||
        answers.length > 12 ||
        max is! int ||
        max < 1 ||
        max > answers.length) {
      return null;
    }
    final ids = <String>{};
    final labels = <String>{};
    final options = <WhatsAppPollOption>[];
    for (final answer in answers) {
      if (answer is! Map) return null;
      final id = answer['id'];
      final label = answer[textKey];
      if (id is! String ||
          id.trim().isEmpty ||
          id.length > 2048 ||
          id.runes.length > 1024 ||
          !ids.add(id) ||
          label is! String ||
          label.trim().isEmpty ||
          label.length > 200 ||
          label.runes.length > 100 ||
          !labels.add(label.trim().toLowerCase())) {
        return null;
      }
      options.add(WhatsAppPollOption._(id, label));
    }
    return WhatsAppPollSnapshot._(text, List.unmodifiable(options), max);
  }

  /// Latest response per sender. An invalid or redacted latest response is
  /// a tombstone: it never brings an older vote back. Empty answers unvote.
  Map<String, Set<String>> votesBySender(Iterable<WhatsAppPollVote> votes) {
    final latest = <String, WhatsAppPollVote>{};
    for (final vote in votes) {
      final previous = latest[vote.senderId];
      if (previous == null || _compareVotes(vote, previous) > 0) {
        latest[vote.senderId] = vote;
      }
    }
    final allowed = options.map((option) => option.id).toSet();
    return Map.unmodifiable({
      for (final entry in latest.entries)
        entry.key: Set<String>.unmodifiable(
          entry.value.redacted ||
                  entry.value.answerIds.length > maxSelections ||
                  entry.value.answerIds.toSet().length !=
                      entry.value.answerIds.length ||
                  entry.value.answerIds.any((id) => !allowed.contains(id))
              ? const <String>[]
              : entry.value.answerIds,
        ),
    });
  }
}

int _compareVotes(WhatsAppPollVote a, WhatsAppPollVote b) {
  final timestamp = a.timestampMs.compareTo(b.timestampMs);
  if (timestamp != 0) return timestamp;
  final event = a.eventId.compareTo(b.eventId);
  if (event != 0) return event;
  // A redacted copy can coexist briefly with its original in an adapter.
  return (a.redacted ? 1 : 0).compareTo(b.redacted ? 1 : 0);
}

class WhatsAppPollOption {
  final String id;
  final String label;
  const WhatsAppPollOption._(this.id, this.label);
}

class WhatsAppPollVote {
  final String senderId;
  final String eventId;
  final int timestampMs;
  final List<String> answerIds;
  final bool redacted;

  WhatsAppPollVote({
    required this.senderId,
    required this.eventId,
    required this.timestampMs,
    required List<String> answerIds,
    this.redacted = false,
  }) : answerIds = List.unmodifiable(answerIds);

  /// Full Matrix event JSON, not just content. Relations from another poll
  /// are rejected when [expectedPollEventId] is supplied by the adapter.
  static WhatsAppPollVote? fromRelation(
    Map<String, dynamic> event, {
    String? expectedPollEventId,
  }) {
    if (event['type'] != WhatsAppPollSnapshot.responseKey) return null;
    final content = event['content'];
    final sender = event['sender'];
    final id = event['event_id'];
    final timestamp = event['origin_server_ts'];
    final relation = content is Map ? content['m.relates_to'] : null;
    final target = relation is Map ? relation['event_id'] : null;
    if (content is! Map ||
        sender is! String ||
        sender.isEmpty ||
        id is! String ||
        id.isEmpty ||
        timestamp is! int ||
        timestamp < 0 ||
        relation is! Map ||
        relation['rel_type'] != 'm.reference' ||
        target is! String ||
        target.isEmpty ||
        (expectedPollEventId != null && target != expectedPollEventId)) {
      return null;
    }
    final unsigned = event['unsigned'];
    final redacted =
        event['redacted'] == true ||
        (unsigned is Map && unsigned['redacted_because'] is Map);
    final response = content[WhatsAppPollSnapshot.responseKey];
    final answers = response is Map ? response['answers'] : null;
    // A malformed latest response invalidates a prior vote too. It has
    // enough relation/identity evidence to act as a tombstone, not a vote.
    final invalid =
        answers is! List ||
        answers.length > 12 ||
        answers.any((answer) => answer is! String || answer.length > 2048);
    return WhatsAppPollVote(
      senderId: sender,
      eventId: id,
      timestampMs: timestamp,
      answerIds: redacted || invalid ? const [] : answers.cast<String>(),
      redacted: redacted || invalid,
    );
  }
}
