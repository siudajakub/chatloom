// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: avoid_relative_lib_imports
import 'dart:io';

import 'package:test/test.dart';

import '../../../lib/personal/media/immediate_media_outbox.dart';
import '../../../lib/personal/media/pending_media_store.dart';
import '../../../lib/personal/round_video/round_availability.dart';
import '../../../lib/personal/round_video/round_media_preparer.dart';
import '../../../lib/personal/round_video/telegram_room_binding.dart';
import '../../../lib/personal/storage/storage_failure.dart';

void main() {
  test('every gate code has short English copy', () {
    final ascii = RegExp(r'^[\x20-\x7E]+$');
    for (final code in RoundGateCode.values) {
      final message = roundGateMessage(code);
      expect(message, matches(ascii), reason: code.name);
      expect(message.length, lessThan(140), reason: code.name);
      expect(message, endsWith('.'), reason: code.name);
    }
  });

  test('stock bridge copy names the missing round bridge', () {
    expect(
      roundFailureMessage(
        const ImmediateMediaRejected('round:bridgeLacksRoundSupport'),
      ),
      "This Telegram bridge doesn't support round video messages yet. "
      'It needs the ChatLoom round bridge.',
    );
    expect(
      roundFailureMessage(
        const ImmediateMediaRejected('trustedRoundBridgeRequired'),
      ),
      startsWith("This Telegram bridge doesn't support"),
    );
  });

  test('availability kinds', () {
    RoundAvailability of(RoundGateCode code) =>
        RoundAvailability.fromReport(RoundGateReport(code));
    expect(of(RoundGateCode.available).canRecord, isTrue);
    expect(of(RoundGateCode.available).reason, isNull);
    expect(of(RoundGateCode.needsTrust).kind, RoundAvailabilityKind.needsTrust);
    expect(of(RoundGateCode.uploadLimitUnknown).canRecord, isTrue);
    for (final code in RoundGateCode.values.where((c) => c.terminal)) {
      expect(of(code).canRecord, isFalse, reason: code.name);
      expect(of(code).reason, isNotEmpty, reason: code.name);
    }
  });

  test('failure messages are specific and never leak details', () {
    expect(
      roundFailureMessage(
        const ImmediateMediaRejected('saveExistingDraftFirst'),
      ),
      contains('previous round video'),
    );
    expect(
      roundFailureMessage(const ImmediateMediaRejected('pendingMediaQuota')),
      contains('Not enough room'),
    );
    expect(
      roundFailureMessage(const PendingMediaFailure('storeQuota')),
      contains('Not enough room'),
    );
    expect(
      roundFailureMessage(const RoundCaptureException('permission_denied')),
      contains('camera and microphone'),
    );
    expect(
      roundFailureMessage(
        const StorageFailure(StorageFailureCode.keyUnavailable),
      ),
      contains('Encrypted storage'),
    );
    expect(
      roundFailureMessage(const FileSystemException('secret/path')),
      isNot(contains('secret')),
    );
    expect(
      roundFailureMessage(const ImmediateMediaRejected('round:unconfirmed')),
      roundFailureFallback,
    );
    expect(roundFailureMessage(StateError('x')), roundFailureFallback);
    expect(
      roundFailureFallback,
      'Round video failed before recording. Nothing was sent.',
    );
  });
}
