// Smoke test: the fully wired app boots (repos load from a mocked
// support dir, SourceManager + PlayerController construct, AppShell
// renders) without exceptions. Real file IO needs runAsync.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:upze_flutter/main.dart';
import 'package:upze_flutter/ui/app_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp/upze_test_support',
    );
    // Skip the first-run setup gate: a finished-setup accounts file.
    final dir = Directory('/tmp/upze_test_support');
    await dir.create(recursive: true);
    await File('${dir.path}/accounts.json')
        .writeAsString('{"setupDone": true, "seedArtistIds": []}');
  });

  testWidgets('App boots to the shell', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const UpZeApp());
      // Let the real async boot (file IO + repo loads) finish.
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.byType(AppShell).evaluate().isNotEmpty) break;
      }
    });
    expect(find.byType(AppShell), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
