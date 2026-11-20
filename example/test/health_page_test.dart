import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';
import 'package:releep_hband_sdk_example/guard_controller.dart';
import 'package:releep_hband_sdk_example/pages/health_page.dart';
import 'package:releep_hband_sdk_example/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('releep_hband_sdk/method'), (call) async {
      return switch (call.method) {
        'getImei' => '76:EA:BE:E7:93:61',
        'getCapabilities' => {'watchDays': 3},
        'syncHealthData' => {
          'success': false,
          'durationMs': 5000,
          'errors': {'sport': 'timeout'},
          'skipped': ['temperature'],
          'records': {
            'heartrate': [
              for (var i = 0; i < 30; i++)
                {
                  'value': 70 + i,
                  'source': 'offline',
                  'time': '2026-10-14 08:${i.toString().padLeft(2, '0')}:00',
                },
            ],
            'ecg': [
              {
                'mode': 'auto',
                'heart_rate': 72,
                'wave': List.generate(500, (i) => i % 50),
                'time': '2026-10-14 09:00:00',
              },
            ],
          },
        },
        'startMeasurement' => {'success': false, 'type': call.arguments['type'], 'message': 'Stopped'},
        _ => null,
      };
    });
    for (final name in ['progress', 'connection', 'events', 'scan']) {
      messenger.setMockStreamHandler(
        EventChannel('releep_hband_sdk/$name'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
    }
  });

  testWidgets('health page: sync, payload sheet and measure sheet render without errors', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844)); // phone
    final controller = GuardController()
      ..connection = const HBandConnectionState(status: HBandConnectionStatus.ready);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: HealthPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('76:EA:BE:E7:93:61'), findsOneWidget);

    await tester.tap(find.text('Sync from watch'));
    await tester.pumpAndSettle();
    expect(find.textContaining('LAST SYNC · 31 RECORDS'), findsOneWidget);
    expect(find.textContaining('Failed: sport (timeout)'), findsOneWidget);

    await tester.tap(find.text('Heart rate').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('POST {HEALTH_API_URL}/api/smartwatch_vp_insert/heartrate'), findsOneWidget);
    expect(find.textContaining('… 27 more'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20)); // close sheet
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('PTT'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('PTT'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
