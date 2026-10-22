import 'package:chatloom/pages/chat/chat_view.dart';
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
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t load messages'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
    expect(tester.takeException(), isNull);
  });
}
