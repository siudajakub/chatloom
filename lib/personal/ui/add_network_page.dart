// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/network_login/network_login_api.dart';
import 'package:chatloom/personal/network_login/network_login_catalog.dart';
import 'package:chatloom/personal/network_login/network_login_session.dart';
import 'package:chatloom/personal/ui/networks_page.dart' show NetworkLogo;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

// Settings → Networks → Add network (wave 8).
//
// Pick a network, pick how to sign in, then follow the bridge's steps: a QR
// code or pairing code to confirm on the phone, a form (phone number, code,
// password, choice), or cookies pasted from a signed-in browser. Everything
// goes through the bridgev2 provisioning login API
// (`network_login_api.dart`); the bridge chat ("send login to the bot")
// stays one tap away under each step as the fallback.
//
// Privacy: codes, typed values and cookies are held only by the widgets of
// the step that shows them and are never logged. Secret fields are cleared
// right after they are sent.

/// Opens a DM with a bridge bot and returns its room id (test seam).
typedef StartBridgeChat = Future<String> Function(String bot);

class AddNetworkPage extends StatefulWidget {
  const AddNetworkPage({
    super.key,
    required this.client,
    this.network,
    this.backend,
    this.loadBridges,
    this.onComplete,
    this.startBridgeChat,
    this.onOpenRoom,
    this.retryDelay = const Duration(seconds: 2),
  });

  final Client client;

  /// Opens this network's sign-in directly (from a network's "Sign in").
  final String? network;

  /// Test seams.
  final NetworkLoginBackend? backend;
  final Future<List<AddableBridge>> Function()? loadBridges;
  final NetworkLoginCompleted? onComplete;
  final StartBridgeChat? startBridgeChat;
  final ValueChanged<String>? onOpenRoom;
  final Duration retryDelay;

  @override
  State<AddNetworkPage> createState() => _AddNetworkPageState();
}

class _AddNetworkPageState extends State<AddNetworkPage> {
  late final NetworkLoginBackend _backend =
      widget.backend ?? NetworkLoginBackend.of(widget.client);
  List<AddableBridge>? _bridges;
  AddableBridge? _selected;
  NetworkLoginSession? _session;
  bool _openingBot = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // Disposing cancels a sign-in still open on the bridge.
    _session?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final load =
        widget.loadBridges ??
        () => loadAddableBridges(
          backend: _backend,
          discovered: discoverBridges(widget.client.rooms),
        );
    List<AddableBridge> bridges;
    try {
      bridges = await load();
    } catch (_) {
      bridges = const [];
    }
    if (!mounted) return;
    setState(() => _bridges = bridges);
    final wanted = widget.network;
    if (wanted == null) return;
    final match = bridges
        .where(
          (entry) =>
              entry.network == wanted &&
              entry.status == AddableBridgeStatus.ready,
        )
        .firstOrNull;
    if (match != null) _select(match);
  }

  void _select(AddableBridge entry) {
    if (entry.status != AddableBridgeStatus.ready) {
      unawaited(_openBotChat(entry.bridge.botId));
      return;
    }
    final api = _backend.api;
    if (api == null) return;
    _session?.dispose();
    final session = NetworkLoginSession(
      api: api,
      bridge: entry.bridge,
      retryDelay: widget.retryDelay,
      onComplete:
          widget.onComplete ??
          (bridge, loginId) =>
              refreshAfterLogin(widget.client, bridge, entry.network, loginId),
    )..addListener(_sessionChanged);
    setState(() {
      _selected = entry;
      _session = session;
    });
    unawaited(session.loadFlows(known: entry.flows));
  }

  void _sessionChanged() {
    if (!mounted) return;
    final session = _session;
    if (session != null && session.phase == NetworkLoginPhase.cancelled) {
      // Not inside the session's own notification: leaving disposes it.
      scheduleMicrotask(() {
        if (mounted && identical(_session, session)) _leaveNetwork();
      });
      return;
    }
    setState(() {});
  }

  /// Back to the list (or out, when opened for one network).
  void _leaveNetwork() {
    final session = _session;
    _session = null;
    session
      ?..removeListener(_sessionChanged)
      ..dispose();
    setState(() => _selected = null);
    if (widget.network != null) {
      // After the rebuild lets the route pop (PopScope reads the session).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  /// Back from a running sign-in (header back, system back).
  Future<void> _back() async {
    final session = _session;
    if (session == null) {
      // A stale pop callback: the page pops on its own once rebuilt.
      return;
    }
    switch (session.phase) {
      case NetworkLoginPhase.complete:
        await Navigator.of(context).maybePop();
      case NetworkLoginPhase.step ||
              NetworkLoginPhase.starting ||
              NetworkLoginPhase.failed ||
              NetworkLoginPhase.unsupported
          when (session.step?.canCancel ?? false) || session.flows.length > 1:
        await session.back();
      default:
        await session.cancel();
    }
  }

  Future<void> _openBotChat(String bot) async {
    if (_openingBot) return;
    setState(() => _openingBot = true);
    try {
      final start =
          widget.startBridgeChat ??
          (String bot) =>
              widget.client.startDirectChat(bot, enableEncryption: false);
      final id = await start(bot);
      if (!mounted) return;
      final open = widget.onOpenRoom;
      if (open != null) {
        open(id);
      } else {
        unawaited(context.push('/rooms/$id'));
      }
    } catch (error, stack) {
      if (!mounted) return;
      await ErrorReporter.action(
        context,
        message: 'Open the bridge chat',
        onRetry: () => _openBotChat(bot),
      ).onErrorCallback(error, stack);
    } finally {
      if (mounted) setState(() => _openingBot = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final session = _session;
    return PopScope(
      canPop: session == null || session.phase == NetworkLoginPhase.complete,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: NotionScaffold(
        title: selected == null ? 'Add network' : selected.label,
        onBack: () => session == null
            ? unawaited(Navigator.of(context).maybePop())
            : unawaited(_back()),
        children: [
          NotionFadeThrough(
            child: KeyedSubtree(
              key: ValueKey((
                selected?.bridge.botId,
                session?.phase,
                session?.step?.stepId,
              )),
              child: selected == null || session == null
                  ? _pickNetwork(context)
                  : _sessionView(context, selected, session),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Pick a network
  // -------------------------------------------------------------------------

  Widget _pickNetwork(BuildContext context) {
    final bridges = _bridges;
    final typography = context.notion.typography;
    if (bridges == null) {
      return Padding(
        padding: const EdgeInsets.only(top: NotionSpace.xxl),
        child: Column(
          children: [
            const NotionDelayedSpinner(semanticsLabel: 'Looking for bridges'),
            const SizedBox(height: NotionSpace.sm),
            Text('Looking for your bridges…', style: typography.calloutMuted),
          ],
        ),
      );
    }
    final disabled = _backend.disabledReason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: NotionSpace.xs,
            bottom: NotionSpace.md,
          ),
          child: Text(
            'Choose a network to connect. You sign in to it here, and its '
            'chats appear in ChatLoom.',
            style: typography.calloutMuted,
          ),
        ),
        if (disabled != null)
          Padding(
            padding: const EdgeInsets.only(bottom: NotionSpace.md),
            child: NotionCallout(
              icon: Icons.link_off,
              title: 'Signing in from the app isn’t available',
              message:
                  '$disabled You can still sign in by sending “login” in a '
                  'bridge chat.',
            ),
          ),
        if (bridges.isEmpty)
          const NotionEmptyState(
            icon: Icons.hub_outlined,
            title: 'No bridges found',
            message:
                'ChatLoom found no bridge for this account. Set one up on '
                'your server, then come back.',
          )
        else
          for (final entry in bridges)
            NotionListRow(
              key: ValueKey('add-network-${entry.bridge.botId}'),
              leading: NetworkLogo(network: entry.network),
              title: entry.label,
              subtitle: _bridgeSubtitle(entry),
              trailing: const Icon(
                Icons.chevron_right,
                size: NotionSize.iconMd,
              ),
              onTap: _openingBot ? null : () => _select(entry),
            ),
      ],
    );
  }

  static String _bridgeSubtitle(AddableBridge entry) {
    if (entry.status == AddableBridgeStatus.unreachable) {
      return 'Sign in through the bridge chat';
    }
    final accounts = entry.accounts;
    if (accounts.isEmpty) return 'Not connected';
    return '${accounts.join(', ')} · Add another account';
  }

  // -------------------------------------------------------------------------
  // A running sign-in
  // -------------------------------------------------------------------------

  Widget _sessionView(
    BuildContext context,
    AddableBridge entry,
    NetworkLoginSession session,
  ) {
    final label = entry.label;
    final body = switch (session.phase) {
      NetworkLoginPhase.loadingFlows ||
      NetworkLoginPhase.starting ||
      NetworkLoginPhase.cancelled => _Waiting(
        text: session.phase == NetworkLoginPhase.starting
            ? 'Connecting to $label…'
            : 'Loading sign-in options…',
      ),
      NetworkLoginPhase.flows => _flows(context, label, session),
      NetworkLoginPhase.step => _step(context, label, session),
      NetworkLoginPhase.complete => _done(context, label, session),
      NetworkLoginPhase.failed => _failed(context, label, session),
      NetworkLoginPhase.unsupported => _unsupported(context, label),
    };
    final showFallback =
        session.phase != NetworkLoginPhase.complete &&
        session.phase != NetworkLoginPhase.unsupported &&
        session.phase != NetworkLoginPhase.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: NotionSpace.sm,
            bottom: NotionSpace.md,
          ),
          child: Center(
            child: NetworkLogo(
              network: entry.network,
              size: NotionSize.avatarLg,
            ),
          ),
        ),
        // Each phase and step fades through to the next while the page
        // height glides, instead of cutting (loading → options → code).
        NotionAnimatedSize(
          alignment: Alignment.topCenter,
          child: NotionFadeThrough(
            alignment: AlignmentDirectional.topCenter,
            child: KeyedSubtree(
              key: ValueKey((session.phase, session.step?.stepId)),
              child: body,
            ),
          ),
        ),
        NotionSizeReveal(
          visible: showFallback,
          child: _fallback(context, entry),
        ),
      ],
    );
  }

  Widget _fallback(BuildContext context, AddableBridge entry) => Padding(
    padding: const EdgeInsets.only(top: NotionSpace.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSectionHeader(title: 'Advanced'),
        NotionListRow(
          key: const ValueKey('add-network-bot-chat'),
          leading: const Icon(Icons.terminal_outlined),
          title: 'Open bridge chat',
          subtitle: 'Sign in by sending “login” to the bridge bot instead',
          trailing: _openingBot
              ? const NotionDelayedSpinner(delay: Duration.zero)
              : null,
          onTap: _openingBot ? null : () => _openBotChat(entry.bridge.botId),
        ),
      ],
    ),
  );

  Widget _flows(
    BuildContext context,
    String label,
    NetworkLoginSession session,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: NotionSpace.sm),
        child: Text(
          'How do you want to sign in to $label?',
          textAlign: TextAlign.center,
          style: context.notion.typography.callout,
        ),
      ),
      for (final flow in session.flows)
        NotionListRow(
          key: ValueKey('add-network-flow-${flow.id}'),
          title: flow.name,
          subtitle: flow.description.isEmpty ? null : flow.description,
          trailing: const Icon(Icons.chevron_right, size: NotionSize.iconMd),
          onTap: () => unawaited(session.start(flow)),
        ),
    ],
  );

  Widget _step(
    BuildContext context,
    String label,
    NetworkLoginSession session,
  ) {
    final step = session.step!;
    final typography = context.notion.typography;
    final content = switch (step.type) {
      NetworkLoginStepType.displayAndWait => _DisplayStep(
        step: step,
        network: label,
      ),
      NetworkLoginStepType.userInput => _InputForm(
        key: ValueKey(('input', step.stepId, step.txnId)),
        step: step,
        busy: session.busy,
        onSubmit: session.submit,
      ),
      NetworkLoginStepType.cookies => _CookieForm(
        key: ValueKey(('cookies', step.stepId, step.txnId)),
        step: step,
        network: label,
        busy: session.busy,
        onSubmit: session.submit,
      ),
      _ => const SizedBox.shrink(),
    };
    final canGoBack = step.canCancel || session.flows.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (step.instructions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: NotionSpace.md),
            child: Text(
              step.instructions,
              textAlign: TextAlign.center,
              style: typography.callout,
            ),
          ),
        content,
        const SizedBox(height: NotionSpace.md),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: NotionSpace.xs,
          runSpacing: NotionSpace.xs,
          children: [
            if (canGoBack)
              NotionButton.ghost(
                key: const ValueKey('add-network-back'),
                label: step.canCancel ? 'Back' : 'Use another way',
                onPressed: () => unawaited(session.back()),
              ),
            NotionButton.ghost(
              key: const ValueKey('add-network-cancel'),
              label: 'Cancel',
              onPressed: () => unawaited(_cancel(session)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _cancel(NetworkLoginSession session) => session.cancel();

  Widget _done(
    BuildContext context,
    String label,
    NetworkLoginSession session,
  ) {
    final name = session.accountName;
    return NotionEmptyState(
      icon: Icons.check_circle_outline,
      title: '$label is connected',
      message: name == null
          ? 'Your chats will appear in a few minutes.'
          : 'Signed in as $name. Your chats will appear in a few minutes.',
      action: NotionButton.primary(
        key: const ValueKey('add-network-done'),
        label: 'Done',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }

  Widget _failed(
    BuildContext context,
    String label,
    NetworkLoginSession session,
  ) {
    final error =
        session.error ??
        const NetworkLoginException(NetworkLoginErrorKind.unreachable);
    final bot = _selected?.bridge.botId;
    return NotionCallout(
      key: const ValueKey('add-network-failed'),
      icon: Icons.error_outline,
      tone: NotionCalloutTone.danger,
      title: 'Couldn’t sign in to $label',
      message: error.describe(label),
      actionLabel:
          error.kind == NetworkLoginErrorKind.unsupported ||
              error.kind == NetworkLoginErrorKind.forbidden
          ? null
          : 'Try again',
      onAction: () => unawaited(session.retry()),
      secondaryLabel: bot == null ? null : 'Open bridge chat',
      onSecondary: bot == null ? null : () => _openBotChat(bot),
    );
  }

  Widget _unsupported(BuildContext context, String label) {
    final bot = _selected?.bridge.botId;
    return NotionCallout(
      key: const ValueKey('add-network-unsupported'),
      icon: Icons.terminal_outlined,
      tone: NotionCalloutTone.warning,
      title: 'Finish in the bridge chat',
      message:
          '$label asked for a sign-in step ChatLoom can’t show yet. Open the '
          'bridge chat and send “login” to sign in there.',
      actionLabel: bot == null ? null : 'Open bridge chat',
      actionBusy: _openingBot,
      onAction: bot == null ? null : () => _openBotChat(bot),
    );
  }
}

/// A quiet spinner line.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: NotionSpace.lg),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const NotionDelayedSpinner(),
        const SizedBox(width: NotionSpace.xs),
        Flexible(
          child: Text(text, style: context.notion.typography.calloutMuted),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// display_and_wait: QR, pairing code, emoji
// ---------------------------------------------------------------------------

class _DisplayStep extends StatelessWidget {
  const _DisplayStep({required this.step, required this.network});

  final NetworkLoginStep step;
  final String network;

  @override
  Widget build(BuildContext context) {
    final data = step.displayData;
    final shown = switch (step.display) {
      NetworkLoginDisplay.qr when data.isNotEmpty => _QrCode(
        key: ValueKey(step.txnId),
        data: data,
        network: network,
      ),
      NetworkLoginDisplay.code when data.isNotEmpty => _PairingCode(
        key: ValueKey(step.txnId),
        code: data,
      ),
      NetworkLoginDisplay.emoji when data.isNotEmpty => Semantics(
        label: 'Emoji to compare: $data',
        excludeSemantics: true,
        child: Text(
          data,
          textAlign: TextAlign.center,
          style: context.notion.typography.title,
        ),
      ),
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shown != null) Center(child: NotionFadeThrough(child: shown)),
        _Waiting(text: 'Waiting for $network…'),
      ],
    );
  }
}

/// A QR code on a light tile so phone cameras read it in either theme.
class _QrCode extends StatelessWidget {
  const _QrCode({super.key, required this.data, required this.network});

  final String data;
  final String network;

  static const _side = 240.0;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'QR code. Scan it with $network on your phone.',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        // Fixed light tile in both themes: QR readers need dark on light.
        color: NotionMediaColors.onScrim,
        borderRadius: NotionRadius.mdAll,
      ),
      child: Padding(
        padding: const EdgeInsets.all(NotionSpace.md),
        child: SizedBox.square(
          dimension: _side,
          child: PrettyQrView.data(
            data: data,
            decoration: const PrettyQrDecoration(
              shape: PrettyQrSmoothSymbol(color: NotionMediaColors.viewer),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A pairing code to type on the phone, with a copy button.
class _PairingCode extends StatefulWidget {
  const _PairingCode({super.key, required this.code});
  final String code;

  @override
  State<_PairingCode> createState() => _PairingCodeState();
}

class _PairingCodeState extends State<_PairingCode> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SelectableText(
        widget.code,
        textAlign: TextAlign.center,
        style: context.notion.typography.title.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: NotionSpace.xxs,
        ),
      ),
      const SizedBox(height: NotionSpace.xs),
      NotionButton(
        key: const ValueKey('add-network-copy-code'),
        label: _copied ? 'Copied' : 'Copy code',
        icon: _copied ? Icons.check : Icons.copy_outlined,
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: widget.code));
          if (mounted) setState(() => _copied = true);
        },
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// user_input
// ---------------------------------------------------------------------------

class _InputForm extends StatefulWidget {
  const _InputForm({
    super.key,
    required this.step,
    required this.busy,
    required this.onSubmit,
  });

  final NetworkLoginStep step;
  final bool busy;
  final Future<void> Function(Map<String, String> values) onSubmit;

  @override
  State<_InputForm> createState() => _InputFormState();
}

class _InputFormState extends State<_InputForm> {
  late final Map<String, TextEditingController> _controllers = {
    for (final field in widget.step.fields)
      if (field.type != NetworkLoginFieldType.select)
        field.id: TextEditingController(text: field.defaultValue),
  };
  late final Map<String, String> _choices = {
    for (final field in widget.step.fields)
      if (field.type == NetworkLoginFieldType.select)
        field.id: field.options.contains(field.defaultValue)
            ? field.defaultValue
            : '',
  };
  final _errors = <String, String>{};
  final _revealed = <String>{};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.busy) return;
    final values = <String, String>{};
    final errors = <String, String>{};
    for (final field in widget.step.fields) {
      final raw = field.type == NetworkLoginFieldType.select
          ? _choices[field.id] ?? ''
          : _controllers[field.id]!.text;
      final result = field.validate(raw);
      final value = result.value;
      if (value == null) {
        errors[field.id] = result.error ?? 'Check this field.';
      } else if (value.isNotEmpty || !field.optional) {
        values[field.id] = value;
      }
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) return;
    // Secrets leave the screen as soon as they are sent.
    for (final field in widget.step.fields) {
      if (field.type.secret ||
          field.type == NetworkLoginFieldType.twoFactorCode) {
        _controllers[field.id]?.clear();
      }
    }
    await widget.onSubmit(values);
  }

  static TextInputType _keyboard(NetworkLoginFieldType type) => switch (type) {
    NetworkLoginFieldType.phoneNumber => TextInputType.phone,
    NetworkLoginFieldType.email => TextInputType.emailAddress,
    NetworkLoginFieldType.url ||
    NetworkLoginFieldType.domain => TextInputType.url,
    NetworkLoginFieldType.twoFactorCode => TextInputType.number,
    NetworkLoginFieldType.password ||
    NetworkLoginFieldType.token => TextInputType.visiblePassword,
    _ => TextInputType.text,
  };

  static Iterable<String>? _autofill(
    NetworkLoginFieldType type,
  ) => switch (type) {
    NetworkLoginFieldType.phoneNumber => const [AutofillHints.telephoneNumber],
    NetworkLoginFieldType.email => const [AutofillHints.email],
    NetworkLoginFieldType.username => const [AutofillHints.username],
    NetworkLoginFieldType.password => const [AutofillHints.password],
    NetworkLoginFieldType.twoFactorCode => const [AutofillHints.oneTimeCode],
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final fields = widget.step.fields;
    final last = fields.lastWhere(
      (field) => field.type != NetworkLoginFieldType.select,
      orElse: () => fields.isEmpty
          ? const NetworkLoginField(id: '', type: NetworkLoginFieldType.text)
          : fields.last,
    );
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final attachment in widget.step.attachments)
            if (attachment.isImage)
              Padding(
                padding: const EdgeInsets.only(bottom: NotionSpace.md),
                child: Center(
                  child: ClipRRect(
                    borderRadius: NotionRadius.smAll,
                    child: Image.memory(
                      attachment.bytes,
                      height: NotionSize.avatarLg * 2,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
          for (final (index, field) in fields.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: NotionSpace.sm),
              child: field.type == NetworkLoginFieldType.select
                  ? _select(context, field)
                  : NotionTextField(
                      key: ValueKey('add-network-field-${field.id}'),
                      label: field.label,
                      helper: field.description.isEmpty
                          ? null
                          : field.description,
                      error: _errors[field.id],
                      controller: _controllers[field.id],
                      enabled: !widget.busy,
                      autofocus: index == 0,
                      autocorrect: false,
                      obscureText:
                          field.type.secret && !_revealed.contains(field.id),
                      keyboardType: _keyboard(field.type),
                      autofillHints: _autofill(field.type),
                      maxLength: field.maxLength > 0 ? field.maxLength : null,
                      textInputAction: identical(field, last)
                          ? TextInputAction.done
                          : TextInputAction.next,
                      onSubmitted: identical(field, last)
                          ? (_) => unawaited(_submit())
                          : null,
                      suffix: field.type.secret
                          ? NotionIconButton(
                              icon: _revealed.contains(field.id)
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              label: _revealed.contains(field.id)
                                  ? 'Hide'
                                  : 'Show',
                              onPressed: () => setState(() {
                                if (!_revealed.remove(field.id)) {
                                  _revealed.add(field.id);
                                }
                              }),
                            )
                          : null,
                    ),
            ),
          Center(
            child: NotionButton.primary(
              key: const ValueKey('add-network-submit'),
              label: 'Continue',
              busy: widget.busy,
              onPressed: widget.busy ? null : () => unawaited(_submit()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _select(BuildContext context, NetworkLoginField field) {
    final error = _errors[field.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionSectionHeader(title: field.label),
        if (field.description.isNotEmpty)
          Text(
            field.description,
            style: context.notion.typography.captionMuted,
          ),
        for (final option in field.options)
          NotionChoiceRow(
            key: ValueKey('add-network-option-${field.id}-$option'),
            title: option,
            selected: _choices[field.id] == option,
            onTap: widget.busy
                ? null
                : () => setState(() => _choices[field.id] = option),
          ),
        NotionSizeReveal(
          visible: error != null,
          child: Text(
            error ?? '',
            style: context.notion.typography.caption.copyWith(
              color: context.notion.colors.danger,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// cookies: paste from a signed-in browser
// ---------------------------------------------------------------------------

class _CookieForm extends StatefulWidget {
  const _CookieForm({
    super.key,
    required this.step,
    required this.network,
    required this.busy,
    required this.onSubmit,
  });

  final NetworkLoginStep step;
  final String network;
  final bool busy;
  final Future<void> Function(Map<String, String> values) onSubmit;

  @override
  State<_CookieForm> createState() => _CookieFormState();
}

class _CookieFormState extends State<_CookieForm> {
  late final Map<String, TextEditingController> _controllers = {
    for (final field in widget.step.cookieFields)
      field.id: TextEditingController(),
  };
  final _errors = <String, String>{};
  String? _pasteNote;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _fillFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final values = parseCookieHeader(text, widget.step.cookieFields);
    if (!mounted) return;
    setState(() {
      for (final entry in values.entries) {
        _controllers[entry.key]?.text = entry.value;
      }
      final total = widget.step.cookieFields.length;
      _pasteNote = values.isEmpty
          ? 'No matching cookies on the clipboard. Copy the Cookie header '
                'of a request to ${widget.network}.'
          : 'Filled ${values.length} of $total.';
    });
  }

  Future<void> _submit() async {
    if (widget.busy) return;
    final values = <String, String>{};
    final errors = <String, String>{};
    for (final field in widget.step.cookieFields) {
      final value = _controllers[field.id]!.text.trim();
      final error = field.check(value);
      if (error != null) {
        errors[field.id] = error;
      } else if (value.isNotEmpty) {
        values[field.id] = value;
      }
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) return;
    for (final controller in _controllers.values) {
      controller.clear();
    }
    await widget.onSubmit(values);
  }

  @override
  Widget build(BuildContext context) {
    final typography = context.notion.typography;
    final url = widget.step.cookieUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in to ${widget.network} in a browser, then copy the Cookie '
          'header of any request to ${url?.host ?? 'the site'} (developer '
          'tools → Network) and paste the values below. They go only to '
          'your bridge.',
          style: typography.calloutMuted,
        ),
        const SizedBox(height: NotionSpace.sm),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: NotionSpace.xs,
          runSpacing: NotionSpace.xs,
          children: [
            if (url != null)
              NotionButton(
                key: const ValueKey('add-network-open-site'),
                label: 'Open ${url.host}',
                icon: Icons.open_in_new,
                onPressed: () => unawaited(
                  launcher.launchUrl(
                    url,
                    mode: launcher.LaunchMode.externalApplication,
                  ),
                ),
              ),
            NotionButton(
              key: const ValueKey('add-network-paste-cookies'),
              label: 'Fill from clipboard',
              icon: Icons.content_paste,
              onPressed: widget.busy
                  ? null
                  : () => unawaited(_fillFromClipboard()),
            ),
          ],
        ),
        if (_pasteNote != null)
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xs),
            child: Text(
              _pasteNote!,
              textAlign: TextAlign.center,
              style: typography.captionMuted,
            ),
          ),
        const SizedBox(height: NotionSpace.md),
        for (final field in widget.step.cookieFields)
          Padding(
            padding: const EdgeInsets.only(bottom: NotionSpace.sm),
            child: NotionTextField(
              key: ValueKey('add-network-cookie-${field.id}'),
              label: field.id,
              helper: [
                ...field.sources.map((source) => source.describe),
                if (!field.required) 'optional',
              ].join(' · '),
              error: _errors[field.id],
              controller: _controllers[field.id],
              enabled: !widget.busy,
              obscureText: true,
              autocorrect: false,
              keyboardType: TextInputType.visiblePassword,
            ),
          ),
        Center(
          child: NotionButton.primary(
            key: const ValueKey('add-network-submit'),
            label: 'Sign in',
            busy: widget.busy,
            onPressed: widget.busy ? null : () => unawaited(_submit()),
          ),
        ),
      ],
    );
  }
}
