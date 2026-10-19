// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

const personalSchemaVersion = 1;
const personalEventType = 'pl.personal.client.operation.v1';
const personalRoomMarker = 'pl.personal.client.journal.v1';

// Keys are hot in merged timelines; both ref classes are immutable.
final _refKeys = Expando<String>('personal ref keys');

class ConversationRef {
  final String accountId;
  final String roomId;
  final String network;
  const ConversationRef({required this.accountId, required this.roomId, this.network = 'unknown'});
  String get key => _refKeys[this] ??= jsonEncode([accountId, roomId]);
  Map<String, Object?> toJson() => {'accountId': accountId, 'roomId': roomId, 'network': network};
  factory ConversationRef.fromJson(Map<String, dynamic> j) => ConversationRef(accountId: j['accountId'] as String, roomId: j['roomId'] as String, network: j['network'] as String? ?? 'unknown');
  @override bool operator ==(Object other) => other is ConversationRef && other.accountId == accountId && other.roomId == roomId;
  @override int get hashCode => Object.hash(accountId, roomId);
  @override String toString() => 'ConversationRef(redacted)';
}

class SourceEventRef {
  final ConversationRef conversation;
  final String eventId;
  const SourceEventRef({required this.conversation, required this.eventId});
  String get key => _refKeys[this] ??= jsonEncode([conversation.accountId, conversation.roomId, eventId]);
  Map<String, Object?> toJson() => {'conversation': conversation.toJson(), 'eventId': eventId};
  factory SourceEventRef.fromJson(Map<String,dynamic> j) => SourceEventRef(conversation: ConversationRef.fromJson(Map<String,dynamic>.from(j['conversation'] as Map)), eventId: j['eventId'] as String);
  @override String toString() => 'SourceEventRef(redacted)';
}

class SendTarget {
  final ConversationRef conversation;
  final String? readUpToEventId;
  const SendTarget({required this.conversation, this.readUpToEventId});
  Map<String,Object?> toJson() => {'conversation': conversation.toJson(), 'readUpToEventId': readUpToEventId};
  factory SendTarget.fromJson(Map<String,dynamic> j) => SendTarget(conversation: ConversationRef.fromJson(Map<String,dynamic>.from(j['conversation'] as Map)), readUpToEventId: j['readUpToEventId'] as String?);
  @override String toString() => 'SendTarget(redacted)';
}

class PersonGroup {
  final String id;
  final String name;
  final List<ConversationRef> members;
  final String defaultRoomId;
  final int revision;
  PersonGroup({required this.id, required this.name, required List<ConversationRef> members, required this.defaultRoomId, this.revision = 0}) : members = List.unmodifiable(members) {
    if (members.length < 2 || members.map((m)=>m.key).toSet().length != members.length || !members.any((m)=>m.roomId == defaultRoomId)) throw ArgumentError('Invalid person group');
    if (members.map((m)=>m.accountId).toSet().length != 1) throw ArgumentError('Cross-account groups are unsupported');
  }
  Map<String,Object?> toJson() => {'id':id,'name':name,'members':members.map((m)=>m.toJson()).toList(),'defaultRoomId':defaultRoomId,'revision':revision};
  factory PersonGroup.fromJson(Map<String,dynamic> j) => PersonGroup(id:j['id'] as String,name:j['name'] as String,members:(j['members'] as List).map((m)=>ConversationRef.fromJson(Map<String,dynamic>.from(m as Map))).toList(),defaultRoomId:j['defaultRoomId'] as String,revision:j['revision'] as int? ?? 0);
  @override String toString() => 'PersonGroup(redacted)';
}

enum CapabilityStatus { available, unavailable, unverified }
class CapabilityResult {
  final CapabilityStatus status;
  final String reason;
  const CapabilityResult(this.status, this.reason);
  bool get allowed => status == CapabilityStatus.available;
}

enum JobState { waitingSync, waitingKeys, queued, processing, done, cancelled, failed, unknown, paused, conflict }

class PersonalOperation {
  final String opId;
  final String kind;
  final String entityId;
  final int baseRevision;
  final DateTime createdAt;
  final Map<String,dynamic> payload;
  PersonalOperation({required this.opId,required this.kind,required this.entityId,this.baseRevision=0,required this.createdAt,required Map<String,dynamic> payload}): payload=Map.unmodifiable(payload) {
    if (opId.isEmpty || kind.isEmpty || entityId.isEmpty || baseRevision < 0) throw ArgumentError('Invalid operation');
  }
  Map<String,Object?> toJson() => {'schema':personalSchemaVersion,'opId':opId,'kind':kind,'entityId':entityId,'baseRevision':baseRevision,'createdAt':createdAt.toUtc().toIso8601String(),'payload':payload};
  factory PersonalOperation.fromJson(Map<String,dynamic> j) {
    if(j['schema'] != personalSchemaVersion) throw const FormatException('Unsupported personal schema');
    return PersonalOperation(opId:j['opId'] as String,kind:j['kind'] as String,entityId:j['entityId'] as String,baseRevision:j['baseRevision'] as int,createdAt:DateTime.parse(j['createdAt'] as String),payload:Map<String,dynamic>.from(j['payload'] as Map));
  }
  @override String toString() => 'PersonalOperation($kind, redacted)';
}

/// Who asked for a transcription. Older workers ignore the field, so absent
/// means manual and manual jobs keep their original JSON shape.
enum TranscriptionOrigin { manual, auto }

TranscriptionOrigin transcriptionOriginFromJson(Object? value) =>
    value == TranscriptionOrigin.auto.name ? TranscriptionOrigin.auto : TranscriptionOrigin.manual;

class TranscriptionJob {
  final String id;
  final SourceEventRef source;
  final JobState state;
  final String? language;
  final String? text;
  final String model;
  final double? durationSeconds;
  final double? estimatedCostUsd;
  final String? errorCode;
  final TranscriptionOrigin origin;
  const TranscriptionJob({required this.id,required this.source,required this.state,this.language,this.text,this.model='gpt-transcribe',this.durationSeconds,this.estimatedCostUsd,this.errorCode,this.origin=TranscriptionOrigin.manual});
  bool get automatic => origin == TranscriptionOrigin.auto;
  Map<String,Object?> toJson()=>{'id':id,'source':source.toJson(),'state':state.name,'language':language,'text':text,'model':model,'durationSeconds':durationSeconds,'estimatedCostUsd':estimatedCostUsd,'errorCode':errorCode,if (origin != TranscriptionOrigin.manual) 'origin':origin.name};
  factory TranscriptionJob.fromJson(Map<String,dynamic> j)=>TranscriptionJob(id:j['id'] as String,source:SourceEventRef.fromJson(Map<String,dynamic>.from(j['source'] as Map)),state:JobState.values.byName(j['state'] as String),language:j['language'] as String?,text:j['text'] as String?,model:j['model'] as String? ?? 'gpt-transcribe',durationSeconds:(j['durationSeconds'] as num?)?.toDouble(),estimatedCostUsd:(j['estimatedCostUsd'] as num?)?.toDouble(),errorCode:j['errorCode'] as String?,origin:transcriptionOriginFromJson(j['origin']));
  @override String toString()=>'TranscriptionJob(${state.name}, redacted)';
}

class ScheduledSend {
  final String id;
  final int revision;
  final SendTarget target;
  final DateTime dueAt;
  final Map<String,dynamic> content;
  final String transactionId;
  final JobState state;
  ScheduledSend({required this.id,this.revision=0,required this.target,required this.dueAt,required Map<String,dynamic> content,required this.transactionId,this.state=JobState.waitingSync}): content=Map.unmodifiable(content);
  Map<String,Object?> toJson()=>{'id':id,'revision':revision,'target':target.toJson(),'dueAt':dueAt.toUtc().toIso8601String(),'content':content,'transactionId':transactionId,'state':state.name};
  factory ScheduledSend.fromJson(Map<String,dynamic> j)=>ScheduledSend(id:j['id'] as String,revision:j['revision'] as int? ?? 0,target:SendTarget.fromJson(Map<String,dynamic>.from(j['target'] as Map)),dueAt:DateTime.parse(j['dueAt'] as String),content:Map<String,dynamic>.from(j['content'] as Map),transactionId:j['transactionId'] as String,state:JobState.values.byName(j['state'] as String));
  @override String toString()=>'ScheduledSend(${state.name}, redacted)';
}
