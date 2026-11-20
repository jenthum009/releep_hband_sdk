# releep_hband_sdk

> คู่มือภาษาไทยสำหรับนำไปใช้ในแอปอื่น : [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md)

Flutter plugin for **Veepoo / HBand** smartwatches (Android + iOS): scan, connect, and an
**SOS & fall guard** that keeps running in the background and forwards events to a webhook.

| | Android | iOS |
|---|---|---|
| Veepoo SDK | `vpprotocol 2.3.85.15` + `vpbluetooth 1.20` (+ JieLi / Bluetrum / Goodix libs) | `VeepooBleSDK 2.2.107.15` (+ JieLi / ABParTool / GRDFU) |
| Background | Foreground service (`connectedDevice`), restart on swipe-away + reboot | `bluetooth-central` background mode |
| Min OS | Android 7 (API 24) | iOS 13, **physical device only** (SDK has no simulator slice) |

## How SOS / fall is detected

Firmwares differ, so three channels run together (one 10 s dedupe window):

1. **Raw frame signature `8F 08 03 …`** — on the tested VIGOR firmware (device 1216, fw 00.16.02)
   an SOS press **and** a fall send this same frame → reported as `EMERGENCY_ALARM`.
   - Android: read from the SDK's `ble_change.txt` log (polled every 0.8 s).
   - iOS: `HBFrameSniffer` hooks the SDK's `peripheral:didUpdateValueForCharacteristic:error:`
     and passes every frame through unchanged. **Not yet verified with a real watch.**
2. **SDK SOS push** → `SOS_PRESSED` (`ISOSListener` / `receiveDeviceSOSCommand`).
3. **SDK fall push** → `FALL_DETECTED`, only when the firmware reports reminder-event support.

### SOS calls need call Bluetooth + SOS contacts
When SOS is pressed the watch **dials its SOS contacts itself through the phone over call
Bluetooth (Bluetooth Classic / HFP)** — BLE alone is not enough. With call Bluetooth not paired
(watch reports `broadcasting`) and no SOS contact, a press may send nothing to the app at all.

```dart
final bt = await HBandSdk.readCallBluetoothState();   // status: connected / broadcasting / …
if (!bt.isConnected) await HBandSdk.connectCallBluetooth(); // Android: pairing dialog; iOS: pair in Settings
await HBandSdk.addContact(name: 'Mom', phone: '0812345678', sos: true);
await HBandSdk.setSosCallTimes(2);
HBandSdk.callBluetoothState.listen(print);
```

A newly paired watch gets an SOS call count of **1** (the factory value is often 3, so one press
dialled the contact three times). This is set once per watch after its first session; a count set
later with `setSosCallTimes` is kept. Forget + re-pair applies it again.

## Usage

```dart
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

final init = await HBandSdk.initialize();          // resumes the guard if a watch is paired
HBandSdk.events.where((e) => e.isEmergency).listen(showAlert);
HBandSdk.connectionState.listen(print);

if (init.session == null) {
  await HBandSdk.requestPermissions();
  HBandSdk.scanResults.listen((device) => /* show in list */ null);
  await HBandSdk.startScan(timeout: const Duration(seconds: 12));
  final result = await HBandSdk.connect(device, password: '0000');
}

await HBandSdk.setWebhookConfig(url: 'https://example.com/hook', enabled: true);
```

Other methods: `disconnect`, `forgetWatch`, `getSession`, `readBattery`, `startGuard` / `stopGuard`,
`getEvents`, `acknowledgeEvent`, `simulateEmergency`, `testWebhook`, `getRawFrames` (Android),
`requestIgnoreBatteryOptimizations` (Android).

### Channels

| Channel | Type | Payload |
|---|---|---|
| `releep_hband_sdk/method` | MethodChannel | see `lib/src/hband_sdk.dart` |
| `releep_hband_sdk/scan` | EventChannel | `{deviceId, name, rssi}` / `{finished: true}` |
| `releep_hband_sdk/connection` | EventChannel | `{state, deviceId, name, message, guardRunning}` |
| `releep_hband_sdk/events` | EventChannel | `{id, type, timestamp, detail, webhookStatus, acknowledged, data}` |

`state` ∈ `disconnected · connecting · verifying · ready · passwordFailed · failed`

### Webhook payload

```json
{
  "event": "EMERGENCY_ALARM",
  "timestamp": 1790533587348,
  "timestampIso": "…",
  "platform": "android",
  "detection": "frame-signature",
  "possibleTriggers": ["SOS button press", "fall detection"],
  "rawFrame": "…8F,08,03,01,02,CE,…",
  "watch": { "sn": "1216", "mac": "76:EA:BE:E7:93:61", "name": "VIGOR", "firmware": "00.16.02", "firmwareTest": "00.16.02.00" }
}
```

## Health data → `api/smartwatch_vp_insert/{type}`

The plugin reads the watch and returns records **already in the backend `data[]` shape**
(`time` = local time `yyyy-MM-dd HH:mm:ss`, no timezone; `source` = `online` / `offline`).
The host app logs in and POSTs them — the plugin never calls the backend.

```dart
final imei = await HBandSdk.getImei();                // "76:EA:BE:E7:93:61"
HBandSdk.syncProgress.listen((p) => print('${p.stage} ${p.progress}'));

final sync = await HBandSdk.syncHealthData(days: 3);  // history stored on the watch
for (final req in sync.toInsertRequests(imei!)) {     // split by backend limits (ECG ≤ 20)
  await http.post(Uri.parse('$healthApiUrl/${req.path}'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode(req.body));
}

HBandSdk.measurementUpdates.listen((u) => print(u.value));  // live value / ECG samples
final m = await HBandSdk.startMeasurement(HBandMeasureType.bloodPressure);
final req = m.toInsertRequest(imei);                  // null when failed / no backend type
// or HBandSdk.measureHeartRate(), measureHrv(), measureCheckup() … ;
// m.toInsertRequests(imei) also covers a checkup (one request per backend type)
```

On-demand only (no backend type yet, record is for display): `bloodcomponent`, `bodycomposition`,
`gsr`, `met`, `emotion`; `checkup` measures several values at once. Use
`(await HBandSdk.getCapabilities()).canMeasure(type)` to hide what the watch can't do.

Re-syncing is safe — the backend skips records whose `time` already exists.
Only one sync or measurement runs at a time (`PlatformException` `BUSY` / `NOT_READY`).

| type | sync (history, `offline`) | measure now (`online`) |
|---|---|---|
| `heartrate` | 5-min data | ✓ |
| `bloodpressure` | 5-min data / BP list | ✓ |
| `spo2` (+ apnea / hypoxia / cardiac load…) | SpO2 data | ✓ |
| `respiratory` | SpO2 data / 5-min data | ✓ |
| `hrv` | HRV data | ✓ (≈30 s) |
| `bodytemp` (+ `base_temp`) | temperature data | ✓ |
| `bloodglucose` (+ risk / calibration) | 5-min data | ✓ |
| `stepcount`, `calorie` | daily running total + current value | |
| `battery` | current value | |
| `sleep` (+ precision scores) | sleep data | |
| `sport` | workout sessions | |
| `ecg` | ECG stored on the watch (`mode: auto`) | ✓ `ecg` (`manual`), `ptt` (`mode: ptt`) |
| `rrinterval` | RR blocks (ms) | |
| `heartwarning` | synced heart rate outside the watch's alarm limits | |
| `fatigue` | — (not stored by the watch) | ✓ (1–4 → good / middle / bad) |
| `stress` | 5-min data (watches with stress support) | ✓ (0–100; <40 good, <70 middle, else bad) |

Needs confirming with a real watch: iOS `deviceAddress` = MAC (used as `imei`), workout
duration / distance units, and PTT (the watch must be in PTT mode; captured for 30 s).

## Host app setup

### Android
Nothing extra — permissions, services and the boot receiver come from the plugin manifest.
The Veepoo AARs are served from a file-based Maven repo inside the plugin (`android/libs-maven`).
`vpprotocol`'s embedded manifest was patched to drop its `<application android:label …>`
attributes, which otherwise clash with every host app (see `PATCHED.txt` next to the AAR).

### iOS
`ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Bluetooth is used to connect to your watch and receive SOS / fall alerts.</string>
<key>UIBackgroundModes</key>
<array><string>bluetooth-central</string></array>
```

`ios/Podfile`: `platform :ios, '13.0'` with `use_frameworks!` (Flutter default).
The plugin sets itself as `UNUserNotificationCenter` delegate only if the app has none.

## Limitations

- SOS vs fall cannot be told apart on the tested firmware (same frame).
- iOS: no MAC address — `deviceId` is the SDK's `deviceAddress`. If the user swipes the app away, iOS
  stops background Bluetooth until the app is opened again.
- Android: Force-stopping the app in system settings stops the guard until the app is opened again.
  OEM battery savers (realme / ColorOS, Xiaomi, …) need the "allow background run" exemption.
- The SDK does not support parallel commands — the plugin issues one command at a time.

## Example app

`example/` contains a complete app: pairing (permissions → scan → password → connect progress),
dashboard (watch card, guard switch, live feed), full-screen emergency alert, and settings
(webhook, background, raw BLE frames, forget watch).
