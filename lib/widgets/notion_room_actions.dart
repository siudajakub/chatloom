// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/person_location.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Source-room actions shared by the unified conversation overflow menu.
/// Leaving a chat is in Chat details (with its own confirmation).
Future<void> performNotionRoomAction(
  BuildContext context,
  Room room,
  String action,
) async {
  switch (action) {
    case 'details':
      context.go('${chatLocation(context, room.id)}/details');
    case 'search':
      context.go('${chatLocation(context, room.id)}/search');
    case 'encryption':
      context.go('${chatLocation(context, room.id)}/encryption');
  }
}
