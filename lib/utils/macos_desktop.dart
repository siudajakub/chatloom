// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/ui/notion/notion_tokens.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The native window's visibility (macOS: not occluded and not minimised),
/// reported by `MainFlutterWindow.swift` over the desktop channel. Drives
/// `NotionActivity` together with the app lifecycle.
abstract final class MacDesktopWindow {
  static final visible = ValueNotifier<bool>(true);

  /// Height of the transparent title bar over the app (the traffic lights),
  /// from `WindowChrome.swift`; 0 in full screen and off the Mac.
  static final titlebarInset = ValueNotifier<double>(0);

  /// Window chrome and pasteboard queries (`WindowChrome.swift`).
  static const channel = MethodChannel('pl.personal.chat/window');

  /// Whether the pasteboard holds media first (files, or an image ahead of
  /// any text). True when the native side cannot tell, so a paste behaves
  /// as before.
  static Future<bool> pasteboardPrefersMedia() async {
    try {
      return await channel.invokeMethod<bool>('pasteboardPrefersMedia') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Applies a `titlebarInset` value from the native side.
  @visibleForTesting
  static void applyInset(Object? value) {
    if (value is num && value.isFinite && value >= 0 && value < 200) {
      titlebarInset.value = value.toDouble();
    }
  }
}

/// Raises the top padding by the transparent title bar (Telegram for macOS):
/// every header already reserves `MediaQuery.padding.top` for a status bar,
/// so its glass reaches under the traffic lights and its row sits below
/// them. The tree shape never changes with the inset.
class MacTitlebarInset extends StatelessWidget {
  const MacTitlebarInset({super.key, required this.inset, required this.child});

  final ValueListenable<double> inset;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: inset,
    child: child,
    builder: (context, top, child) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: top <= 0
            ? media
            : media.copyWith(
                padding: media.padding.copyWith(top: media.padding.top + top),
                viewPadding: media.viewPadding.copyWith(
                  top: media.viewPadding.top + top,
                ),
              ),
        child: child!,
      );
    },
  );
}

/// What the inbox offers to keyboard shortcuts.
class MacInboxCommands {
  const MacInboxCommands({
    required this.search,
    this.openAt,
    this.step,
    this.nextUnread,
    this.toggleArchived,
    this.toggleUnread,
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

  /// ⌘⇧A: archives the open chat (unarchives it in the Archive view).
  final VoidCallback? toggleArchived;

  /// ⌘⇧U: marks the open chat unread, or read when it is unread.
  final VoidCallback? toggleUnread;
}

/// What an open conversation offers to keyboard shortcuts.
class MacChatCommands {
  const MacChatCommands({
    required this.searchInChat,
    required this.scrollToTop,
    required this.scrollToBottom,
    this.typeIntoComposer,
    this.escape,
  });

  /// ⌘F: search this conversation.
  final VoidCallback searchInChat;

  /// ⌘↑: the oldest loaded message.
  final VoidCallback scrollToTop;

  /// ⌘↓: the newest message.
  final VoidCallback scrollToBottom;

  /// Text typed while focus is elsewhere in the chat or the inbox; false
  /// when the composer cannot take it.
  final bool Function(String text)? typeIntoComposer;

  /// Esc on the messages: what Back does (cancel the reply or edit, close
  /// the panel or thread, then close the chat). The composer's Esc is
  /// `ComposerBackAction`.
  final bool Function()? escape;
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

  static void toggleArchived() {
    if (_unlocked) _inbox?.toggleArchived?.call();
  }

  static void toggleUnread() {
    if (_unlocked) _inbox?.toggleUnread?.call();
  }

  /// Whether [context] lies inside the bound [owner]'s widget (a `State`).
  static bool _within(Object? owner, BuildContext context) {
    if (owner is! State || !owner.mounted) return false;
    final zone = owner.context;
    if (identical(zone, context)) return true;
    var found = false;
    context.visitAncestorElements((element) {
      found = identical(element, zone);
      return !found;
    });
    return found;
  }

  /// A bare Esc with focus on the messages (macOS early key handler,
  /// Telegram desktop: Back). The timeline's `SelectionArea` would swallow
  /// it (it only hides a selection toolbar), so it is taken before the focus
  /// tree. Text fields keep Esc for their own overlays (the composer's
  /// reaches `ComposerBackAction`); other routes and the inbox keep theirs.
  static KeyEventResult handleEarlyKey(KeyEvent event) {
    final chat = _chat;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        chat == null ||
        !_unlocked) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (focus == null ||
        context == null ||
        !context.mounted ||
        _editableOf(context) != null) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed ||
        !_within(_chatOwner, context)) {
      return KeyEventResult.ignored;
    }
    return chat.escape?.call() == true
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// Keys no widget handled (macOS late key handler). Telegram desktop:
  /// typing with focus on a message or the inbox writes in the composer.
  /// Never inside another route (menus, dialogs, sheets, the media viewer),
  /// a text field, or through the app lock.
  static KeyEventResult handleUnhandledKey(KeyEvent event) {
    final chat = _chat;
    if (event is! KeyDownEvent || chat == null || !_unlocked) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (focus == null || context == null || !context.mounted) {
      return KeyEventResult.ignored;
    }
    if (_editableOf(context) != null) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final text = macTypedText(
      event,
      metaPressed: keyboard.isMetaPressed,
      controlPressed: keyboard.isControlPressed,
    );
    if (text == null ||
        (!_within(_chatOwner, context) && !_within(_inboxOwner, context))) {
      return KeyEventResult.ignored;
    }
    return chat.typeIntoComposer?.call(text) == true
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
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
  (keys: '⌘⇧A', action: 'Archive or unarchive the open chat'),
  (keys: '⌘⇧U', action: 'Mark the open chat unread or read'),
  (keys: '↑', action: 'Edit your last message (empty composer)'),
  (keys: '⌘↩', action: 'Send, also when Enter adds a new line'),
  (
    keys: 'Esc',
    action: 'Close a menu or dialog; cancel a reply; close the chat',
  ),
  (keys: 'A … Z', action: 'Typing anywhere in a chat writes in its composer'),
  (keys: '⌘W', action: 'Close the window (ChatLoom keeps syncing)'),
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
  archive,
  unread,
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

/// The text field [context] (a focused node's) belongs to, if any.
EditableTextState? _editableOf(BuildContext context) =>
    context is StatefulElement && context.state is EditableTextState
    ? context.state as EditableTextState
    : context.findAncestorStateOfType<EditableTextState>();

/// Whether the focused widget is a text field that holds text.
bool _editingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final editable = _editableOf(context);
  return editable != null && editable.textEditingValue.text.isNotEmpty;
}

/// The printable text of a key press that may type into a composer: no ⌘ or
/// ⌃ (shortcuts, text editing), no control characters (Enter, Tab, Esc,
/// Backspace) and no function or arrow keys. ⌥ and ⇧ type characters on
/// the Mac (ą, ł, capitals), so they pass.
String? macTypedText(
  KeyEvent event, {
  required bool metaPressed,
  required bool controlPressed,
}) {
  if (event is! KeyDownEvent || metaPressed || controlPressed) return null;
  final text = event.character;
  if (text == null || text.isEmpty) return null;
  for (final rune in text.runes) {
    // C0/C1 controls, DEL, and AppKit's private-use function-key range.
    if (rune < 0x20 ||
        (rune >= 0x7f && rune < 0xa0) ||
        (rune >= 0xf700 && rune <= 0xf8ff)) {
      return null;
    }
  }
  return text;
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
    SingleActivator(LogicalKeyboardKey.keyA, meta: true, shift: true):
        _MacIntent(_MacCommand.archive),
    SingleActivator(LogicalKeyboardKey.keyU, meta: true, shift: true):
        _MacIntent(_MacCommand.unread),
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
      case _MacCommand.archive:
        MacDesktopCommands.toggleArchived();
      case _MacCommand.unread:
        MacDesktopCommands.toggleUnread();
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

  /// The appearance last given to the window (`dark`), null before.
  bool? _dark;

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
        case 'help':
          // Help → Keyboard Shortcuts (the menu item; ⌘/ is a Flutter key).
          if (PersonalPrivacy.surfaceUnlocked) widget.onShortcutsHelp?.call();
        case 'wake':
          widget.onWake();
        case 'visibility':
          final visible = call.arguments;
          if (visible is bool) MacDesktopWindow.visible.value = visible;
      }
    });
    MacDesktopWindow.channel.setMethodCallHandler((call) async {
      if (call.method == 'titlebarInset') {
        MacDesktopWindow.applyInset(call.arguments);
      }
    });
    // The native side may have measured before this handler existed.
    MacDesktopWindow.channel
        .invokeMethod<double>('titlebarInset')
        .then(MacDesktopWindow.applyInset, onError: (Object _) {});
    FocusManager.instance.addEarlyKeyEventHandler(
      MacDesktopCommands.handleEarlyKey,
    );
    FocusManager.instance.addLateKeyEventHandler(
      MacDesktopCommands.handleUnhandledKey,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!PlatformInfos.isMacOS) return;
    // The window (traffic lights, menus, resize background) follows the app
    // theme, not the system appearance.
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark == _dark) return;
    _dark = dark;
    final background = dark
        ? NotionColors.dark.background
        : NotionColors.light.background;
    MacDesktopWindow.channel
        .invokeMethod<void>('appearance', {
          'dark': dark,
          'background': background.toARGB32(),
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    if (identical(_owner, this)) {
      _owner = null;
      _channel.setMethodCallHandler(null);
      MacDesktopWindow.channel.setMethodCallHandler(null);
    }
    if (PlatformInfos.isMacOS) {
      FocusManager.instance.removeEarlyKeyEventHandler(
        MacDesktopCommands.handleEarlyKey,
      );
      FocusManager.instance.removeLateKeyEventHandler(
        MacDesktopCommands.handleUnhandledKey,
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformInfos.isMacOS
      ? MacTitlebarInset(
          inset: MacDesktopWindow.titlebarInset,
          child: MacDesktopIntegration.bindings(
            onSettings: widget.onSettings,
            onShortcutsHelp: widget.onShortcutsHelp,
            child: widget.child,
          ),
        )
      : widget.child;
}
