# งานแก้ค่าการนอน (VIGOR) และการวัดอุณหภูมิ (นาฬิกา BT)

สถานะ ณ 2026-11-27 · SDK `releep_hband_sdk 0.0.1` · แอปที่ใช้ : `imt-releep-new`

เอกสารนี้มี 2 เรื่อง:

1. ค่าการนอนจาก VIGOR ไม่ตรงกับที่นาฬิกาแสดง
2. การวัดอุณหภูมิ fail ทันทีเมื่อนาฬิกาไม่ว่าง (แก้แล้วทั้ง Android / iOS ใน PR #1)

---

## 1. ค่าการนอนจาก VIGOR ไม่ตรงกับนาฬิกา

### อาการ

ค่าการนอนที่ส่งขึ้น backend (`POST api/smartwatch_vp_insert/sleep`) ไม่ตรงกับตัวเลขที่นาฬิกาแสดง
ทั้งเวลานอนรวม เวลาเข้านอน และเวลาตื่น

### สาเหตุ ก. ไม่ได้ต่อช่วงการนอนเข้าด้วยกัน (น่าจะเป็นสาเหตุหลัก)

นาฬิกาแบ่งการนอนคืนเดียวเป็นหลายช่วง แต่ละช่วงบอกว่าต้องต่อกับช่วงก่อนหน้าหรือถัดไป

| แพลตฟอร์ม | model | field ที่บอกให้ต่อ |
|---|---|---|
| iOS | `VPAccurateSleepModel` | `lastType`, `nextType` |
| Android | `SleepPrecisionData` | `getLaster()`, `getNext()` |

กฎจาก header ของ Veepoo (`VPAccurateSleepModel.h`):

> ถ้า `lastType == 1` ต้องต่อกับช่วงก่อนหน้า ถ้า `nextType == 1` ต้องต่อกับช่วงถัดไป
> เมื่อต่อแล้ว ให้แก้เวลาเข้านอน/เวลาตื่น และต่อกราฟการนอน ค่าอื่นทั้งหมดใช้ของ **ช่วงสุดท้าย**

ตอนนี้ SDK ส่งแต่ละช่วงขึ้นไปเป็นคนละ record:

- iOS : `ios/Classes/HealthSync.swift` → `querySleep(_:)`
- Android : `android/src/main/kotlin/com/releep/releep_hband_sdk/health/HealthSync.kt` → `onSleep(_:)`

### สาเหตุ ข. REM และเวลาตื่นคำนวณเอง แทนที่จะใช้ค่าจากนาฬิกา

SDK นับ `rem` / `awakeShort` เองจาก `sleep_line` (`preciseRemAwake`)
แต่นาฬิกาส่งค่าเหล่านี้มาให้อยู่แล้ว:

| ค่า | iOS | Android |
|---|---|---|
| REM (นาที) | `otherDuration` | `getOtherDuration()` |
| เวลาตื่น (นาที) | `getUpDuration` | `getGetUpDuration()` |

ถ้ารูปแบบกราฟไม่ตรงกับที่โค้ดคาด ค่าที่นับได้จะคลาดเคลื่อน

### แนวทางแก้ (รอยืนยัน)

1. สำหรับนาฬิกาที่ใช้การนอนแบบ precise ให้ต่อช่วงที่ติด flag `lastType` / `nextType` เข้าด้วยกันก่อน `bag.put(...)`
   - `startTime` ใช้ของช่วงแรก, `endTime` ใช้ของช่วงสุดท้าย
   - `sleep_line` ต่อกันตามลำดับ
   - ค่าอื่น (`allSleep`, `deepSleep`, `lightSleep`, คะแนนต่าง ๆ) ใช้ของช่วงสุดท้าย
2. `rem` = `otherDuration`, `awakeShort` = `getUpDuration` (เก็บ `preciseRemAwake` ไว้เป็น fallback เมื่อค่าเป็น 0)
3. แก้ให้ตรงกันทั้ง iOS และ Android

### ต้องตัดสินใจ / ข้อมูลที่ต้องใช้

- [ ] backend รับการนอนแบบไหน : คืนละ record เดียว หรือแยกตามช่วงได้
- [ ] log `HBand sleep records before upload: ...` ของคืนที่ค่าไม่ตรง
      (พิมพ์จาก `lib/services/hband_watch_service.dart` ใน debug mode)
- [ ] ตัวเลขที่นาฬิกาแสดงของคืนเดียวกัน (นอนรวม / หลับลึก / หลับตื้น / REM / ตื่น / เวลาเข้านอน-ตื่น)

---

## 2. การวัดอุณหภูมิ (นาฬิกา BT)

### สิ่งที่แก้แล้ว (PR #1 : `fix/temperature-busy-retry`)

แก้ทั้งสองแพลตฟอร์มให้ทำงานเหมือนกัน:

- Android : `android/src/main/kotlin/com/releep/releep_hband_sdk/health/HealthMeasure.kt`
- iOS : `ios/Classes/HealthMeasure.swift` (`startTemperature()`, `retryTemperatureAfterBusy()`)

พฤติกรรม:

- นาฬิกาตอบว่าไม่ว่าง (Android `deviceState` 1..7, iOS `enable == false`)
  → ลองใหม่สูงสุด 3 ครั้ง ครั้งละ 1.5 วินาที แทนการ fail ทันที ครบแล้วยังไม่ว่างจึง fail `"Watch is busy"`
- จำ `base_temp` จาก callback ก่อนหน้า ถ้า callback สุดท้าย (100%) ไม่ส่งมาก็ยังได้ค่า
  และส่ง `base_temp` ไปกับ progress update ด้วย
- ยกเลิกรอบ retry ที่ค้างอยู่ตอนจบการวัด (iOS ไม่สนใจ callback ที่มาช้าจากรอบก่อน retry)

### ขั้นต่อไป

1. ทดสอบในแอป `imt-releep-new` : สลับเป็น
   ```yaml
   releep_hband_sdk:
     path: ../EPITWORK/releep_hband_sdk_repo
   ```
   แล้ว `flutter clean && flutter pub get` (iOS : `cd ios && pod install`)
2. merge PR แล้ว publish เป็น `0.0.2` (แก้ `version` ใน `pubspec.yaml` และ `CHANGELOG.md`)
3. แอปเปลี่ยนเป็น `releep_hband_sdk: ^0.0.2`

### ต้องตัดสินใจ

- [ ] ทดสอบด้วย `path:` ก่อน หรือ publish `0.0.2` เลย
