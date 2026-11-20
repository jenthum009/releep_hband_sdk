## 0.0.1

* On-demand measurement: added `hrv`, `respiratory`, `bloodcomponent`, `bodycomposition`, `gsr`,
  `met`, `emotion`, `checkup` (Android + iOS), one `HBandSdk.measureXxx()` call per value,
  `HBandCapabilities.measurements` / `canMeasure`, `HBandMeasureResult.records` /
  `toInsertRequests`, `HBandMeasureUpdate.leadOff`.
* SOS call count defaults to 1: set once per paired watch after its first session (Android + iOS);
  a count changed later with `setSosCallTimes` is kept, forget + re-pair applies it again.
* `setEmergencyNotification(bool)` (Android + iOS): turns off the plugin's own "Emergency from
  watch" notification for apps that show their own SOS alert. Saved, kept across `forgetWatch`,
  on by default; detection, events, the saved feed and the webhook are unchanged.
* iOS: a watch whose link iOS already holds (connected for calls) no longer advertises; scans now
  also report it from the system. `startScan` takes optional `watchId` / `watchName` to find it
  when no saved session identifies it.
* iOS: the session id and `getImei()` are always the watch MAC (as on Android), never the
  CoreBluetooth UUID. A watch found through the system link is listed by its UUID until it is
  connected; its MAC is then read from the chip and saved.

## 0.0.1

* TODO: Describe initial release.
