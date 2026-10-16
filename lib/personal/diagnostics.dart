// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/privacy_transport.dart';
import 'package:fluffychat/personal/storage/storage_failure.dart';
import 'package:http/http.dart' as http;

import 'network_failure_stub.dart'
    if (dart.library.io) 'network_failure_native.dart'
    as platform;

bool isPersonalNetworkFailure(Object error) =>
    error is http.ClientException || platform.isNativeNetworkFailure(error);

enum PersonalFailurePhase {
  bindings,
  settings,
  crypto,
  backgroundClients,
  clients,
  gui,
  registry,
  accountRestore,
  localStorage,
  journalDiscovery,
  journalValidation,
  journalReplay,
  journalPublish,
  timelineLoad,
  action,
}

/// Only fixed codes and source locations may leave the error boundary.
class PersonalDiagnostic {
  final String code;
  final PersonalFailurePhase phase;
  const PersonalDiagnostic(this.code, this.phase);

  factory PersonalDiagnostic.from(Object error, PersonalFailurePhase phase) {
    if (error is StorageFailure) {
      return PersonalDiagnostic('storage_${error.code.name}', phase);
    }
    if (error is PrivacySuppressed) {
      return PersonalDiagnostic('privacy_suppressed', phase);
    }
    if (error is TimeoutException) {
      return PersonalDiagnostic('network_timeout', phase);
    }
    if (isPersonalNetworkFailure(error)) {
      return PersonalDiagnostic('network_unavailable', phase);
    }
    if (error is StateError) {
      const states = <String, String>{
        'Account registry is invalid': 'account_registry_invalid',
        'No element': 'empty_result',
        'Too many elements': 'ambiguous_result',
        'A signed-in account is required': 'account_unavailable',
        'Private client is closed': 'client_closed',
        'Encrypted outbox unavailable': 'outbox_unavailable',
        'Private encrypted sync is not connected': 'private_sync_disconnected',
        'Journal synchronization is incomplete': 'journal_incomplete',
        'Private journal is not configured': 'journal_missing',
        'Invalid encrypted journal': 'journal_invalid',
        'Unsafe journal membership': 'journal_membership_untrusted',
        'Journal history pagination stalled': 'journal_history_stalled',
        'Journal history exceeds safe pagination limit':
            'journal_history_limit',
      };
      return PersonalDiagnostic(
        states[error.message] ?? 'invalid_state',
        phase,
      );
    }
    if (error is TypeError) {
      return PersonalDiagnostic('invalid_data_type', phase);
    }
    return PersonalDiagnostic('operation_failed', phase);
  }

  String report([StackTrace? stack]) {
    // No symbols, absolute paths, query strings, IDs or exception text.
    // Compiled stack coordinates are already one-based. Only the two fixed
    // asset names may survive a bare or HTTP(S) frame; never its URL or symbol.
    final locations = RegExp(
      r'package:fluffychat/([a-zA-Z0-9_/]+\.dart):(\d+)(?::(\d+))?\)'
      r'|(?:^|[\s(])(?:https?://[^\s()?#]+/)?'
      r'(main\.dart\.js|native_executor\.js):(\d+):(\d+)(?=$|[\s)])',
      multiLine: true,
    );
    final frames = <String>{};
    for (final match in locations.allMatches(stack?.toString() ?? '')) {
      frames.add(
        match[1] != null
            ? '${match[1]}:${match[2]}${match[3] == null ? '' : ':${match[3]}'}'
            : '${match[4]}:${match[5]}:${match[6]}',
      );
      if (frames.length == 8) break;
    }
    final sourceLocations = frames.join('\n');
    return 'Personal Chat: $code [${phase.name}]'
        '${sourceLocations.isEmpty ? '' : '\n$sourceLocations'}';
  }
}

enum PrivateSyncFailure {
  storageUnavailable,
  offline,
  timeout,
  journalMissing,
  journalInvalid,
  membershipUntrusted,
  journalUnavailable,
}

PrivateSyncFailure privateSyncFailure(
  Object error,
  PersonalFailurePhase phase,
) {
  final code = PersonalDiagnostic.from(error, phase).code;
  if (error is StorageFailure || phase == PersonalFailurePhase.localStorage) {
    return PrivateSyncFailure.storageUnavailable;
  }
  return switch (code) {
    'network_timeout' => PrivateSyncFailure.timeout,
    'network_unavailable' => PrivateSyncFailure.offline,
    'journal_missing' => PrivateSyncFailure.journalMissing,
    'journal_invalid' => PrivateSyncFailure.journalInvalid,
    'journal_membership_untrusted' => PrivateSyncFailure.membershipUntrusted,
    _ => PrivateSyncFailure.journalUnavailable,
  };
}

extension PrivateSyncFailureText on PrivateSyncFailure {
  String get message => switch (this) {
    PrivateSyncFailure.storageUnavailable =>
      'Could not open encrypted private storage. Your data is preserved. Unlock your device and retry.',
    PrivateSyncFailure.offline =>
      'Private sync is offline. Local drafts and pending changes are preserved. Check your connection and retry.',
    PrivateSyncFailure.timeout =>
      'Private sync timed out. Local drafts and pending changes are preserved. Retry when connected.',
    PrivateSyncFailure.journalMissing =>
      'Private sync is not configured. Local data is preserved. Connect private sync to continue.',
    PrivateSyncFailure.journalInvalid =>
      'Private sync is paused because its encrypted journal is invalid. Your local data is preserved.',
    PrivateSyncFailure.membershipUntrusted =>
      'Private sync is paused because the private room membership is untrusted. Check its membership before retrying.',
    PrivateSyncFailure.journalUnavailable =>
      'Private sync could not read its encrypted journal. Your local data is preserved. Check encryption keys and retry.',
  };
}
