// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:matrix/matrix.dart';

import 'sticker_models.dart';

/// Network sticker packs saved in the account's own data.
///
/// The bridges keep imported packs in the login's personal filtering space
/// (mautrix-go `ImportImagePack`). When that space is missing, disabled or
/// the bridge can't write to it, the pack's preview (the same content, its
/// stickers already uploaded by the bridge) is saved here instead, so the
/// pack still syncs to every ChatLoom device. Account data events are
/// limited to ~64 KB, so a pack is split into parts:
///
/// * `pl.personal.chat.sticker_pack.v1.<id>.0` holds the pack metadata, the
///   number of parts, a revision and the first images;
/// * `….<id>.<n>` (n ≥ 1) holds more images with the same revision.
///
/// Parts are written last-first, so a device that sees part 0 of a
/// revision gets the other parts in the same or an earlier sync. A removed
/// pack's parts are overwritten with `{}` (Matrix can't delete account
/// data). Like room packs, the server can read the content (not end-to-end
/// encrypted): pack metadata and media URLs, never messages.
const accountPackTypePrefix = 'pl.personal.chat.sticker_pack.v1.';

/// Byte budget of one part (UTF-8 JSON), well under the event size limit.
const accountPackPartBudget = 48 * 1024;

/// At most this many parts (Telegram's largest sets fit in four).
const accountPackMaxParts = 8;

/// The account data id of a network pack: `<network>.<name>`, lowercase
/// (Telegram set names are case-insensitive), so every device that saves
/// the same pack writes the same events.
String accountPackIdOf(String network, String name) {
  String clean(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
  return '${clean(network)}.${clean(name)}';
}

String accountPackType(String id, int part) =>
    '$accountPackTypePrefix$id.$part';

/// The id of a part-0 event type, or null for any other type.
String? accountPackIdOfType(String type) {
  if (!type.startsWith(accountPackTypePrefix) || !type.endsWith('.0')) {
    return null;
  }
  final id = type.substring(
    accountPackTypePrefix.length,
    type.length - '.0'.length,
  );
  return RegExp(r'^[a-z0-9_-]+\.[a-z0-9_-]+$').hasMatch(id) ? id : null;
}

/// A pack does not fit in [accountPackMaxParts] parts.
class AccountPackTooLarge implements Exception {
  const AccountPackTooLarge();
  @override
  String toString() => 'AccountPackTooLarge';
}

int _bytes(Object? json) => utf8.encode(jsonEncode(json)).length;

/// Splits [content] into part contents (index = part number). Image `info`
/// is trimmed like library items (what a bridge needs to send the sticker
/// natively stays). Throws [AccountPackTooLarge].
List<Map<String, Object?>> encodeAccountPack(
  ImagePackContent content, {
  required String packUrl,
  required String network,
  required int rev,
}) {
  final pack = content.pack.toJson();
  final parts = <Map<String, Object?>>[];
  var images = <String, Object?>{};
  Map<String, Object?> head() => {
    'pack': pack,
    'pack_url': packUrl,
    'network': network,
    'rev': rev,
    'parts': 0,
  };
  var size = _bytes(head()) + 16;
  void close() {
    parts.add({if (parts.isEmpty) ...head() else 'rev': rev, 'images': images});
    images = {};
    size = _bytes({'rev': rev}) + 16;
  }

  for (final entry in content.images.entries) {
    final json = entry.value.toJson();
    final info = json['info'];
    if (info is Map) json['info'] = trimStickerInfo(info.cast());
    final weight = _bytes({entry.key: json});
    if (weight + size > accountPackPartBudget && images.isNotEmpty) close();
    images[entry.key] = json;
    size += weight;
  }
  if (images.isNotEmpty || parts.isEmpty) close();
  if (parts.length > accountPackMaxParts) throw const AccountPackTooLarge();
  parts.first['parts'] = parts.length;
  return parts;
}

/// The saved pack [id] as read by [read] (synced account data by type), or
/// null when it is not saved (missing or removed). Parts of another
/// revision (not synced yet) are skipped.
SavedAccountPack? decodeAccountPack(
  String id,
  Map<String, Object?>? Function(String type) read,
) {
  final head = read(accountPackType(id, 0));
  final rev = head?['rev'];
  final pack = head?['pack'];
  if (head == null || rev is! int || pack is! Map) return null;
  final count = head['parts'];
  final parts = count is int ? count.clamp(1, accountPackMaxParts) : 1;
  final images = <String, Object?>{};
  for (var i = 0; i < parts; i++) {
    final part = i == 0 ? head : read(accountPackType(id, i));
    if (part == null || part['rev'] != rev) continue;
    final more = part['images'];
    if (more is Map) {
      for (final entry in more.entries) {
        if (entry.key is String && entry.value is Map) {
          images[entry.key as String] = entry.value;
        }
      }
    }
  }
  if (images.isEmpty) return null;
  final ImagePackContent content;
  try {
    content = ImagePackContent.fromJson({'pack': pack, 'images': images});
  } catch (_) {
    return null;
  }
  String? text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
  return SavedAccountPack(
    id: id,
    content: content,
    rev: rev,
    parts: parts,
    packUrl: text(head['pack_url']),
    network: text(head['network']),
  );
}

/// A pack read back from account data.
class SavedAccountPack {
  const SavedAccountPack({
    required this.id,
    required this.content,
    required this.rev,
    required this.parts,
    this.packUrl,
    this.network,
  });

  final String id;
  final ImagePackContent content;
  final int rev;
  final int parts;
  final String? packUrl;
  final String? network;

  StickerPackRef ref({String? title, int addedTs = 0}) =>
      StickerPackRef.account(
        id,
        packUrl: packUrl,
        network: network,
        title: title ?? content.pack.displayName,
        addedTs: addedTs,
      );
}
