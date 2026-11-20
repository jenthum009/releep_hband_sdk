import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('models parse the native maps', () {
    test('connection state', () {
      final s = HBandConnectionState.fromMap({
        'state': 'ready',
        'deviceId': 'AA:BB',
        'name': 'VIGOR',
        'guardRunning': true,
      });
      expect(s.status, HBandConnectionStatus.ready);
      expect(s.isReady, isTrue);
      expect(s.guardRunning, isTrue);
      expect(HBandConnectionStatus.parse('nonsense'), HBandConnectionStatus.disconnected);
    });

    test('session hides empty values and unknown serial', () {
      final s = HBandSession.fromMap({
        'deviceId': 'AA',
        'name': 'VIGOR',
        'deviceNumber': -1,
        'firmware': '',
      })!;
      expect(s.deviceNumber, isNull);
      expect(s.firmware, isNull);
      expect(s.serial, 'unknown');
      expect(HBandSession.fromMap(null), isNull);
    });

    test('emergency event with nested native data', () {
      final e = HBandEvent.fromMap({
        'id': '1',
        'type': 'EMERGENCY_ALARM',
        'timestamp': 1790533587348,
        'detail': 'x',
        'acknowledged': false,
        'data': <Object?, Object?>{
          'detection': 'frame-signature',
          'possibleTriggers': ['SOS button press', 'fall detection'],
          'watch': <Object?, Object?>{'sn': '1216'},
        },
      });
      expect(e.isEmergency, isTrue);
      expect(e.acknowledged, isFalse);
      expect(e.detection, 'frame-signature');
      expect((e.data['watch'] as Map)['sn'], '1216');
      expect(e.data['possibleTriggers'], hasLength(2));
    });

    test('battery falls back to bars', () {
      final b = HBandBattery.fromMap({'isPercent': false, 'level': 3})!;
      expect(b.displayPercent, 75);
    });
  });

  group('method channel', () {
    const channel = MethodChannel('releep_hband_sdk/method');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'connect' => {'success': true, 'state': 'ready'},
          'initialize' => {
            'platform': 'android',
            'session': null,
            'connection': {'state': 'disconnected'},
          },
          _ => null,
        };
      });
    });

    test('connect sends the expected arguments', () async {
      final result = await HBandSdk.connect(
        const HBandDevice(deviceId: 'AA:BB', name: 'VIGOR', rssi: -50),
        password: '1234',
      );
      expect(result.success, isTrue);
      expect(calls.single.method, 'connect');
      expect(calls.single.arguments, {
        'deviceId': 'AA:BB',
        'name': 'VIGOR',
        'password': '1234',
        'is24Hour': true,
      });
    });

    test('initialize without session', () async {
      final init = await HBandSdk.initialize();
      expect(init.platform, 'android');
      expect(init.session, isNull);
      expect(init.connection.status, HBandConnectionStatus.disconnected);
    });
  });
}
