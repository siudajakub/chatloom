import 'package:fluffychat/pages/chat/chat_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('failed timeline offers an actionable retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatTimelineLoadError(onRetry: () => retries++)),
      ),
    );
    expect(find.text('Could not load this conversation.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
    expect(tester.takeException(), isNull);
  });
}
