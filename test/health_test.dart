import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sync result parses native records and builds insert requests', () {
    final result = HBandHealthSyncResult.fromMap({
      'success': false,
      'cancelled': false,
      'durationMs': 4200,
      'errors': {'sport': 'timeout'},
      'skipped': ['temperature'],
      'records': {
        'heartrate': [
          {'value': 80, 'source': 'offline', 'time': '2026-10-14 08:30:00'},
          {'value': 82, 'source': 'offline', 'time': '2026-10-14 08:35:00'},
        ],
        'ecg': [
          for (var i = 0; i < 45; i++)
            {'mode': 'auto', 'heart_rate': 70, 'time': '2026-10-14 08:${i % 60}:00'},
        ],
        'sleep': <Object?>[],
      },
    });

    expect(result.totalCount, 47);
    expect(result.counts['heartrate'], 2);
    expect(result.errors, {'sport': 'timeout'});
    expect(result.skipped, ['temperature']);
    expect(result.duration, const Duration(milliseconds: 4200));

    final requests = result.toInsertRequests('76:EA:BE:E7:93:61');
    final ecg = requests.where((r) => r.type == 'ecg').toList();
    expect(ecg.map((r) => r.count), [20, 20, 5], reason: 'ECG is limited to 20 items per request');
    expect(requests.where((r) => r.type == 'sleep'), isEmpty, reason: 'empty types are not sent');

    final hr = requests.singleWhere((r) => r.type == 'heartrate');
    expect(hr.path, 'api/smartwatch_vp_insert/heartrate');
    expect(hr.body['imei'], '76:EA:BE:E7:93:61');
    expect((hr.body['data'] as List).first, {
      'value': 80,
      'source': 'offline',
      'time': '2026-10-14 08:30:00',
    });
  });

  test('measure result becomes a single-record request (ptt → ecg)', () {
    final result = HBandMeasureResult.fromMap({
      'success': true,
      'type': 'ecg',
      'record': {
        'mode': 'ptt',
        'heart_rate': 72,
        'wave': [1, 2, 3],
        'time': '2026-10-14 08:30:00',
      },
    });
    final request = result.toInsertRequest('AA:BB')!;
    expect(request.path, 'api/smartwatch_vp_insert/ecg');
    expect(request.body['data'], hasLength(1));

    final failed = HBandMeasureResult.fromMap({'success': false, 'type': 'spo2', 'message': 'busy'});
    expect(failed.toInsertRequest('AA:BB'), isNull);
    expect(failed.message, 'busy');
  });

  test('progress events', () {
    final p = HBandSyncProgress.fromMap({
      'kind': 'sync',
      'stage': 'daily',
      'progress': 0.4,
      'stageProgress': 0.5,
    });
    expect(p.stage, 'daily');
    expect(p.progress, 0.4);
    final u = HBandMeasureUpdate.fromMap({
      'kind': 'measure',
      'type': 'ecg',
      'progress': 30,
      'samples': [1, 2],
    });
    expect(u.samples, [1, 2]);
    expect(u.progress, 30);
  });

  test('syncHealthData / startMeasurement send the expected arguments', () async {
    const channel = MethodChannel('releep_hband_sdk/method');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'syncHealthData' => {'success': true, 'records': <String, Object?>{}},
        'startMeasurement' => {
          'success': true,
          'type': 'heartrate',
          'record': {'value': 75, 'source': 'online', 'time': '2026-10-14 08:30:00'},
        },
        _ => null,
      };
    });

    final sync = await HBandSdk.syncHealthData(days: 2, types: ['heartrate', 'sleep']);
    expect(sync.success, isTrue);
    expect(calls.last.arguments, {
      'days': 2,
      'types': ['heartrate', 'sleep'],
    });

    final m = await HBandSdk.startMeasurement(HBandMeasureType.heartRate);
    expect(m.record?['value'], 75);
    expect(calls.last.arguments, {'type': 'heartrate'});
  });
}
