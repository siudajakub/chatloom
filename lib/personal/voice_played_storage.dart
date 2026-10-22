// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/voice_playback.dart';

/// Played voice notes of one account in its encrypted private store
/// (`PersonalClient.readLocalRecord`): local to this device, not synced to
/// the worker journal, no receipt.
class PersonalVoicePlayedStorage implements VoicePlayedStorage {
  PersonalVoicePlayedStorage(this.personal);

  final PersonalClient personal;

  static const key = 'voicePlayed';

  @override
  Future<Map<String, dynamic>?> read() => personal.readLocalRecord(key);

  @override
  Future<void> write(Map<String, dynamic> value) =>
      personal.writeLocalRecord(key, value);
}
