// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _OfflineMatrix extends Matrix {
  const _OfflineMatrix({required super.store, super.key})
    : super(clients: const []);

  @override
  MatrixState createState() => _OfflineMatrixState();
}

class _OfflineMatrixState extends MatrixState {
  @override
  void initMatrix() {}

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets('matrix teardown releases cached password and its timer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final key = GlobalKey<MatrixState>();
    await tester.pumpWidget(
      _OfflineMatrix(store: await SharedPreferences.getInstance(), key: key),
    );
    final state = key.currentState!;
    state.cachedPassword = 'synthetic fixture only';
    expect(state.cachedPassword, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(state.cachedPassword, isNull);
    // flutter_test also rejects a timer left pending at the end of this test.
    expect(tester.takeException(), isNull);
  });
}
