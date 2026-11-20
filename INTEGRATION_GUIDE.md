# คู่มือนำ `releep_hband_sdk` ไปใช้ในแอป

สำหรับทีมแอปที่จะใช้นาฬิกา **Veepoo / HBand** (VIGOR, VITRO, VANTA, Air Band …) ผ่าน plugin นี้
สถานะ ณ 2026-10-16 · เวอร์ชัน `0.0.1`

> **หลักการ :** plugin ทำหน้าที่ **ต่อนาฬิกา · อ่านค่า · จัดข้อมูลเป็น `data[]` ของ backend · สั่งงานนาฬิกา** เท่านั้น
> **ไม่เรียก backend ของเรา** — การ login, การบันทึก (`api/smartwatch_vp_insert`), การดึงค่า เป็นหน้าที่ของแอป

---

## 0. สรุปความสามารถ

| หมวด | ทำได้ | หัวข้อ |
|---|---|---|
| ค้นหา / เชื่อมต่อ | สแกน, ต่อ + ตรวจรหัส 4 หลัก, จำนาฬิกา, reconnect เอง, ลืมนาฬิกา | 3 |
| ข้อมูลสุขภาพย้อนหลัง | 15 type ในรูป `data[]` พร้อมส่ง + แบ่ง request ตามขนาดสูงสุด | 4 |
| วัดสด | ชีพจร, ความดัน, SpO2, อุณหภูมิ, ความเหนื่อยล้า, น้ำตาล, ECG, PTT | 5 |
| SOS โทรออก | รายชื่อ / รายชื่อ SOS ในนาฬิกา, จำนวนรอบโทร, Bluetooth โทร | 6 |
| SOS / ล้ม (Guard) | เฝ้าเบื้องหลัง, events, แจ้งเตือนเต็มจอ, webhook (หน้าจอ SOS แอปทำเอง — 7.1) | 7 |
| อื่น ๆ | แบตเตอรี่, ฟีเจอร์ที่นาฬิการองรับ, MAC (`imei`), raw frame, battery optimization | 8 |
| **ยังไม่มี** | ตั้งค่านาฬิกา (แจ้งเตือนชีพจร / อุณหภูมิ, ภาษา, ความถี่วัด), โหมดกีฬาสด, OTA / หน้าปัด | 11 |

| | Android | iOS |
|---|---|---|
| Veepoo SDK | `vpprotocol 2.3.85.15` + `vpbluetooth 1.20` | `VeepooBleSDK 2.2.107.15` |
| OS ขั้นต่ำ | Android 7 (API 24), `compileSdk 36` | iOS 13 · **เครื่องจริงเท่านั้น** (ไม่มี simulator) |
| เบื้องหลัง | Foreground service `connectedDevice` + เริ่มเองหลังรีบูต | `bluetooth-central` |

---

## 1. ติดตั้ง

```yaml
# pubspec.yaml
dependencies:
  releep_hband_sdk:
    path: ../releep_HBandSDK_flutter      # ชั่วคราว ก่อนขึ้น pub.dev
```

### Android
ไม่ต้องตั้งค่าเพิ่ม — permission, service, boot receiver มาจาก manifest ของ plugin
(BLE, Location ≤ Android 11, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`, …)
Veepoo AAR อยู่ใน Maven repo ภายใน plugin (`android/libs-maven`) · `minSdk` ของแอปต้อง ≥ 24

> ถ้าแอปมี plugin นาฬิกาตัวอื่นที่ประกาศ service / proguard ของตัวเอง (เช่น `releep_watch_connect` เดิม) ให้ลบออกจาก
> `AndroidManifest.xml` / `proguard-rules.pro` ของแอป · plugin นี้มี `consumer-rules.pro` keep `com.veepoo.**` ให้แล้ว

### iOS
`ios/Runner/Info.plist`
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>ใช้ Bluetooth เพื่อเชื่อมต่อนาฬิกาและรับแจ้งเหตุ SOS / ล้ม</string>
<key>UIBackgroundModes</key>
<array><string>bluetooth-central</string></array>
```
`ios/Podfile` : `platform :ios, '13.0'` + `use_frameworks!` แล้ว `pod install`

> เปลี่ยน / เพิ่ม plugin native ต้อง **build ใหม่** (hot reload ไม่พอ) · iOS ต้อง `pod install` ก่อน

---

## 2. เริ่มต้น

เรียกครั้งเดียวตอนเปิดแอป (หลัง login) — ถ้าเคยผูกนาฬิกาไว้ plugin จะ reconnect + เปิด guard เอง

```dart
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

final init = await HBandSdk.initialize();
init.session;      // นาฬิกาที่ผูกไว้ (null = ยังไม่เคยผูก)
init.connection;   // สถานะตอนนี้
```

---

## 3. ค้นหา / เชื่อมต่อ

```dart
final perm = await HBandSdk.requestPermissions();          // perm.allGranted
if (!await HBandSdk.isBluetoothEnabled()) { /* ให้ผู้ใช้เปิด Bluetooth */ }

HBandSdk.scanResults.listen((d) => list.add(d));            // HBandDevice(deviceId, name, rssi)
HBandSdk.scanFinished.listen((_) => /* หมดเวลา */ null);
await HBandSdk.startScan(timeout: const Duration(seconds: 12));

final res = await HBandSdk.connect(device, password: '0000');   // รหัสโรงงาน 0000
if (res.success) {
  final imei = await HBandSdk.getImei();   // "76:EA:BE:E7:93:61" (MAC ตัวพิมพ์ใหญ่)
} else if (res.status == HBandConnectionStatus.passwordFailed) { /* รหัสผิด */ }
```

| ฟังก์ชัน | หมายเหตุ |
|---|---|
| `connect(device)` / `connectById(deviceId, name:)` | ต่อ + ตรวจรหัส สำเร็จแล้ว **บันทึก session + เปิด guard** |
| `connectionState` (stream) / `getConnectionState()` | `disconnected · connecting · verifying · ready · passwordFailed · failed` · `isReady`, `isBusy` |
| `getSession()` | `deviceId`, `name`, `deviceNumber`, `firmware` · อยู่ข้ามการปิดแอป |
| `disconnect()` | ตัดการเชื่อมต่อ เก็บ session ไว้ |
| `forgetWatch()` | ลบ session + หยุด guard (ใช้ตอนผู้ใช้ลบนาฬิกา) |
| `getImei()` | MAC ตัวพิมพ์ใหญ่ — ใช้เป็น serial ใน `TB_Device` และ `imei` ของ API |

**ข้อควรรู้**
- **iOS ต้องสแกนเจอนาฬิกาใน session นั้นก่อนถึง `connect` ได้** (ไม่งั้นได้ `Device not found — scan again`)
  → ถ้าจะต่อนาฬิกาที่บันทึกไว้เอง ให้ `startScan` แล้วรอ `deviceId` ที่ตรงกันก่อน `connectById`
- `deviceId` บน iOS อาจไม่ใช่ตัวพิมพ์ใหญ่ — **ใช้ `deviceId` เดิมตอน connect** และใช้ `getImei()` ตอนคุยกับ backend
- นาฬิกาที่ผูกไว้ reconnect เอง — เช็ค `getConnectionState()` / รอ `connectionState` ก่อนสั่ง connect ซ้ำ
- **แนะนำ : ต่อนาฬิกาให้ติดก่อน แล้วค่อยผูก `TB_Device`** ด้วย `getImei()` จะได้ serial ตรงกับ `imei` ที่ใช้บันทึก
- **`connect` บันทึก session ทันที** — ถ้าผู้ใช้ยกเลิกฟอร์ม / ปัดแอปทิ้งก่อนผูกกับ backend สำเร็จ ต้อง `forgetWatch()` เอง
  แนวทางที่แนะนำ : ตอน connect เก็บ flag "รอบันทึก" ใน SharedPreferences → บันทึกฟอร์มสำเร็จค่อยจำนาฬิกา + ลบ flag →
  ปิดฟอร์มโดยไม่บันทึก หรือเปิดแอปแล้วเจอ flag ค้าง → `forgetWatch()`

---

## 4. ข้อมูลสุขภาพย้อนหลัง → `api/smartwatch_vp_insert/{type}`

```dart
HBandSdk.syncProgress.listen((p) => print('${p.stage} ${(p.progress * 100).round()}%'));

final sync = await HBandSdk.syncHealthData(days: 3);   // types: [...] เลือกบาง type ได้
sync.totalCount; sync.records; sync.errors; sync.skipped; sync.duration;

final imei = (await HBandSdk.getImei())!;
for (final req in sync.toInsertRequests(imei)) {        // แบ่งก้อน : ≤ 50,000 รายการ, ECG ≤ 20
  final r = await http.post(
    Uri.parse('$healthApiUrl/${req.path}'),             // req.path = "api/smartwatch_vp_insert/<type>"
    headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
    body: jsonEncode(req.body),                          // {"imei": ..., "data": [...]}
  );
  // 200 → {"inserted", "skipped", "skippedList"} · 401 login ใหม่ · 403 imei ยังไม่ผูก user · 400/500 ส่งใหม่รอบหน้า
}
```

- record อยู่ในรูปที่ backend ต้องการแล้ว : `time` = เวลาไทย `yyyy-MM-dd HH:mm:ss` **ไม่มี timezone**,
  `source` = `offline` (ย้อนหลัง) / `online` (ค่าปัจจุบัน) · sleep ใช้ `startTime` / `endTime` (unix ms)
- **ส่งซ้ำได้ปลอดภัย** backend ข้ามรายการที่ `time` ซ้ำ → sync ไม่สำเร็จก็ sync ใหม่ทั้งก้อนได้ ไม่ต้องลบข้อมูลในนาฬิกา
- `cancelHealthSync()` ยกเลิกกลางทาง

| type | Android | iOS | field |
|---|:-:|:-:|---|
| `heartrate` | ✅ | ✅ | `value`, `source`, `time` |
| `spo2` | ✅ | ✅ | + `apnea_result`, `is_hypoxia`, `hypoxia_time`, `hypopnea`, `cardiac_load`, `hr_variation` |
| `bloodpressure` | ✅ | ✅ | `sbp`, `dbp` |
| `bodytemp` | ✅ | ✅ | + `base_temp` (อุณหภูมิผิว) |
| `respiratory` | ✅ | ✅ | `value` |
| `hrv` | ✅ | ✅ | `value`, `bpm`, `hrv_type` (iOS = `1` ตายตัว) |
| `stepcount` / `calorie` | ✅ | ✅ | ยอด**สะสมรายวัน** + `distance` (km), `battery_level` |
| `battery` | ✅ | ✅ | `value` (%) |
| `sleep` | ✅ | ✅ | `allSleep`, `deepSleep`, `lightSleep`, `rem`, `awakeShort` (นาที) + `sleep_date`, `sleep_quality`, `wake_count`, `sleep_line`, คะแนน (รุ่นที่รองรับ) |
| `sport` | ✅ | ✅ | `sport_type`, `time`, `end_time`, `duration` (วิ), `steps`, `distance` (km), `calories`, `avg_heartrate`, `pause_*`, `pace`, `sport_count` |
| `ecg` | ✅ | ✅ | `mode: auto`, ค่าเฉลี่ย, `result8`, `wave` · ผลวิเคราะห์ละเอียดเฉพาะ Android |
| `bloodglucose` | ✅ | ✅ | `value` (mmol/L), `risk_level` |
| `rrinterval` | ✅ | ✅ | `rr_arry` (ms) · ย้อนหลังสูงสุด 3 วัน |
| `heartwarning` | ✅ | ✅ | plugin เทียบชีพจรที่ sync ได้กับค่าเตือนในนาฬิกา → `value`, `warning_type` (`high`/`low`), `heart_high`, `heart_low` |
| `fatigue` | — | — | นาฬิกาไม่เก็บย้อนหลัง → ใช้การวัดสด (5) |
| `stress` | ✅ | ✅ | `value` (0–100), `status` (`good` < 40, `middle` < 70, `bad`) จากข้อมูลราย 5 นาที เฉพาะรุ่นที่รองรับ (`capabilities()['stress']`) |

---

## 5. วัดสด

```dart
HBandSdk.measurementUpdates.listen((u) => print('${u.type} ${u.progress}% ${u.value}'));  // u.samples = จุด ECG

final m = await HBandSdk.startMeasurement(HBandMeasureType.bloodPressure);
if (m.success) {
  final req = m.toInsertRequest(imei);    // พร้อม POST (source: online) · ptt → type ecg, mode ptt
}
await HBandSdk.stopMeasurement();          // ยกเลิก
```

มีฟังก์ชันแยกต่อค่าด้วย เช่น `HBandSdk.measureHeartRate()`, `measureHrv()`, `measureCheckup()` (= `startMeasurement(type)`)

ก่อนแสดงปุ่ม เช็กว่านาฬิการุ่นนี้วัดได้ไหม: `(await HBandSdk.getCapabilities()).canMeasure(HBandMeasureType.gsr)`

| `HBandMeasureType` | ผลที่ได้ (`m.record`) | POST ได้ |
|---|---|---|
| `heartRate` | `value` bpm | ✅ `heartrate` |
| `bloodPressure` | `sbp`, `dbp` | ✅ `bloodpressure` |
| `spo2` | `value` % | ✅ `spo2` |
| `bodyTemp` | `value` °C, `base_temp` | ✅ `bodytemp` |
| `fatigue` | `value`, `status` | ✅ `fatigue` |
| `bloodGlucose` | `value` mmol/L, `risk_level` | ✅ `bloodglucose` |
| `stress` | `value`, `status` | ✅ `stress` |
| `ecg` / `ptt` | ECG record (`ptt` นาฬิกาต้องอยู่โหมด PTT) | ✅ `ecg` |
| `hrv` | `value` (วัดต่อเนื่อง ~30 วินาที) | ✅ `hrv` |
| `respiratory` | `value` ครั้ง/นาที | ✅ `respiratory` |
| `bloodComponent` | `uric_acid`, `total_cholesterol`, `triglyceride`, `hdl`, `ldl` | — ยังไม่มี API |
| `bodyComposition` | `bmi`, `body_fat_rate`, `muscle_mass`, `bone_mass`, `basal_metabolic_rate` … (นิ้วแตะขั้วไฟฟ้า, `u.leadOff`) | — ยังไม่มี API |
| `gsr` | `emotion_level`, `skin_moisture`, `depression_risk`, `sns_activation`, `cortisol` | — ยังไม่มี API |
| `met` | `value` | — ยังไม่มี API |
| `emotion` | `value` | — ยังไม่มี API |
| `checkup` | ทุกค่าที่นาฬิกาวัดได้ในครั้งเดียว | ✅ แยกตาม type ใน `m.records` |

POST ทุกอย่างที่ส่งได้: `for (final req in m.toInsertRequests(imei)) ...` (type ที่ยังไม่มี API จะได้ list ว่าง)

---

## 6. SOS โทรออก (รายชื่อ SOS + Bluetooth โทร)

เวลากด SOS **นาฬิกาโทรหารายชื่อ SOS เองผ่านโทรศัพท์ทาง Bluetooth โทร (Classic / HFP)** — BLE อย่างเดียวไม่พอ
ถ้าไม่มีรายชื่อ SOS หรือยังไม่ได้จับคู่ Bluetooth โทร (สถานะ `broadcasting`) กด SOS แล้วอาจไม่มีอะไรเกิดขึ้นเลย

```dart
final support = await HBandSdk.getContactSupport();      // support.contacts, support.sosContacts
var list = await HBandSdk.getContacts();                  // [HBandContact(id, name, phone, sos)]
list = await HBandSdk.addContact(name: 'แม่', phone: '0812345678', sos: true);
list = await HBandSdk.setSosContact(list.first, true);    // เปิด / ปิด SOS
list = await HBandSdk.deleteContact(list.first);

await HBandSdk.getSosCallTimes();                         // times, min, max
await HBandSdk.setSosCallTimes(2);                        // โทรวนกี่รอบ (ค่าเริ่มต้น 1 — plugin ตั้งให้ครั้งแรกที่ pair นาฬิกาเรือนนั้น)

final bt = await HBandSdk.readCallBluetoothState();       // supported, status, canPlaceSosCalls
if (bt.supported && !bt.isConnected) {
  await HBandSdk.connectCallBluetooth();   // Android : เปิดหน้าจับคู่ · iOS (bt.manualPairing) : ให้ผู้ใช้จับคู่ใน Settings → Bluetooth
}
HBandSdk.callBluetoothState.listen(print);
```

**แนะนำ** : ฟอร์มผูก / แก้ไขนาฬิกามีเบอร์ฉุกเฉิน → บันทึกสำเร็จแล้ว
1. เทียบกับ `getContacts()` (ตัวเลขล้วน, `+66` = `0`) เบอร์ที่มีแล้วใช้ตัวเดิม / ไม่มีก็ `addContact(sos: true)`
2. รายชื่อ SOS อื่นที่ไม่อยู่ในฟอร์ม → `setSosContact(false)` (ไม่ลบ)
3. ถ้า Bluetooth โทรยังไม่ต่อ → ถามผู้ใช้แล้ว `connectCallBluetooth()`

---

## 7. SOS / ล้ม — Guard เบื้องหลัง

Guard เปิดเองหลัง `connect` / `initialize` · ตรวจ 3 ช่องทางพร้อมกัน (กันซ้ำ 10 วิ) :
frame `8F 08 03 …` (`EMERGENCY_ALARM` — VIGOR fw 00.16.02 ส่งทั้งกด SOS และล้ม แยกไม่ได้),
SOS push ของ SDK (`SOS_PRESSED`), fall push ของ SDK (`FALL_DETECTED`, เฉพาะ firmware ที่รองรับ)

```dart
HBandSdk.events.where((e) => e.isEmergency).listen(showAlert);   // HBandEvent(id, type, timestamp, detail, data)
HBandSdk.emergencyNotificationTaps.listen(openAlert);            // ผู้ใช้กดแจ้งเตือน
final launchId = await HBandSdk.getLaunchEmergencyEventId();     // เปิดแอปจากแจ้งเตือน
await HBandSdk.acknowledgeEvent(id);
await HBandSdk.getEvents(); await HBandSdk.clearEvents();

await HBandSdk.startGuard(); await HBandSdk.stopGuard(); await HBandSdk.isGuardRunning();

await HBandSdk.setWebhookConfig(url: 'https://…/hook', enabled: true);   // native POST เหตุการณ์ (เฉพาะ SOS)
await HBandSdk.testWebhook();
await HBandSdk.simulateEmergency(label: 'test');                         // ทดสอบ UI
```

`HBandEventType` : `EMERGENCY_ALARM`, `SOS_PRESSED`, `FALL_DETECTED`, `SEDENTARY_REMIND`, `STATUS`

### 7.1 แนะนำ : รับ SOS ในแอป

plugin **ไม่มีหน้าจอ SOS** ให้ — มีแค่แจ้งเตือน + events แอปต้องทำเอง :

```dart
// หลัง login + HBandSdk.initialize()
HBandSdk.events.where((e) => e.isEmergency).listen((e) => handle(e, open: true));
HBandSdk.emergencyNotificationTaps.listen(openById);           // แตะแจ้งเตือน
final launchId = await HBandSdk.getLaunchEmergencyEventId();   // เปิดแอปจากแจ้งเตือน
await processPending(openId: launchId);                        // + เรียกซ้ำตอน AppLifecycleState.resumed

Future<void> processPending({String? openId}) async {
  final recent = (await HBandSdk.getEvents())
      .where((e) => e.isEmergency && DateTime.now().difference(e.timestamp) < const Duration(minutes: 30));
  for (final e in recent) { await handle(e, open: false); }   // ส่งที่ยังไม่ได้ส่ง
  // เปิดหน้าจอของ openId หรือเหตุการณ์ล่าสุดที่ยัง !acknowledged
}

Future<void> handle(HBandEvent e, {required bool open}) async {
  if (open) openAlertScreen(e);
  if (alreadySent(e.id) || e.isSimulated) return;   // เก็บ id ที่ส่งแล้วไว้ (SharedPreferences) · เหตุการณ์จำลองห้ามแจ้งครอบครัว
  final imei = await HBandSdk.getImei();
  // แจ้ง backend ของแอป เช่น POST /api/sosapi/reciveLogSos
  //   {watch_imeicode: imei, sos_type: e.type == FALL_DETECTED ? "fall-detect" : "sos", lat, lng, ...}
}
// ปุ่ม "ฉันปลอดภัย" → HBandSdk.acknowledgeEvent(e.id) แล้วปิดหน้าจอ
```

- events ถูกส่งซ้ำเมื่อสถานะ webhook เปลี่ยน → **กันซ้ำด้วย `id`**
- `EMERGENCY_ALARM` = SOS หรือล้ม (firmware ที่ทดสอบแยกไม่ได้) → แสดงว่า "SOS / ล้ม"
- เหตุการณ์ที่เกิดตอนแอปไม่ได้เปิด guard เก็บไว้ (สูงสุด 100) → ส่งตอนเปิด / กลับเข้าแอป
- **ข้อจำกัด** : Dart ทำงานเฉพาะตอนแอปมีชีวิต — Android ถ้าแอปถูกปัดทิ้งและจอไม่ล็อก แจ้งเตือนขึ้นแต่การแจ้ง backend รอจนผู้ใช้แตะแจ้งเตือน
  (จอล็อก : full-screen intent เปิดแอปให้) · ต้องการส่งทันทีแม้แอปปิด → ใช้ `setWebhookConfig` (native POST)

Android : แนะนำให้ผู้ใช้ยกเว้น battery optimization (`requestIgnoreBatteryOptimizations()`) — ROM บางยี่ห้อ (Xiaomi, realme…) ฆ่า service

---

## 8. อื่น ๆ

| ฟังก์ชัน | |
|---|---|
| `readBattery()` | `percent`, `level`, `isPercent` |
| `getCapabilities()` | ฟีเจอร์ที่นาฬิการองรับ (`raw` map) |
| `getRawFrames(lines:)` | frame BLE ล่าสุด (Android · debug) |
| `isIgnoringBatteryOptimizations()` / `requestIgnoreBatteryOptimizations()` | Android |

---

## 9. Error

ทุกคำสั่งที่คุยกับนาฬิกา throw `PlatformException` เมื่อไม่สำเร็จ

| code | ความหมาย | ทำอย่างไร |
|---|---|---|
| `NOT_READY` | นาฬิกายังไม่เชื่อมต่อ | ต่อก่อน / รอ reconnect |
| `BUSY` | มีคำสั่งอื่นทำงานอยู่ | **SDK ทำงานได้ทีละคำสั่ง** — รอ sync / วัดเสร็จก่อน |
| `UNSUPPORTED` / `UNSUPPORTED_TYPE` | นาฬิการุ่นนี้ไม่รองรับ | ซ่อนฟีเจอร์ |
| `TIMEOUT` / `WRITE_FAILED` / `FAILED` | นาฬิกาไม่ตอบ / ปฏิเสธ | ลองใหม่ |
| `NOT_FOUND` | ไม่พบรายชื่อ | โหลด `getContacts()` ใหม่ |

---

## 10. Flow แนะนำ

```
เปิดแอป (login แล้ว) ── HBandSdk.initialize()

ผูกนาฬิกา
  requestPermissions → startScan → ผู้ใช้เลือก → connect(password: '0000')
  → imei = getImei() → ผูกกับ user ที่ backend (TB_Device, serial = imei)
  → (ยกเลิกฟอร์ม / ปัดแอปทิ้ง → forgetWatch())
  → ส่งเบอร์ฉุกเฉิน → รายชื่อ SOS (6) → ชวนจับคู่ Bluetooth โทร
  → syncHealthData → POST smartwatch_vp_insert (ทีละงาน ไม่ทำพร้อมกัน)

ใช้งาน
  เปิดหน้า / กด SYNC → ถ้ายังไม่ ready : รอ reconnect → (iOS) สแกนหา + connectById
                     → syncHealthData → POST → โหลดหน้าจอใหม่
  SOS / ล้ม → events → แจ้ง backend (reciveLogSos) + หน้าจอ SOS · เปิด / กลับเข้าแอป → processPending (7.1)
  แสดงผล → API ดึงค่าของ backend (smartwatch_cn_api / smartwatch_vp_api) ด้วย imei

ลบนาฬิกา ── forgetWatch() + ลบที่ backend
```

แอปตัวอย่างครบทุกฟีเจอร์ : `example/` ใน repo นี้

---

## 11. ข้อจำกัด / ยังไม่มี

- ยังไม่มี : ตั้งค่านาฬิกา (แจ้งเตือนชีพจร / อุณหภูมิ, ภาษา, ความถี่วัด), โหมดกีฬาสด, OTA / หน้าปัด
- `bloodglucose` ยังไม่ส่ง `calibration_open` / `calibration_value` · iOS : ECG ไม่มีผลวิเคราะห์ละเอียด, `hrv_type` ตายตัว
- แยก SOS กับล้มไม่ได้บน firmware ที่ทดสอบ (frame เดียวกัน)
- iOS : ผู้ใช้ปัดแอปทิ้ง → iOS หยุด Bluetooth เบื้องหลังจนกว่าจะเปิดแอปใหม่
- Android : Force stop ในตั้งค่าระบบ → guard หยุดจนกว่าจะเปิดแอปใหม่
- **ยังไม่ได้ยืนยันกับนาฬิกาจริง** : iOS `HBFrameSniffer` (frame SOS), iOS `deviceAddress` = MAC, หน่วย duration / distance ของ sport, PTT,
  SOS โทรออกหลังตั้งรายชื่อ + จับคู่ Bluetooth โทร

เอกสาร backend : `smartwatch_vp_app_guide.md` (บันทึก + ดึงค่าของตัวเอง), `smartwatch_vp_api_guide.md` (ภาพรวม + รูปแบบ response)
