import 'package:fluffychat/pages/chat/chat.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'the actual source controller does not submit an active IME candidate',
    () {
      final controller = _SubmitProbe();
      addTearDown(controller.sendController.dispose);
      addTearDown(controller.scrollController.dispose);
      controller.sendController.value = const TextEditingValue(
        text: 'candidate',
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange(start: 0, end: 9),
      );
      // A composing submit must return before either send or context/focus access.
      controller.onInputBarSubmitted('candidate');
      expect(controller.sends, 0);
      expect(controller.sendController.text, 'candidate');
    },
  );
}

class _SubmitProbe extends ChatController {
  int sends = 0;
  @override
  Future<void> send() async {
    sends++;
  }
}
