// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

class NotionSettingsData {
  final String name;
  final Widget avatar;
  final bool incognito;
  final bool privacyPending;
  final String appLock;
  final String appearance;
  final String privateSync;
  final String? status;
  const NotionSettingsData({
    required this.name,
    required this.avatar,
    required this.incognito,
    this.privacyPending = false,
    this.appLock = 'Unknown',
    this.appearance = 'System',
    this.privateSync = 'Not connected',
    this.status,
  });
}

class NotionSettingsActions {
  final VoidCallback? back,
      overflow,
      editProfile,
      appLock,
      devices,
      notifications,
      appearance,
      transcriptions,
      privateSync,
      about;
  final ValueChanged<bool>? incognito;
  const NotionSettingsActions({
    this.back,
    this.overflow,
    this.editProfile,
    this.appLock,
    this.devices,
    this.notifications,
    this.appearance,
    this.transcriptions,
    this.privateSync,
    this.about,
    this.incognito,
  });
}

/// Production settings document; adapters supply actual profile and settings.
class NotionSettingsPage extends StatelessWidget {
  final NotionSettingsData data;
  final NotionSettingsActions actions;
  const NotionSettingsPage({
    super.key,
    required this.data,
    required this.actions,
  });
  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: NotionTokens.headerHeight,
        titleSpacing: 0,
        leading: NotionIconButton(
          icon: Icons.chevron_left,
          label: 'Back',
          onPressed: actions.back ?? () => Navigator.maybePop(context),
        ),
        title: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'My chats / ',
                style: TextStyle(color: secondary),
              ),
              const TextSpan(text: 'Settings'),
            ],
          ),
          style: const TextStyle(fontSize: 17),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          NotionIconButton(
            icon: Icons.more_horiz,
            label: 'More settings',
            onPressed: actions.overflow,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            key: const PageStorageKey('notion-settings'),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Semantics(
                  label: 'Settings illustration',
                  image: true,
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: 96,
                      height: 88,
                      child: CustomPaint(
                        painter: _SettingsIllustration(
                          Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Settings',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Your account and private preferences.',
                style: TextStyle(fontSize: 15, height: 1.4, color: secondary),
              ),
              const SizedBox(height: 24),
              Text('Account', style: TextStyle(fontSize: 14, color: secondary)),
              const SizedBox(height: 10),
              InkWell(
                onTap: actions.editProfile,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox.square(
                          dimension: 44,
                          child: data.avatar,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Edit profile',
                              style: TextStyle(
                                fontSize: 14,
                                color: secondary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const NotionDetailsSection(title: 'Privacy'),
              NotionListRow(
                leading: const Icon(Icons.visibility_off_outlined),
                title: 'Incognito mode',
                subtitle:
                    'Suppresses automatic typing, receipts and presence on this device',
                trailing: Switch(
                  value: data.incognito,
                  onChanged: data.privacyPending ? null : actions.incognito,
                ),
              ),
              if (data.status != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      data.status!,
                      style: TextStyle(color: secondary, fontSize: 13),
                    ),
                  ),
                ),
              NotionListRow(
                leading: const Icon(Icons.lock_outline),
                title: 'App lock',
                trailing: _value(context, data.appLock),
                onTap: actions.appLock,
              ),
              NotionListRow(
                leading: const Icon(Icons.devices_outlined),
                title: 'Devices & keys',
                onTap: actions.devices,
              ),
              const NotionDetailsSection(title: 'Preferences'),
              NotionListRow(
                leading: const Icon(Icons.notifications_none_outlined),
                title: 'Notifications',
                trailing: _value(context, 'Configure'),
                onTap: actions.notifications,
              ),
              NotionListRow(
                leading: const Icon(Icons.dark_mode_outlined),
                title: 'Appearance',
                trailing: _value(context, data.appearance),
                onTap: actions.appearance,
              ),
              NotionListRow(
                leading: const Icon(Icons.description_outlined),
                title: 'Transcriptions',
                trailing: _value(context, 'Manual'),
                onTap: actions.transcriptions,
              ),
              NotionListRow(
                leading: const Icon(Icons.sync_outlined),
                title: 'Private sync',
                subtitle: data.privateSync,
                onTap: actions.privateSync,
              ),
              const NotionDetailsSection(),
              NotionListRow(
                leading: const Icon(Icons.help_outline),
                title: 'About',
                onTap: actions.about,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _value(BuildContext context, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(fit: FlexFit.loose, child: NotionValueTag(value)),
      const SizedBox(width: 8),
      const Icon(Icons.chevron_right, size: 20),
    ],
  );
}

/// Original vector linework, drawn for Personal Chat; no third-party artwork.
class _SettingsIllustration extends CustomPainter {
  final Color color;
  const _SettingsIllustration(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 96, size.height / 88);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    final hair = Path()
      ..moveTo(20, 24)
      ..cubicTo(8, 24, 8, 42, 17, 44)
      ..cubicTo(10, 53, 18, 60, 28, 53)
      ..lineTo(32, 34)
      ..cubicTo(43, 36, 49, 30, 46, 20)
      ..cubicTo(47, 10, 33, 5, 29, 13)
      ..cubicTo(18, 10, 15, 15, 20, 24)
      ..close();
    canvas.drawPath(hair, fill);
    final body = Path()
      ..moveTo(6, 83)
      ..cubicTo(13, 63, 23, 57, 31, 59)
      ..lineTo(30, 52)
      ..cubicTo(41, 51, 47, 40, 43, 30)
      ..moveTo(30, 53)
      ..cubicTo(30, 65, 37, 66, 40, 58)
      ..cubicTo(47, 60, 51, 70, 55, 79)
      ..lineTo(69, 63)
      ..moveTo(70, 62)
      ..lineTo(64, 55)
      ..lineTo(67, 49)
      ..lineTo(72, 52)
      ..lineTo(78, 42);
    canvas.drawPath(body, stroke);
    canvas.drawCircle(const Offset(32, 35), 1.4, fill);
    canvas.drawCircle(const Offset(40, 35), 1.4, fill);
    canvas.drawPath(
      Path()
        ..moveTo(36, 36)
        ..lineTo(35, 42)
        ..moveTo(33, 46)
        ..quadraticBezierTo(36, 48, 39, 44),
      stroke,
    );
    final wrench = Path()
      ..moveTo(72, 55)
      ..lineTo(80, 33)
      ..cubicTo(91, 34, 94, 21, 87, 17)
      ..lineTo(83, 26)
      ..lineTo(78, 24)
      ..lineTo(80, 15)
      ..cubicTo(68, 18, 67, 29, 74, 32)
      ..lineTo(65, 53)
      ..close();
    canvas.drawPath(wrench, stroke);
    canvas.drawLine(const Offset(59, 84), const Offset(70, 65), stroke);
    canvas.drawLine(const Offset(81, 8), const Offset(83, 3), stroke);
    canvas.drawLine(const Offset(90, 13), const Offset(95, 10), stroke);
    canvas.drawLine(const Offset(91, 39), const Offset(95, 42), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SettingsIllustration oldDelegate) =>
      oldDelegate.color != color;
}
