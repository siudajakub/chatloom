// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/ui/notion/notion_motion.dart';
import 'package:flutter/widgets.dart';

/// Opening a settings or details page used to call [PersonalClient.load] in
/// `initState`. That revalidates the private journal (membership request,
/// possibly a replay) and its result landed in the middle of the page
/// transition. Pages now ask for a load through here instead:
///
/// * the load starts only after the page finished sliding in, and
/// * a ready client that was loaded through here less than [fresh] ago is not
///   loaded again; a not-ready client is always loaded.
///
/// The private sync itself keeps its own live updates; this only throttles
/// the extra revalidation that page opens triggered.
abstract final class PersonalPageLoad {
  static const fresh = Duration(seconds: 30);
  static final _loadedAt = Expando<DateTime>('personal page load');

  /// Whether [personal] needs a page-triggered load now.
  static bool needed(PersonalClient personal) {
    if (!personal.ready) return true;
    final at = _loadedAt[personal];
    return at == null || DateTime.now().difference(at) >= fresh;
  }

  /// Loads [personal] after the route hosting [context] settled, unless a
  /// recent load makes it redundant.
  static void request(BuildContext context, PersonalClient personal) {
    if (!needed(personal)) return;
    NotionMotion.afterRouteSettled(context, () => unawaited(_load(personal)));
  }

  static Future<void> _load(PersonalClient personal) async {
    if (!needed(personal)) return;
    try {
      await personal.load();
    } catch (_) {
      // [PersonalClient] records its own failure state for the UI.
      return;
    }
    if (personal.ready) _loadedAt[personal] = DateTime.now();
  }
}
