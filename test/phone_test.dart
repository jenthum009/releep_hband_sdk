import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('call Bluetooth state parses native maps', () {
    final waiting = HBandCallBluetoothState.fromMap({
      'supported': true,
      'status': 'broadcasting',
      'btOpen': true,
      'link': 'timeout',
    });
    expect(waiting.status, HBandCallBtStatus.broadcasting);
    expect(waiting.canPlaceSosCalls, isFalse);
    expect(waiting.link, 'timeout');

    final connected = HBandCallBluetoothState.fromMap({'supported': true, 'status': 'connected'});
    expect(connected.canPlaceSosCalls, isTrue);

    expect(HBandCallBluetoothState.fromMap(null).status, HBandCallBtStatus.unknown);
  });

  test('contact methods send ids and parse lists', () async {
    const channel = MethodChannel('releep_hband_sdk/method');
    final calls = <MethodCall>[];
    final list = [
      {'id': 3, 'name': 'Mom', 'phone': '0812345678', 'sos': true},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'getSosCallTimes' => {'times': 2, 'min': 1, 'max': 3},
        'getContactSupport' => {'contacts': true, 'sosContacts': true, 'contactType': 2},
        _ => list,
      };
    });

    final added = await HBandSdk.addContact(name: 'Mom', phone: '0812345678', sos: true);
    expect(calls.last.arguments, {'name': 'Mom', 'phone': '0812345678', 'sos': true});
    expect(added.single.sos, isTrue);
    expect(added.single.id, 3);

    await HBandSdk.setSosContact(added.single, false);
    expect(calls.last.method, 'setSosContact');
    expect(calls.last.arguments, {'id': 3, 'enabled': false});

    await HBandSdk.deleteContact(added.single);
    expect(calls.last.arguments, {'id': 3});

    final times = await HBandSdk.getSosCallTimes();
    expect((times.times, times.min, times.max), (2, 1, 3));

    expect((await HBandSdk.getContactSupport()).sosContacts, isTrue);
  });
}
