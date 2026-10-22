// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:matrix/matrix.dart';

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
/// decrypt again on every rebuild or scroll. Memory only.
final _decrypted = <String, Uint8List>{};
const _decryptedLimit = 64;

/// Decrypts one stored private avatar record (see `uploadPrivateAvatar`).
Future<Uint8List?> downloadPrivateAvatarValue(
  Client client,
  Map<String, dynamic> value,
) async {
  final hash = value['sha256'];
  final cached = hash is String ? _decrypted[hash] : null;
  if (cached != null) return cached;
  final bytes = await _download(client, value);
  if (bytes != null && hash is String) {
    if (_decrypted.length >= _decryptedLimit) {
      _decrypted.remove(_decrypted.keys.first);
    }
    _decrypted[hash] = bytes;
  }
  return bytes;
}

/// Plaintext of [value] when already in memory, to render without a flash.
Uint8List? cachedPrivateAvatar(Map<String, dynamic>? value) {
  final hash = value?['sha256'];
  return hash is String ? _decrypted[hash] : null;
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
