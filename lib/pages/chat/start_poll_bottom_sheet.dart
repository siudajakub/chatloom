// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/media/send_error_text.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart'
    show NotionSettingsToggle;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// What [room]'s network takes in a poll (`poll_max_options`,
/// `poll_option_max_length`, `poll_hidden_votes`,
/// `poll_duplicate_options`; WhatsApp: 12 options of 100 characters,
/// votes always visible, no duplicates). Without a declaration, the
/// limits FluffyChat always used.
@visibleForTesting
({int maxOptions, int optionLength, bool hiddenVotes, bool duplicates})
pollLimitsOf(Room room) {
  final declared = RoomCapabilities.declared(room);
  final limits = declared.evidence(BridgeFeature.poll).limits;
  bool supported(String key) =>
      declared.level(key).result.status != CapabilityStatus.unavailable;
  return (
    maxOptions: limits['poll_max_options'] ?? StartPollBottomSheet.maxOptions,
    optionLength:
        limits['poll_option_max_length'] ?? StartPollBottomSheet.optionLength,
    hiddenVotes: supported('poll_hidden_votes'),
    duplicates: supported('poll_duplicate_options'),
  );
}

/// The new-poll sheet (Telegram's "New Poll"): question, options, two
/// switches, Create. A glass [NotionSheet] like every other sheet.
class StartPollBottomSheet extends StatefulWidget {
  final Room room;
  const StartPollBottomSheet({required this.room, super.key});

  /// Options and option length where the network declares no limit.
  static const maxOptions = 10;
  static const optionLength = 64;

  /// Opens the sheet for [room].
  static Future<void> show(BuildContext context, Room room) =>
      showNotionSheet<void>(
        context: context,
        title: 'New poll',
        builder: (_) => StartPollBottomSheet(room: room),
      );

  @override
  State<StartPollBottomSheet> createState() => _StartPollBottomSheetState();
}

class _StartPollBottomSheetState extends State<StartPollBottomSheet> {
  final TextEditingController _bodyController = TextEditingController();
  bool _allowMultipleAnswers = false;
  final List<TextEditingController> _answers = [
    TextEditingController(),
    TextEditingController(),
  ];
  PollKind _pollKind = PollKind.disclosed;

  bool _canCreate = false;
  bool _duplicate = false;

  String? _txid;

  late final _limits = pollLimitsOf(widget.room);

  /// The sheet closes at once: the poll's bubble shows "Sending" and, if it
  /// fails, "Not sent · Tap to retry" (same transaction on retry).
  Future<void> _createPoll() async {
    final proceed = await showTrustUserInRoomDialog(context, widget.room);
    if (!proceed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    var id = 0;
    _txid ??= widget.room.client.generateUniqueTransactionId();
    final sending = widget.room.startPoll(
      question: _bodyController.text.trim(),
      answers: _answers
          .map(
            (answerController) => PollAnswer(
              id: (++id).toString(),
              mText: answerController.text.trim(),
            ),
          )
          .toList(),
      kind: _limits.hiddenVotes ? _pollKind : PollKind.disclosed,
      maxSelections: _allowMultipleAnswers ? _answers.length : 1,
      txid: _txid,
    );
    Navigator.of(context).pop();
    try {
      await sending;
    } catch (e, s) {
      Logs().w('Unable to create poll', e, s);
      messenger.showSnackBar(SnackBar(content: Text(sendErrorText(e))));
    }
  }

  /// Whether two options are the same where the network refuses that.
  bool _hasDuplicate() {
    if (_limits.duplicates) return false;
    final seen = <String>{};
    for (final answer in _answers) {
      final text = answer.text.trim().toLowerCase();
      if (text.isNotEmpty && !seen.add(text)) return true;
    }
    return false;
  }

  void _updateCanCreate([_]) {
    final duplicate = _hasDuplicate();
    final canCreate =
        _bodyController.text.trim().isNotEmpty &&
        !_answers.any((controller) => controller.text.trim().isEmpty) &&
        !duplicate;
    if (_canCreate != canCreate || _duplicate != duplicate) {
      setState(() {
        _canCreate = canCreate;
        _duplicate = duplicate;
      });
    }
  }

  @override
  void dispose() {
    _bodyController.dispose();
    for (final answerController in _answers) {
      answerController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final tokens = context.notion;
    final limits = _limits;
    final left = limits.maxOptions - _answers.length;
    return Padding(
      // Above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NotionTextField(
              key: const ValueKey('poll-question'),
              label: 'Question',
              hint: l10n.pollQuestion,
              controller: _bodyController,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              inputFormatters: [LengthLimitingTextInputFormatter(1024)],
              textInputAction: TextInputAction.next,
              onChanged: _updateCanCreate,
            ),
            const SizedBox(height: NotionSpace.md),
            Padding(
              padding: const EdgeInsets.only(bottom: NotionSpace.xs),
              child: Text('Options', style: tokens.typography.sectionLabel),
            ),
            for (final (index, answer) in _answers.indexed)
              Padding(
                key: ObjectKey(answer),
                padding: const EdgeInsets.only(bottom: NotionSpace.xs),
                child: NotionTextField(
                  hint: 'Option ${index + 1}',
                  controller: answer,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(limits.optionLength),
                  ],
                  textInputAction: TextInputAction.next,
                  onChanged: _updateCanCreate,
                  suffix: _answers.length <= 2
                      ? null
                      : IconButton(
                          tooltip: 'Remove option',
                          icon: const Icon(
                            Icons.close_rounded,
                            size: NotionSize.icon,
                          ),
                          onPressed: () {
                            setState(() => _answers.remove(answer));
                            answer.dispose();
                            _updateCanCreate();
                          },
                        ),
                ),
              ),
            if (_duplicate)
              Padding(
                padding: const EdgeInsets.only(bottom: NotionSpace.xs),
                child: Text(
                  'Each option must be different on this network.',
                  style: NotionType.caption.copyWith(
                    color: tokens.colors.danger,
                  ),
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: NotionButton.ghost(
                key: const ValueKey('poll-add-option'),
                icon: Icons.add_rounded,
                label: left > 0
                    ? l10n.addAnswerOption
                    : 'Up to ${limits.maxOptions} options',
                onPressed: left > 0
                    ? () {
                        setState(() => _answers.add(TextEditingController()));
                        _updateCanCreate();
                      }
                    : null,
              ),
            ),
            const SizedBox(height: NotionSpace.xs),
            if (limits.hiddenVotes)
              NotionSettingsToggle(
                title: l10n.answersVisible,
                value: _pollKind == PollKind.disclosed,
                onChanged: (allow) => setState(() {
                  _pollKind = allow ? PollKind.disclosed : PollKind.undisclosed;
                }),
              ),
            NotionSettingsToggle(
              title: l10n.allowMultipleAnswers,
              value: _allowMultipleAnswers,
              onChanged: (allow) => setState(() {
                _allowMultipleAnswers = allow;
              }),
            ),
            const SizedBox(height: NotionSpace.md),
            NotionButton.primary(
              key: const ValueKey('poll-create'),
              label: 'Create poll',
              expand: true,
              onPressed: _canCreate ? _createPoll : null,
            ),
          ],
        ),
      ),
    );
  }
}
