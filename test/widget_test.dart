import 'package:flutter_test/flutter_test.dart';
import 'package:govee_scene/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const GoveeApp());
    expect(find.text('Session Control'), findsOneWidget);
  });
}
