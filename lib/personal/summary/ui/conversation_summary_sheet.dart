// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

enum SummaryUiStage { loadingHistory, syncing, waitingWorker, summarizing }

/// Real progress from history loading and the worker, without invented percent.
class SummaryUiProgress {
  final SummaryUiStage stage;
  final int messageCount;

  const SummaryUiProgress({required this.stage, this.messageCount = 0});
}

typedef SummaryRunner =
    Future<SummaryResult> Function(
      SummaryRequest request,
      ValueChanged<SummaryUiProgress> onProgress,
      SummaryCancellation cancellation,
    );

/// A private reading surface opened from a group's conversation menu.
/// Closing it cancels the current operation and invalidates late completions.
Future<void> showConversationSummary(
  BuildContext context, {
  required String chatName,
  required SummaryRunner summarize,
  Listenable? accessChanges,
  bool Function()? isCurrent,
}) => showNotionSheet<void>(
  context: context,
  title: 'Conversation summary',
  builder: (context) => ConversationSummarySheet(
    chatName: chatName,
    summarize: summarize,
    accessChanges: accessChanges,
    isCurrent: isCurrent,
  ),
);

enum _SummaryView { options, running, result, failure }

class ConversationSummarySheet extends StatefulWidget {
  final String chatName;
  final SummaryRunner summarize;
  final Listenable? accessChanges;
  final bool Function()? isCurrent;

  const ConversationSummarySheet({
    super.key,
    required this.chatName,
    required this.summarize,
    this.accessChanges,
    this.isCurrent,
  });

  @override
  State<ConversationSummarySheet> createState() =>
      _ConversationSummarySheetState();
}

class _ConversationSummarySheetState extends State<ConversationSummarySheet> {
  final _amount = TextEditingController(text: '100');
  final _scroll = ScrollController();
  final _amounts = <SummaryScopeKind, String>{
    SummaryScopeKind.messages: '100',
    SummaryScopeKind.hours: '24',
    SummaryScopeKind.days: '7',
  };
  SummaryScopeKind _scope = SummaryScopeKind.messages;
  SummaryDetail _detail = SummaryDetail.standard;
  String _language = 'pl';
  _SummaryView _view = _SummaryView.options;
  SummaryUiProgress _progress = const SummaryUiProgress(
    stage: SummaryUiStage.loadingHistory,
  );
  SummaryResult? _result;
  SummaryCancellation? _cancellation;
  String? _failure;
  String? _notice;
  bool _copied = false;
  bool _retryAllowed = true;
  int _generation = 0;
  bool _accessClosed = false;

  @override
  void initState() {
    super.initState();
    widget.accessChanges?.addListener(_accessChanged);
  }

  @override
  void didUpdateWidget(ConversationSummarySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessChanges != widget.accessChanges) {
      oldWidget.accessChanges?.removeListener(_accessChanged);
      widget.accessChanges?.addListener(_accessChanged);
    }
    _ensureAccess();
  }

  bool _ensureAccess() {
    if (!mounted || _accessClosed) return false;
    if (widget.isCurrent?.call() ?? true) return true;
    _accessChanged();
    return false;
  }

  void _accessChanged() {
    if (!mounted || _accessClosed || (widget.isCurrent?.call() ?? true)) return;
    _accessClosed = true;
    _generation++;
    _cancellation?.cancel();
    _cancellation = null;
    _result = null;
    _view = _SummaryView.options;
    // A lock/account notification can arrive during a frame. Remove this
    // route after it, without popping a different overlay above the sheet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  int get _maximum => switch (_scope) {
    SummaryScopeKind.messages => 10000,
    SummaryScopeKind.hours => 8760,
    SummaryScopeKind.days => 3650,
    SummaryScopeKind.all => 1,
  };

  int? get _number => int.tryParse(_amount.text);

  String? get _amountError {
    if (_scope == SummaryScopeKind.all) return null;
    final number = _number;
    if (number == null || number < 1 || number > _maximum) {
      return 'Enter a whole number from 1 to $_maximum.';
    }
    return null;
  }

  @override
  void dispose() {
    widget.accessChanges?.removeListener(_accessChanged);
    _generation++;
    _cancellation?.cancel();
    _amount.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _chooseScope(SummaryScopeKind value) {
    if (value == _scope) return;
    setState(() {
      if (_scope != SummaryScopeKind.all) _amounts[_scope] = _amount.text;
      _scope = value;
      if (value != SummaryScopeKind.all) {
        _amount.text = _amounts[value]!;
      }
    });
  }

  void _chooseAmount(int value) => setState(() {
    _amount.text = '$value';
    _amounts[_scope] = '$value';
  });

  void _resetScroll() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _generate() async {
    if (!_ensureAccess() ||
        _view == _SummaryView.running ||
        _amountError != null) {
      return;
    }
    FocusScope.of(context).unfocus();
    final cancellation = SummaryCancellation();
    final generation = ++_generation;
    final request = SummaryRequest(
      scope: _scope,
      amount: _scope == SummaryScopeKind.all ? 1 : _number!,
      detail: _detail,
      language: _language,
    );
    _resetScroll();
    setState(() {
      _cancellation = cancellation;
      _view = _SummaryView.running;
      _progress = const SummaryUiProgress(stage: SummaryUiStage.loadingHistory);
      _failure = null;
      _notice = null;
      _copied = false;
    });
    bool current() =>
        mounted &&
        generation == _generation &&
        !cancellation.isCancelled &&
        _ensureAccess();
    try {
      final result = await widget.summarize(request, (progress) {
        if (current()) setState(() => _progress = progress);
      }, cancellation);
      if (!current()) return;
      _resetScroll();
      setState(() {
        _result = result;
        _view = _SummaryView.result;
        _cancellation = null;
      });
    } catch (error) {
      if (!current()) return;
      _resetScroll();
      setState(() {
        _failure = summaryFailureMessage(error);
        _retryAllowed = !{
          'timeout',
          'paid_request_unknown',
        }.contains(_summaryErrorCode(error));
        _view = _SummaryView.failure;
        _cancellation = null;
      });
    }
  }

  void _stop() {
    _cancellation?.cancel();
    _generation++;
    _resetScroll();
    setState(() {
      _cancellation = null;
      _view = _SummaryView.options;
      _notice =
          'Summary stopped. A request already started by the service may still have a cost.';
    });
  }

  void _edit() {
    _resetScroll();
    setState(() {
      _view = _SummaryView.options;
      _notice = null;
    });
  }

  Future<void> _copy() async {
    if (!_ensureAccess()) return;
    final result = _result;
    if (result == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: result.text));
      if (_ensureAccess()) setState(() => _copied = true);
    } catch (_) {
      if (!mounted || !_ensureAccess()) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Could not copy. Select the text to copy it.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final available = MediaQuery.sizeOf(context).height - keyboard;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: available * .78),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.chatName,
                    style: tokens.typography.footnoteMuted,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                NotionIconButton(
                  key: const ValueKey('summary-close'),
                  icon: Icons.close,
                  label: 'Close summary',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                controller: _scroll,
                child: NotionFadeThrough(
                  alignment: Alignment.topCenter,
                  child: switch (_view) {
                    _SummaryView.options => _options(context),
                    _SummaryView.running => _working(context),
                    _SummaryView.result => _output(context, _result!),
                    _SummaryView.failure => _error(context),
                  },
                ),
              ),
            ),
            const SizedBox(height: NotionSpace.md),
            _actions(),
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: NotionSpace.lg, bottom: NotionSpace.xs),
    child: Text(text, style: context.notion.typography.sectionLabel),
  );

  Widget _options(BuildContext context) {
    final tokens = context.notion;
    final presets = switch (_scope) {
      SummaryScopeKind.messages => [50, 100, 250, 500],
      SummaryScopeKind.hours => [1, 6, 12, 24],
      SummaryScopeKind.days => [1, 3, 7, 30],
      SummaryScopeKind.all => <int>[],
    };
    return Column(
      key: const ValueKey('summary-options'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: NotionSpace.sm),
            child: Semantics(
              liveRegion: true,
              child: Text(_notice!, style: tokens.typography.footnoteMuted),
            ),
          ),
        Text('What did you miss?', style: tokens.typography.heading),
        Text(
          'Choose the part of the conversation you want to catch up on.',
          style: tokens.typography.calloutMuted,
        ),
        _label(context, 'Range'),
        Wrap(
          spacing: NotionSpace.xs,
          runSpacing: NotionSpace.xs,
          children: [
            for (final scope in SummaryScopeKind.values)
              NotionGlassPill(
                key: ValueKey('summary-scope-${scope.name}'),
                label: _scopeLabel(scope),
                selected: _scope == scope,
                onPressed: () => _chooseScope(scope),
              ),
          ],
        ),
        const SizedBox(height: NotionSpace.sm),
        NotionFadeThrough(
          alignment: Alignment.topCenter,
          child: _scope == SummaryScopeKind.all
              ? Text(
                  'All history imported into this account. Messages from before the bridge import may be unavailable. An incomplete history download must be retried or narrowed.',
                  key: const ValueKey('summary-entire-history'),
                  style: tokens.typography.footnoteMuted,
                )
              : Column(
                  key: ValueKey('summary-range-${_scope.name}'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: NotionSpace.xs,
                      runSpacing: NotionSpace.xs,
                      children: [
                        for (final value in presets)
                          NotionGlassPill(
                            key: ValueKey('summary-amount-$value'),
                            label: '$value',
                            tooltip:
                                'Last $value ${_scopeLabel(_scope).toLowerCase()}',
                            selected: _number == value,
                            onPressed: () => _chooseAmount(value),
                          ),
                      ],
                    ),
                    const SizedBox(height: NotionSpace.sm),
                    NotionTextField(
                      key: const ValueKey('summary-custom-amount'),
                      label: switch (_scope) {
                        SummaryScopeKind.messages => 'Last messages',
                        SummaryScopeKind.hours => 'Last hours',
                        _ => 'Last days',
                      },
                      controller: _amount,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      error: _amountError,
                      onChanged: (value) => setState(() {
                        _amounts[_scope] = value;
                      }),
                      onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    ),
                  ],
                ),
        ),
        _label(context, 'Detail'),
        Wrap(
          spacing: NotionSpace.xs,
          runSpacing: NotionSpace.xs,
          children: [
            for (final detail in SummaryDetail.values)
              NotionGlassPill(
                key: ValueKey('summary-detail-${detail.name}'),
                label: _detailLabel(detail),
                selected: detail == _detail,
                onPressed: () => setState(() => _detail = detail),
              ),
          ],
        ),
        const SizedBox(height: NotionSpace.xs),
        NotionFadeThrough(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            _detailDescription(_detail),
            key: ValueKey(_detail),
            style: tokens.typography.footnoteMuted,
          ),
        ),
        NotionPickerRow<String>(
          key: const ValueKey('summary-language'),
          label: 'Summary language',
          value: _language,
          options: const [
            NotionChoice('pl', 'Polish'),
            NotionChoice('en', 'English'),
          ],
          onChanged: (language) {
            if (_ensureAccess()) setState(() => _language = language);
          },
        ),
        const SizedBox(height: NotionSpace.sm),
        Text(
          'Gemini 3.1 Flash Lite · OpenRouter',
          style: tokens.typography.footnote.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: NotionSpace.xxs),
        Text(
          'Message text and available transcripts are sent to OpenRouter. Deleted or unreadable messages are omitted. Media include their type and caption; unseen contents are not read. Omissions are reported in the result. Longer ranges cost more. The summary is never posted to the group.',
          key: const ValueKey('summary-provider-note'),
          style: tokens.typography.footnoteMuted,
        ),
      ],
    );
  }

  Widget _working(BuildContext context) {
    final tokens = context.notion;
    final stage = _progress.stage;
    final heading = switch (stage) {
      SummaryUiStage.loadingHistory => 'Loading conversation history',
      SummaryUiStage.syncing => 'Sending your summary request',
      SummaryUiStage.waitingWorker => 'Waiting for the summary service',
      SummaryUiStage.summarizing => 'Writing your summary',
    };
    return Column(
      key: const ValueKey('summary-working'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: NotionSpace.xl),
        Semantics(
          liveRegion: true,
          child: NotionFadeThrough(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              heading,
              key: ValueKey(stage),
              style: tokens.typography.heading,
            ),
          ),
        ),
        const SizedBox(height: NotionSpace.xs),
        if (_progress.messageCount > 0)
          NotionAnimatedCount(
            count: _progress.messageCount,
            style: tokens.typography.footnoteMuted,
            format: (count) => '$count messages collected',
          )
        else
          Text(
            'Fetching the range you selected. You can stop at any time.',
            style: tokens.typography.footnoteMuted,
          ),
        const SizedBox(height: NotionSpace.xl),
        const ExcludeSemantics(child: NotionShimmerLines(lines: 4)),
        const SizedBox(height: NotionSpace.xl),
        Text(
          stage == SummaryUiStage.waitingWorker
              ? 'Keep this window open. No messages are sent to the group.'
              : 'Large conversations can take a little longer.',
          style: tokens.typography.footnoteMuted,
        ),
        const SizedBox(height: NotionSpace.xl),
      ],
    );
  }

  Widget _output(BuildContext context, SummaryResult result) {
    final tokens = context.notion;
    return Column(
      key: const ValueKey('summary-result'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your summary', style: tokens.typography.heading),
        const SizedBox(height: NotionSpace.xxs),
        Text(
          '${result.messageCount} messages · ${_dateRange(context, result)}',
          style: tokens.typography.footnoteMuted,
        ),
        if (!result.complete || result.coverageNote != null) ...[
          const SizedBox(height: NotionSpace.sm),
          NotionCallout(
            icon: result.complete ? Icons.info_outline : Icons.history_outlined,
            title: result.complete
                ? 'About this range'
                : 'Partial conversation',
            message:
                result.coverageNote ??
                'Some messages were unavailable. This summary only covers the readable history shown above.',
            tone: result.complete
                ? NotionCalloutTone.neutral
                : NotionCalloutTone.warning,
          ),
        ],
        const SizedBox(height: NotionSpace.lg),
        SummaryReadableText(text: result.text),
        const SizedBox(height: NotionSpace.lg),
        Text(
          'AI summaries can miss context. Check important decisions against the conversation.',
          style: tokens.typography.captionMuted,
        ),
        if (result.estimatedCostUsd case final cost?) ...[
          const SizedBox(height: NotionSpace.xxs),
          Text(
            'Estimated cost: ${cost > 0 && cost < .01 ? '< \$0.01' : '\$${cost.toStringAsFixed(2)}'}',
            style: tokens.typography.captionMuted,
          ),
        ],
      ],
    );
  }

  Widget _error(BuildContext context) => Column(
    key: const ValueKey('summary-failure'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: NotionSpace.lg),
      NotionCallout(
        icon: Icons.error_outline,
        title: 'Could not create the summary',
        message: _failure,
        tone: NotionCalloutTone.warning,
      ),
      const SizedBox(height: NotionSpace.lg),
    ],
  );

  Widget _actions() => switch (_view) {
    _SummaryView.options => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Selected text goes to OpenRouter.',
          style: context.notion.typography.captionMuted,
        ),
        const SizedBox(height: NotionSpace.xs),
        NotionButton.primary(
          key: const ValueKey('summary-generate'),
          label: 'Summarize',
          expand: true,
          onPressed: _amountError == null ? _generate : null,
        ),
      ],
    ),
    _SummaryView.running => NotionButton(
      key: const ValueKey('summary-stop'),
      label: 'Stop',
      icon: Icons.stop_circle_outlined,
      expand: true,
      onPressed: _stop,
    ),
    _SummaryView.result => Wrap(
      alignment: WrapAlignment.end,
      spacing: NotionSpace.xs,
      runSpacing: NotionSpace.xs,
      children: [
        NotionButton.ghost(
          key: const ValueKey('summary-edit'),
          label: 'Change range',
          onPressed: _edit,
        ),
        NotionButton.primary(
          key: const ValueKey('summary-copy'),
          label: _copied ? 'Copied' : 'Copy summary',
          icon: _copied ? Icons.check : Icons.copy_outlined,
          onPressed: _copy,
        ),
      ],
    ),
    _SummaryView.failure => Wrap(
      alignment: WrapAlignment.end,
      spacing: NotionSpace.xs,
      runSpacing: NotionSpace.xs,
      children: [
        NotionButton.ghost(
          key: const ValueKey('summary-edit'),
          label: 'Change range',
          onPressed: _edit,
        ),
        if (_retryAllowed)
          NotionButton.primary(
            key: const ValueKey('summary-retry'),
            label: 'Try again',
            icon: Icons.refresh,
            onPressed: _generate,
          ),
      ],
    ),
  };
}

String _scopeLabel(SummaryScopeKind scope) => switch (scope) {
  SummaryScopeKind.messages => 'Messages',
  SummaryScopeKind.hours => 'Hours',
  SummaryScopeKind.days => 'Days',
  SummaryScopeKind.all => 'Whole conversation',
};

String _detailLabel(SummaryDetail detail) => switch (detail) {
  SummaryDetail.brief => 'Brief',
  SummaryDetail.standard => 'Standard',
  SummaryDetail.detailed => 'Detailed',
};

String _detailDescription(SummaryDetail detail) => switch (detail) {
  SummaryDetail.brief => 'Highlights and key decisions.',
  SummaryDetail.standard =>
    'Main topics, decisions, next steps and open questions.',
  SummaryDetail.detailed =>
    'Topic-by-topic context, decisions, differing views and owners.',
};

String _dateRange(BuildContext context, SummaryResult result) {
  final localizations = MaterialLocalizations.of(context);
  final start = result.startedAt.toLocal();
  final end = result.endedAt.toLocal();
  final first = localizations.formatCompactDate(start);
  final last = localizations.formatCompactDate(end);
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  String time(DateTime date) => localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(date),
    alwaysUse24HourFormat: use24h,
  );
  if (start == end) return '$first, ${time(start)}';
  if (DateUtils.isSameDay(start, end)) {
    return '$first, ${time(start)} – ${time(end)}';
  }
  return '$first ${time(start)} – $last ${time(end)}';
}

/// Intentionally renders only the prompt's small Markdown vocabulary. The
/// model cannot introduce links, HTML, embedded media or interactive actions.
class SummaryReadableText extends StatelessWidget {
  final String text;

  const SummaryReadableText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    for (var index = 0; index < lines.length; index++) {
      var line = lines[index];
      final heading = RegExp(r'^#{1,4}\s+').firstMatch(line);
      final boldHeading = RegExp(r'^\*\*(.+)\*\*$').firstMatch(line);
      final isHeading = heading != null || boldHeading != null;
      if (heading != null) line = line.substring(heading.end);
      if (boldHeading != null) line = boldHeading.group(1)!;
      line = line.replaceFirst(RegExp(r'^\s*[-*]\s+'), '• ');
      final style = isHeading
          ? tokens.typography.headline
          : tokens.typography.callout.copyWith(height: 1.6);
      final pieces = <InlineSpan>[];
      var cursor = 0;
      for (final match in RegExp(r'\*\*(.+?)\*\*').allMatches(line)) {
        if (match.start > cursor) {
          pieces.add(TextSpan(text: line.substring(cursor, match.start)));
        }
        pieces.add(
          TextSpan(
            text: match.group(1),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
        cursor = match.end;
      }
      pieces.add(TextSpan(text: line.substring(cursor)));
      if (index != lines.length - 1) pieces.add(const TextSpan(text: '\n'));
      spans.add(TextSpan(style: style, children: pieces));
    }
    return SelectableText.rich(
      TextSpan(children: spans),
      key: const ValueKey('summary-readable-text'),
      style: tokens.typography.callout,
    );
  }
}

/// Safe user-facing failures; exception strings may contain provider data.
String summaryFailureMessage(Object error) {
  final code = _summaryErrorCode(error);
  return switch (code) {
    'history_incomplete' || 'incomplete_history' || 'partial_history' =>
      'The complete range could not be read. Choose fewer messages or a shorter time range and try again.',
    'source_timeout' =>
      'Loading the conversation took too long. Choose a shorter range and try again.',
    'input_too_large' || 'source_too_large' || 'request_too_large' =>
      'This range is too large for one summary. Choose fewer messages or a shorter time range.',
    'no_messages' || 'empty_source' =>
      'There are no readable messages in this range. Choose a different range.',
    'disappearing_messages' || 'disappearing_room' =>
      'Disappearing conversations are not sent for summarization.',
    'worker_unavailable' || 'worker_offline' || 'worker_timeout' =>
      'The summary service is unavailable. Check the connection and try again later.',
    'timeout' || 'paid_request_unknown' =>
      'The service has not confirmed a result. The request may still be running and may have a cost. Check the connection before starting another summary.',
    'locked' =>
      'Unlock the app, then open the conversation again to create a summary.',
    'account_unavailable' =>
      'This conversation is no longer available on the current account. Open it again before creating a summary.',
    'private_sync_required' || 'storage_unavailable' =>
      'Connect private sync in Advanced settings to use conversation summaries.',
    'not_configured' || 'provider_unavailable' || 'missing_api_key' =>
      'Summarization is not configured on the service yet. Try again after the service has been updated.',
    'rate_limited' => 'The service is busy. Wait a moment, then try again.',
    'budget_exceeded' || 'cost_limit' =>
      'This summary exceeds the service’s cost limit. Choose a shorter range.',
    'auth_failed' || 'payment_required' =>
      'The summary service cannot access OpenRouter. Its provider access or balance needs attention before retrying.',
    'invalid_response' || 'output_incomplete' || 'model_mismatch' =>
      'The service did not return a complete summary. Try again or choose a shorter range.',
    'rejected' =>
      'The provider could not summarize this selection. Change the range and try again.',
    'invalid_request' ||
    'invalid_source' ||
    'invalid_summary_request' ||
    'invalid_summary_source' =>
      'This selection could not be prepared. Change the range and try again.',
    'cancelled' => 'The summary was stopped. You can try again.',
    _ =>
      'The summary could not be completed. Try again or choose a shorter range.',
  };
}

String _summaryErrorCode(Object error) {
  if (error is! SummaryException) return '';
  final code = error.code;
  return code.startsWith('summary_') ? code.substring('summary_'.length) : code;
}
