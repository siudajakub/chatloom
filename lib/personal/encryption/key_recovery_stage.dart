// SPDX-License-Identifier: AGPL-3.0-or-later

/// Where the room key for an undecryptable message stands. Drives the
/// "Waiting for this message" bubble and the chat header hint.
enum KeyRecoveryStage {
  /// Asking this account's online key backup.
  backup,

  /// Asked this account's other devices; waiting for one of them to answer.
  devices,

  /// A key arrived; the timeline is decrypting the message again.
  keyReceived,

  /// Nobody answered in time, or the key that arrived does not open it.
  failed,

  /// This session is not cross-signed, so other devices will not share keys
  /// with it.
  verifySession,

  /// The SDK reports this message can never be decrypted here (corrupted
  /// channel, unknown algorithm, no session id, encryption unavailable).
  permanent;

  bool get inFlight => this == backup || this == devices || this == keyReceived;
}
