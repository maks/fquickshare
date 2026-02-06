import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:fquickshare/main.dart';
import 'package:fquickshare/state/app_state.dart';

void main() {
  testWidgets('Shows expected startup UI state', (WidgetTester tester) async {
    final state = AppState(autoStart: false);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      ),
    );

    expect(find.text('RQuickShare'), findsOneWidget);
    expect(find.text('Service: Not running'), findsOneWidget);
    expect(find.text('Auto-accept'), findsOneWidget);
    expect(find.text('Waiting for transfers...'), findsOneWidget);

    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.value, isFalse);
  });
}
