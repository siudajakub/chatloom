// SPDX-License-Identifier: AGPL-3.0-or-later
// Fixtures of the sticker catalogue tests: a fake provisioning transport and
// fictional Telegram sets.
import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';

const telegramBridge = BridgeEndpoint(
  botId: '@sh-telegrambot:beeper.local',
  network: 'telegram',
  label: 'Telegram',
);

class CatalogTransport implements BridgeProvisioningTransport {
  final requests = <BridgeProvisioningRequest>[];
  Object? Function(BridgeProvisioningRequest request)? answer;

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) async {
    requests.add(request);
    final value = answer!(request);
    return value is Future ? await value : value;
  }

  List<String> get paths => [for (final r in requests) r.path];
}

Map<String, Object?> catalogSet(
  int i, {
  bool emoji = false,
  bool cover = false,
  bool installed = false,
}) => {
  'short_name': 'FictionalSet$i',
  'title': 'Fictional set $i',
  'url': 'https://t.me/${emoji ? 'addemoji' : 'addstickers'}/FictionalSet$i',
  'count': 10 + i,
  'emoji': emoji,
  'installed': installed,
  'has_cover': cover,
};
