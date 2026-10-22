// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The native window's visibility (macOS: not occluded and not minimised),
/// reported by `MainFlutterWindow.swift` over the desktop channel. Drives
/// `NotionActivity` together with the app lifecycle.
abstract final class MacDesktopWindow {
  static final visible = ValueNotifier<bool>(true);
}

/// What the inbox offers to keyboard shortcuts.
class MacInboxCommands {
  const MacInboxCommands({
    required this.search,
    this.openAt,
    this.step,
    this.nextUnread,
  });

  /// Global search, also where new chats start (⌘K, ⌘N).
  final VoidCallback search;

  /// Opens the chat at [index] (0-based) of the quick order: pinned chats,
  /// then the inbox list (⌘1…⌘9).
  final void Function(int index)? openAt;

  /// Opens the next (+1) or previous (−1) chat in inbox order.
  final void Function(int delta)? step;

  /// Opens the next chat with unread messages after the open one.
  final VoidCallback? nextUnread;
}

/// What an open conversation offers to keyboard shortcuts.
class MacChatCommands {
  const MacChatCommands({
    required this.searchInChat,
    required this.scrollToTop,
    required this.scrollToBottom,
  });

  /// ⌘F: search this conversation.
  final VoidCallback searchInChat;

  /// ⌘↑: the oldest loaded message.
  final VoidCallback scrollToTop;

  /// ⌘↓: the newest message.
  final VoidCallback scrollToBottom;
}

/// One inbox and one open conversation own the shortcuts, including while
/// the composer in the other column has focus. A replaced owner cannot
/// unregister its successor's commands. Nothing runs while the app lock
/// covers the surface.
abstract final class MacDesktopCommands {
  static Object? _inboxOwner;
  static MacInboxCommands? _inbox;
  static Object? _chatOwner;
  static MacChatCommands? _chat;

  static void bindInbox(Object owner, MacInboxCommands commands) {
    _inboxOwner = owner;
    _inbox = commands;
  }

  static void unbindInbox(Object owner) {
    if (!identical(_inboxOwner, owner)) return;
    _inboxOwner = null;
    _inbox = null;
  }

  static void bindSearch(Object owner, VoidCallback search) =>
      bindInbox(owner, MacInboxCommands(search: search));

  static void unbindSearch(Object owner) => unbindInbox(owner);

  static void bindChat(Object owner, MacChatCommands commands) {
    _chatOwner = owner;
    _chat = commands;
  }

  static void unbindChat(Object owner) {
    if (!identical(_chatOwner, owner)) return;
    _chatOwner = null;
    _chat = null;
  }

  static bool get _unlocked => PersonalPrivacy.surfaceUnlocked;

  /// Whether a conversation is open (and bound).
  static bool get hasChat => _chat != null;

  static void search() {
    if (_unlocked) _inbox?.search();
  }

  /// ⌘F: the open conversation's search, else the global one.
  static void find() {
    if (!_unlocked) return;
    final chat = _chat;
    chat == null ? _inbox?.search() : chat.searchInChat();
  }

  static void openAt(int index) {
    if (_unlocked) _inbox?.openAt?.call(index);
  }

  static void step(int delta) {
    if (_unlocked) _inbox?.step?.call(delta);
  }

  static void nextUnread() {
    if (_unlocked) _inbox?.nextUnread?.call();
  }

  static void scrollToTop() {
    if (_unlocked) _chat?.scrollToTop();
  }

  static void scrollToBottom() {
    if (_unlocked) _chat?.scrollToBottom();
  }

  @visibleForTesting
  static void debugReset() {
    _inboxOwner = _chatOwner = null;
    _inbox = null;
    _chat = null;
  }
}

/// One entry of the shortcuts help sheet (⌘/).
typedef MacShortcutHelp = ({String keys, String action});

/// Shown by the help sheet; mirrors [MacDesktopIntegration.shortcuts].
const macShortcutHelp = <MacShortcutHelp>[
  (keys: '⌘K   ⌘N', action: 'Search, start a new chat'),
  (keys: '⌘F', action: 'Search in the open chat'),
  (keys: '⌘1 … ⌘9', action: 'Open a pinned chat, then chats in list order'),
  (keys: '⌃Tab   ⌘]   ⌥↓', action: 'Next chat'),
  (keys: '⌃⇧Tab   ⌘[   ⌥↑', action: 'Previous chat'),
  (keys: '⌥⇧↓', action: 'Next unread chat'),
  (keys: '⌘↑   ⌘↓', action: 'Oldest loaded message, newest message'),
  (keys: '↑', action: 'Edit your last message (empty composer)'),
  (keys: 'Esc', action: 'Close a menu, dialog or sheet; cancel a reply'),
  (keys: '⌘,', action: 'Settings'),
  (keys: '⌘/', action: 'Keyboard shortcuts'),
];

enum _MacCommand {
  search,
  find,
  settings,
  help,
  next,
  previous,
  nextByArrow,
  previousByArrow,
  nextUnread,
  top,
  bottom,
  open1,
  open2,
  open3,
  open4,
  open5,
  open6,
  open7,
  open8,
  open9,
}

class _MacIntent extends Intent {
  const _MacIntent(this.command);
  final _MacCommand command;
}

/// Arrow-key shortcuts that also edit text (⌥↑/⌥↓ move by paragraph,
/// ⌘↑/⌘↓ to the start/end) yield to a focused field that holds text.
const _textCommands = {
  _MacCommand.nextByArrow,
  _MacCommand.previousByArrow,
  _MacCommand.nextUnread,
  _MacCommand.top,
  _MacCommand.bottom,
};

/// Whether the focused widget is a text field that holds text.
bool _editingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final editable =
      context is StatefulElement && context.state is EditableTextState
      ? context.state as EditableTextState
      : context.findAncestorStateOfType<EditableTextState>();
  return editable != null && editable.textEditingValue.text.isNotEmpty;
}

class _MacAction extends Action<_MacIntent> {
  _MacAction(this.run);
  final void Function(_MacCommand) run;

  @override
  bool isEnabled(_MacIntent intent) =>
      !_textCommands.contains(intent.command) || !_editingText();

  @override
  Object? invoke(_MacIntent intent) {
    run(intent.command);
    return null;
  }
}

class MacDesktopIntegration extends StatefulWidget {
  final Widget child;
  final VoidCallback onSettings;
  final VoidCallback onWake;

  /// ⌘/: shows the keyboard shortcuts sheet.
  final VoidCallback? onShortcutsHelp;
  const MacDesktopIntegration({
    super.key,
    required this.child,
    required this.onSettings,
    required this.onWake,
    this.onShortcutsHelp,
  });

  /// macOS bindings; [macShortcutHelp] documents them.
  static const shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.keyK, meta: true): _MacIntent(
      _MacCommand.search,
    ),
    SingleActivator(LogicalKeyboardKey.keyN, meta: true): _MacIntent(
      _MacCommand.search,
    ),
    SingleActivator(LogicalKeyboardKey.keyF, meta: true): _MacIntent(
      _MacCommand.find,
    ),
    SingleActivator(LogicalKeyboardKey.comma, meta: true): _MacIntent(
      _MacCommand.settings,
    ),
    SingleActivator(LogicalKeyboardKey.slash, meta: true): _MacIntent(
      _MacCommand.help,
    ),
    SingleActivator(LogicalKeyboardKey.slash, meta: true, shift: true):
        _MacIntent(_MacCommand.help),
    SingleActivator(LogicalKeyboardKey.tab, control: true): _MacIntent(
      _MacCommand.next,
    ),
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
        _MacIntent(_MacCommand.previous),
    SingleActivator(LogicalKeyboardKey.bracketRight, meta: true): _MacIntent(
      _MacCommand.next,
    ),
    SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): _MacIntent(
      _MacCommand.previous,
    ),
    SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): _MacIntent(
      _MacCommand.nextByArrow,
    ),
    SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): _MacIntent(
      _MacCommand.previousByArrow,
    ),
    SingleActivator(LogicalKeyboardKey.arrowDown, alt: true, shift: true):
        _MacIntent(_MacCommand.nextUnread),
    SingleActivator(LogicalKeyboardKey.arrowUp, meta: true): _MacIntent(
      _MacCommand.top,
    ),
    SingleActivator(LogicalKeyboardKey.arrowDown, meta: true): _MacIntent(
      _MacCommand.bottom,
    ),
    SingleActivator(LogicalKeyboardKey.digit1, meta: true): _MacIntent(
      _MacCommand.open1,
    ),
    SingleActivator(LogicalKeyboardKey.digit2, meta: true): _MacIntent(
      _MacCommand.open2,
    ),
    SingleActivator(LogicalKeyboardKey.digit3, meta: true): _MacIntent(
      _MacCommand.open3,
    ),
    SingleActivator(LogicalKeyboardKey.digit4, meta: true): _MacIntent(
      _MacCommand.open4,
    ),
    SingleActivator(LogicalKeyboardKey.digit5, meta: true): _MacIntent(
      _MacCommand.open5,
    ),
    SingleActivator(LogicalKeyboardKey.digit6, meta: true): _MacIntent(
      _MacCommand.open6,
    ),
    SingleActivator(LogicalKeyboardKey.digit7, meta: true): _MacIntent(
      _MacCommand.open7,
    ),
    SingleActivator(LogicalKeyboardKey.digit8, meta: true): _MacIntent(
      _MacCommand.open8,
    ),
    SingleActivator(LogicalKeyboardKey.digit9, meta: true): _MacIntent(
      _MacCommand.open9,
    ),
  };

  /// The shortcuts and their actions around [child] (also for tests, which
  /// do not run on macOS).
  @visibleForTesting
  static Widget bindings({
    required Widget child,
    required VoidCallback onSettings,
    VoidCallback? onShortcutsHelp,
  }) => Shortcuts(
    shortcuts: shortcuts,
    child: Actions(
      actions: {
        _MacIntent: _MacAction(
          (command) => _run(command, onSettings, onShortcutsHelp),
        ),
      },
      child: child,
    ),
  );

  static void _run(
    _MacCommand command,
    VoidCallback onSettings,
    VoidCallback? onShortcutsHelp,
  ) {
    switch (command) {
      case _MacCommand.search:
        MacDesktopCommands.search();
      case _MacCommand.find:
        MacDesktopCommands.find();
      case _MacCommand.settings:
        if (PersonalPrivacy.surfaceUnlocked) onSettings();
      case _MacCommand.help:
        if (PersonalPrivacy.surfaceUnlocked) onShortcutsHelp?.call();
      case _MacCommand.next || _MacCommand.nextByArrow:
        MacDesktopCommands.step(1);
      case _MacCommand.previous || _MacCommand.previousByArrow:
        MacDesktopCommands.step(-1);
      case _MacCommand.nextUnread:
        MacDesktopCommands.nextUnread();
      case _MacCommand.top:
        MacDesktopCommands.scrollToTop();
      case _MacCommand.bottom:
        MacDesktopCommands.scrollToBottom();
      case _MacCommand.open1 ||
          _MacCommand.open2 ||
          _MacCommand.open3 ||
          _MacCommand.open4 ||
          _MacCommand.open5 ||
          _MacCommand.open6 ||
          _MacCommand.open7 ||
          _MacCommand.open8 ||
          _MacCommand.open9:
        MacDesktopCommands.openAt(command.index - _MacCommand.open1.index);
    }
  }

  @override
  State<MacDesktopIntegration> createState() => _MacDesktopIntegrationState();
}

class _MacDesktopIntegrationState extends State<MacDesktopIntegration> {
  static const _channel = MethodChannel('pl.personal.chat/desktop');
  static Object? _owner;

  void _settings() {
    if (PersonalPrivacy.surfaceUnlocked) widget.onSettings();
  }

  @override
  void initState() {
    super.initState();
    if (!PlatformInfos.isMacOS) return;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'search':
          // The menu's ⌘F ("Find…"): the open chat first, like the key.
          MacDesktopCommands.find();
        case 'settings':
          _settings();
        case 'wake':
          widget.onWake();
        case 'visibility':
          final visible = call.arguments;
          if (visible is bool) MacDesktopWindow.visible.value = visible;
      }
    });
  }

  @override
  void dispose() {
    if (identical(_owner, this)) {
      _owner = null;
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformInfos.isMacOS
      ? MacDesktopIntegration.bindings(
          onSettings: widget.onSettings,
          onShortcutsHelp: widget.onShortcutsHelp,
          child: widget.child,
        )
      : widget.child;
}
