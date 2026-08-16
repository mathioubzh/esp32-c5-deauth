import 'package:deauther/main.dart';
import 'package:deauther/screens/scan_screen.dart';
import 'package:deauther/services/api_server.dart';
import 'package:deauther/services/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots into scan screen', (WidgetTester tester) async {
    final settings = Settings.forTesting();
    final api = ApiServer(settings);

    await tester.pumpWidget(
      DeautherApp(
        settings: settings,
        api: api,
        home: const ScanScreen(autoStart: false),
      ),
    );
    await tester.pump();
    expect(find.text('ESP32-C5 Deauther'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Open diagnostic log'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    api.dispose();
    settings.dispose();
  });
}
