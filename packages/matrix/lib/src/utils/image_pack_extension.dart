// SPDX-FileCopyrightText: 2019-Present, 2020, 2021 Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:slugify/slugify.dart';

import '../../matrix_api_lite.dart';
import '../room.dart';

// ChatLoom: the stable MSC2545 names next to the unstable `im.ponies.*`
// ones. mautrix bridges (bridgev2 `provisionutil/imagepack.go`) write only
// the stable room state type. See UPSTREAM-PIN.md (2026-10-22).

/// Room state type of an image pack (stable MSC2545 name).
const imagePackStateType = 'm.room.image_pack';

/// Room state type of an image pack (unstable MSC2545 name).
const unstableImagePackStateType = 'im.ponies.room_emotes';

/// Account data listing the rooms whose packs are enabled everywhere.
const imagePackRoomsType = 'm.image_pack.rooms';
const unstableImagePackRoomsType = 'im.ponies.emote_rooms';

/// Account data holding the user's own pack.
const userImagePackType = 'm.image_pack';
const unstableUserImagePackType = 'im.ponies.user_emotes';

/// Both room state types of an image pack, unstable first (upstream order).
const imagePackStateTypes = [unstableImagePackStateType, imagePackStateType];

final _partSuffix = RegExp(r' \(part \d+\)$');

/// ChatLoom: the image packs of one room state type, keyed by state key,
/// with the packs a bridge split into several state events joined again.
///
/// mautrix bridges split a pack larger than ~62 KB into parts that share
/// `fi.mau.combined_pack_key` (and carry `fi.mau.combined_pack_index` /
/// `fi.mau.combined_pack_count`); each part's display name ends with
/// " (part N)". The parts are merged into one pack under the combined key,
/// in part order, with the suffix removed. A pack whose parts have not all
/// arrived yet is returned with the parts that have.
Map<String, ImagePackContent> combineImagePackStates(
  Map<String, StrippedStateEvent> byStateKey,
) {
  final packs = <String, ImagePackContent>{};
  final parts = <String, List<(int, String, ImagePackContent)>>{};
  for (final entry in byStateKey.entries) {
    final content = entry.value.content;
    final ImagePackContent pack;
    try {
      pack = ImagePackContent.fromJson(content);
    } catch (_) {
      continue;
    }
    final combined = content['fi.mau.combined_pack_key'];
    if (combined is String && combined.isNotEmpty) {
      final index = content['fi.mau.combined_pack_index'];
      parts
          .putIfAbsent(combined, () => [])
          .add((index is int ? index : 0, entry.key, pack));
      continue;
    }
    packs[entry.key] = pack;
  }
  for (final entry in parts.entries) {
    final list = entry.value
      ..sort((a, b) {
        final byIndex = a.$1.compareTo(b.$1);
        return byIndex != 0 ? byIndex : a.$2.compareTo(b.$2);
      });
    final meta = list.first.$3.pack.toJson();
    final name = meta['display_name'];
    if (name is String) meta['display_name'] = name.replaceFirst(_partSuffix, '');
    packs[entry.key] = ImagePackContent(
      images: {for (final part in list) ...part.$3.images},
      pack: ImagePackPackContent.fromJson(meta),
    );
  }
  return packs;
}

/// ChatLoom: every image pack [room] holds, both state types together
/// (split packs joined), keyed by state key. A state key present in both
/// types keeps the stable pack.
Map<String, ImagePackContent> roomImagePacks(Room room) => {
  for (final type in imagePackStateTypes)
    ...combineImagePackStates(room.states[type] ?? const {}),
};

extension ImagePackRoomExtension on Room {
  /// Get all the active image packs for the specified [usage], mapped by their slug
  Map<String, ImagePackContent> getImagePacks([ImagePackUsage? usage]) {
    final allMxcs = <Uri>{}; // used for easy deduplication
    final packs = <String, ImagePackContent>{};

    void addImagePack(ImagePackContent? imagePack, {Room? room, String? slug}) {
      if (imagePack == null) return;
      final finalSlug = slugify(slug ?? 'pack');
      for (final entry in imagePack.images.entries) {
        final image = entry.value;
        if (allMxcs.contains(image.url)) {
          continue;
        }
        final imageUsage = image.usage ?? imagePack.pack.usage;
        if (usage != null &&
            imageUsage != null &&
            !imageUsage.contains(usage)) {
          continue;
        }
        packs
                .putIfAbsent(
                  finalSlug,
                  () => ImagePackContent.fromJson({})
                    ..pack.displayName =
                        imagePack.pack.displayName ??
                        room?.getLocalizedDisplayname() ??
                        finalSlug
                    ..pack.avatarUrl = imagePack.pack.avatarUrl ?? room?.avatar
                    ..pack.attribution = imagePack.pack.attribution,
                )
                .images[entry.key] =
            image;
        allMxcs.add(image.url);
      }
    }

    // first we add the user image pack
    // ChatLoom: unstable and stable account data.
    for (final type in [unstableUserImagePackType, userImagePackType]) {
      final event = client.accountData[type];
      if (event == null) continue;
      addImagePack(event.parsedImagePackContent, slug: 'user');
    }
    // next we add all the external image packs
    // ChatLoom: unstable and stable room lists, stable/split room packs.
    for (final type in [unstableImagePackRoomsType, imagePackRoomsType]) {
      final packRooms = client.accountData[type];
      final rooms = packRooms?.content.tryGetMap<String, Object?>('rooms');
      if (packRooms == null || rooms == null) continue;
      for (final roomEntry in rooms.entries) {
        final roomId = roomEntry.key;
        final room = client.getRoomById(roomId);
        final roomEntryValue = roomEntry.value;
        if (room != null && roomEntryValue is Map<String, Object?>) {
          final roomPacks = roomImagePacks(room);
          for (final stateKeyEntry in roomEntryValue.entries) {
            final stateKey = stateKeyEntry.key;
            final fallbackSlug =
                '${room.getLocalizedDisplayname()}-${stateKey.isNotEmpty ? '$stateKey-' : ''}${room.id}';
            addImagePack(
              roomPacks[stateKey],
              room: room,
              slug: fallbackSlug,
            );
          }
        }
      }
    }
    // finally we add all of this rooms state
    for (final entry in roomImagePacks(this).entries) {
      addImagePack(
        entry.value,
        room: this,
        slug: entry.key.isNotEmpty ? entry.key : 'room',
      );
    }
    return packs;
  }

  /// Get a flat view of all the image packs of a specified [usage], that is a map of all
  /// slugs to a map of the image code to their mxc url
  Map<String, Map<String, String>> getImagePacksFlat([ImagePackUsage? usage]) =>
      getImagePacks(usage).map(
        (k, v) =>
            MapEntry(k, v.images.map((k, v) => MapEntry(k, v.url.toString()))),
      );
}
