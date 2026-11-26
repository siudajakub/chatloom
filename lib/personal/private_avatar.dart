// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'memory_trim.dart';
import 'personal_client.dart';

/// Size limit of a private avatar, plaintext and encrypted.
const privateAvatarMaxBytes = 2 * 1024 * 1024;

/// Private store key of the avatar the user set for a conversation entity.
String privateAvatarKey(String entityId) => 'avatar:$entityId';

/// Prefix of `ConversationMetadata.avatarAsset` of a merged person whose
/// photo is the network photo of one of its chats (`source:<room id>`).
const personAvatarSourcePrefix = 'source:';

/// The chat whose network photo a person shows, from its `avatarAsset`.
String? personAvatarSource(Object? asset) =>
    asset is String &&
        asset.startsWith(personAvatarSourcePrefix) &&
        asset.length > personAvatarSourcePrefix.length
    ? asset.substring(personAvatarSourcePrefix.length)
    : null;

/// Whether the private avatar of [entityId] is the one shown: one is set
/// and the person did not choose a network photo instead.
bool privateAvatarShown(PersonalClient personal, String entityId) =>
    personal.values.containsKey(privateAvatarKey(entityId)) &&
    personAvatarSource(personal.values['org:$entityId']?['avatarAsset']) ==
        null;

/// Downloads and decrypts the private avatar stored for [entityId].
///
/// Returns null when none is set or it cannot be loaded; never throws.
Future<Uint8List?> downloadPrivateAvatar(
  PersonalClient personal,
  String entityId,
) async {
  final value = personal.values[privateAvatarKey(entityId)];
  if (value == null) return null;
  return downloadPrivateAvatarValue(personal.client, value);
}

/// Decrypted avatars by ciphertext hash, so list rows do not download and
/// decrypt again on every rebuild or scroll. Memory only, least recently
/// used first out, bounded by [_decryptedLimit] entries and
/// [privateAvatarCacheBytes] (one avatar may be up to 2 MB, so 64 entries
/// alone allowed 128 MB). [MemoryTrim] empties it only under memory
/// pressure (refilling costs a download and decryption); a shown avatar
/// keeps its own bytes and image.
final _decrypted = <String, Uint8List>{};
const _decryptedLimit = 64;
int _decryptedBytes = 0;
bool _trimRegistered = false;

/// Byte budget of the decrypted private avatar cache.
const privateAvatarCacheBytes = 8 * 1024 * 1024;

void _remember(String hash, Uint8List bytes) {
  if (!_trimRegistered) {
    _trimRegistered = true;
    MemoryTrim.addPressureCache(clearPrivateAvatarCache);
  }
  final previous = _decrypted.remove(hash);
  if (previous != null) _decryptedBytes -= previous.lengthInBytes;
  // Larger than the whole budget: shown once, never kept.
  if (bytes.lengthInBytes > privateAvatarCacheBytes) return;
  while (_decrypted.isNotEmpty &&
      (_decrypted.length >= _decryptedLimit ||
          _decryptedBytes + bytes.lengthInBytes > privateAvatarCacheBytes)) {
    final oldest = _decrypted.keys.first;
    _decryptedBytes -= _decrypted.remove(oldest)!.lengthInBytes;
  }
  _decrypted[hash] = bytes;
  _decryptedBytes += bytes.lengthInBytes;
}

Uint8List? _recall(String hash) {
  final bytes = _decrypted.remove(hash);
  if (bytes != null) _decrypted[hash] = bytes;
  return bytes;
}

/// Empties the decrypted private avatar cache (memory trim, tests).
void clearPrivateAvatarCache() {
  _decrypted.clear();
  _decryptedBytes = 0;
}

@visibleForTesting
({int entries, int bytes}) get debugPrivateAvatarCache =>
    (entries: _decrypted.length, bytes: _decryptedBytes);

@visibleForTesting
void debugRememberPrivateAvatar(String hash, Uint8List bytes) =>
    _remember(hash, bytes);

@visibleForTesting
void debugResetPrivateAvatarCache() {
  clearPrivateAvatarCache();
  _trimRegistered = false;
}

/// Decrypts one stored private avatar record (see `uploadPrivateAvatar`).
Future<Uint8List?> downloadPrivateAvatarValue(
  Client client,
  Map<String, dynamic> value,
) async {
  final hash = value['sha256'];
  final cached = hash is String ? _recall(hash) : null;
  if (cached != null) return cached;
  final bytes = await _download(client, value);
  if (bytes != null && hash is String) _remember(hash, bytes);
  return bytes;
}

/// Plaintext of [value] when already in memory, to render without a flash.
Uint8List? cachedPrivateAvatar(Map<String, dynamic>? value) {
  final hash = value?['sha256'];
  return hash is String ? _recall(hash) : null;
}

Future<Uint8List?> _legacy(
  Client client,
  Uri uri,
  Map<String, dynamic> value,
) async {
  final content = await client.getContent(uri.host, uri.pathSegments.single);
  return _decrypt(client, content.data, value);
}

Future<Uint8List?> _decrypt(
  Client client,
  Uint8List data,
  Map<String, dynamic> value,
) async {
  if (data.length > privateAvatarMaxBytes) return null;
  return await client.nativeImplementations.decryptFile(
    EncryptedFile(
      data: data,
      iv: value['iv'] as String,
      k: value['key'] as String,
      sha256: value['sha256'] as String,
    ),
  );
}

Future<Uint8List?> _download(Client client, Map<String, dynamic> value) async {
  try {
    final uri = Uri.parse(value['mxc'] as String);
    if (uri.scheme != 'mxc' ||
        uri.host.isEmpty ||
        uri.pathSegments.length != 1 ||
        (value['size'] as int? ?? 0) > privateAvatarMaxBytes) {
      return null;
    }
    final Uint8List data;
    try {
      // Authenticated media; the legacy endpoint 404s on current servers.
      data = (await client.getContentAuthed(
        uri.host,
        uri.pathSegments.single,
      )).data;
    } on MatrixException {
      return await _legacy(client, uri, value);
    }
    return await _decrypt(client, data, value);
  } catch (_) {
    return null;
  }
}
