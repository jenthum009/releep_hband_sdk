/// Health data read from the watch, shaped for the backend
/// `POST {HEALTH_API_URL}/api/smartwatch_vp_insert/{type}` API.
library;

/// Backend `{type}` names.
abstract final class HBandHealthType {
  static const heartRate = 'heartrate';
  static const spo2 = 'spo2';
  static const bloodPressure = 'bloodpressure';
  static const bodyTemp = 'bodytemp';
  static const respiratory = 'respiratory';
  static const hrv = 'hrv';
  static const fatigue = 'fatigue';
  static const stepCount = 'stepcount';
  static const calorie = 'calorie';
  static const battery = 'battery';
  static const sleep = 'sleep';
  static const sport = 'sport';
  static const ecg = 'ecg';
  static const bloodGlucose = 'bloodglucose';
  static const rrInterval = 'rrinterval';
  static const heartWarning = 'heartwarning';
  static const stress = 'stress';

  static const all = [
    heartRate, spo2, bloodPressure, bodyTemp, respiratory, hrv, fatigue, stepCount, //
    calorie, battery, sleep, sport, ecg, bloodGlucose, rrInterval, heartWarning, stress,
  ];

  /// Max items per insert request (backend limits).
  static int maxPerRequest(String type) => type == ecg ? 20 : 50000;
}

/// Types that can be measured on demand with [HBandSdk.startMeasurement].
/// Check [HBandCapabilities.measurements] for what the connected watch supports.
abstract final class HBandMeasureType {
  static const heartRate = HBandHealthType.heartRate;
  static const bloodPressure = HBandHealthType.bloodPressure;
  static const spo2 = HBandHealthType.spo2;
  static const bodyTemp = HBandHealthType.bodyTemp;
  static const fatigue = HBandHealthType.fatigue;
  static const bloodGlucose = HBandHealthType.bloodGlucose;
  static const ecg = HBandHealthType.ecg;
  static const stress = HBandHealthType.stress;
  static const hrv = HBandHealthType.hrv;
  static const respiratory = HBandHealthType.respiratory;

  /// PTT signal (watch must be in PTT mode). Result is an `ecg` record with `mode: "ptt"`.
  static const ptt = 'ptt';

  // The types below have no backend `{type}` yet — the record is for display only.

  /// `uric_acid` (µmol/L), `total_cholesterol`, `triglyceride`, `hdl`, `ldl` (mmol/L).
  static const bloodComponent = 'bloodcomponent';

  /// Fingers on the electrodes (see [HBandMeasureUpdate.leadOff]). `bmi`, `body_fat_rate` %,
  /// `fat_mass` kg, `lean_body_mass` kg, `muscle_rate` %, `muscle_mass` kg, `subcutaneous_fat` %,
  /// `body_water` %, `water_content` kg, `skeletal_muscle_rate` %, `bone_mass` kg,
  /// `protein_rate` %, `protein_mass` kg, `basal_metabolic_rate` kcal.
  static const bodyComposition = 'bodycomposition';

  /// Skin conductance: `emotion_level` -10..10, `skin_moisture` 1..99, `depression_risk`
  /// low/medium/high, `sns_activation` 1..99, `cortisol` µg/L.
  static const gsr = 'gsr';

  /// `value` = MET.
  static const met = 'met';

  /// `value` = emotion level.
  static const emotion = 'emotion';

  /// Several values in one run. The record holds every measured value (flat keys plus
  /// nested `bloodcomponent` / `bodycomposition` / `gsr` maps); [HBandMeasureResult.records]
  /// holds ready-to-POST records per backend type.
  static const checkup = 'checkup';

  static const all = [
    heartRate, bloodPressure, spo2, bodyTemp, fatigue, bloodGlucose, ecg, ptt, stress, hrv, respiratory, //
    bloodComponent, bodyComposition, gsr, met, emotion, checkup,
  ];
}

/// One request body for `api/smartwatch_vp_insert/{type}`.
class HBandInsertRequest {
  const HBandInsertRequest({required this.type, required this.body});

  final String type;

  /// `{"imei": "...", "data": [...]}` — send as JSON.
  final Map<String, dynamic> body;

  /// Path relative to `{HEALTH_API_URL}`.
  String get path => 'api/smartwatch_vp_insert/$type';

  int get count => (body['data'] as List).length;
}

/// Splits [records] of one type into request bodies within the backend limit.
List<HBandInsertRequest> buildInsertRequests(String imei, String type, List<Map<String, dynamic>> records) {
  final max = HBandHealthType.maxPerRequest(type);
  return [
    for (var i = 0; i < records.length; i += max)
      HBandInsertRequest(
        type: type,
        body: {'imei': imei, 'data': records.sublist(i, i + max > records.length ? records.length : i + max)},
      ),
  ];
}

/// Result of [HBandSdk.syncHealthData].
class HBandHealthSyncResult {
  const HBandHealthSyncResult({
    required this.success,
    required this.cancelled,
    required this.records,
    required this.errors,
    required this.skipped,
    required this.duration,
  });

  /// False when any step failed / timed out (the other steps still ran).
  final bool success;
  final bool cancelled;

  /// Records per backend type, each already in the `data[]` item shape.
  final Map<String, List<Map<String, dynamic>>> records;

  /// Failed steps → reason (e.g. `{"sport": "timeout"}`).
  final Map<String, String> errors;

  /// Steps skipped because the watch does not support them.
  final List<String> skipped;
  final Duration duration;

  int get totalCount => records.values.fold(0, (sum, list) => sum + list.length);

  Map<String, int> get counts => records.map((k, v) => MapEntry(k, v.length));

  /// Ready-to-POST bodies for every non-empty type.
  List<HBandInsertRequest> toInsertRequests(String imei) => [
    for (final entry in records.entries)
      if (entry.value.isNotEmpty) ...buildInsertRequests(imei, entry.key, entry.value),
  ];

  factory HBandHealthSyncResult.fromMap(Map<dynamic, dynamic>? map) {
    final raw = map?['records'] as Map? ?? const {};
    return HBandHealthSyncResult(
      success: map?['success'] as bool? ?? false,
      cancelled: map?['cancelled'] as bool? ?? false,
      records: {
        for (final e in raw.entries)
          e.key.toString(): [for (final r in (e.value as List? ?? const [])) _castMap(r)],
      },
      errors: {for (final e in (map?['errors'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
      skipped: [for (final s in (map?['skipped'] as List? ?? const [])) '$s'],
      duration: Duration(milliseconds: (map?['durationMs'] as num?)?.toInt() ?? 0),
    );
  }
}

/// Result of [HBandSdk.startMeasurement].
class HBandMeasureResult {
  const HBandMeasureResult({
    required this.success,
    required this.type,
    this.record,
    this.records = const {},
    this.message,
  });

  final bool success;

  /// Measured type (`ptt` measurements produce `ecg`).
  final String type;

  /// The result, `time: now`. For backend types it is one `data[]` item (`source: online`
  /// where the backend has it); for the others it is for display.
  final Map<String, dynamic>? record;

  /// [HBandMeasureType.checkup] only: backend type → `data[]` item for each value measured.
  final Map<String, Map<String, dynamic>> records;
  final String? message;

  /// Whether [type] can be POSTed to `api/smartwatch_vp_insert/{type}`.
  bool get hasBackendType => HBandHealthType.all.contains(type);

  /// Request for [record]; null when it failed or [type] has no backend type.
  HBandInsertRequest? toInsertRequest(String imei) {
    final r = record;
    if (!success || r == null || !hasBackendType) return null;
    return HBandInsertRequest(
      type: type,
      body: {
        'imei': imei,
        'data': [r],
      },
    );
  }

  /// Every request to POST: [toInsertRequest], or one per backend type for a checkup.
  List<HBandInsertRequest> toInsertRequests(String imei) {
    if (!success) return const [];
    if (records.isNotEmpty) {
      return [
        for (final e in records.entries) ...buildInsertRequests(imei, e.key, [e.value]),
      ];
    }
    final single = toInsertRequest(imei);
    return single == null ? const [] : [single];
  }

  factory HBandMeasureResult.fromMap(Map<dynamic, dynamic>? map) => HBandMeasureResult(
    success: map?['success'] as bool? ?? false,
    type: map?['type'] as String? ?? '',
    record: map?['record'] is Map ? _castMap(map!['record']) : null,
    records: {
      for (final e in (map?['records'] as Map? ?? const {}).entries) '${e.key}': _castMap(e.value),
    },
    message: map?['message'] as String?,
  );
}

/// Progress of a running sync.
class HBandSyncProgress {
  const HBandSyncProgress({required this.stage, required this.progress, this.stageProgress});

  /// battery · steps · daily · sleep · temperature · spo2 · hrv · database · rrinterval · sport · ecg · heartwarning
  final String stage;

  /// Overall 0..1.
  final double progress;
  final double? stageProgress;

  factory HBandSyncProgress.fromMap(Map<dynamic, dynamic> map) => HBandSyncProgress(
    stage: map['stage'] as String? ?? '',
    progress: (map['progress'] as num?)?.toDouble() ?? 0,
    stageProgress: (map['stageProgress'] as num?)?.toDouble(),
  );
}

/// Live update of a running measurement.
class HBandMeasureUpdate {
  const HBandMeasureUpdate({required this.type, this.progress, this.value, this.samples, this.leadOff});

  final String type;

  /// 0..100 when known.
  final int? progress;

  /// Current reading (number, or "120/80" for blood pressure).
  final Object? value;

  /// ECG / PTT waveform chunk.
  final List<int>? samples;

  /// Body composition: true while the fingers are off the electrodes.
  final bool? leadOff;

  factory HBandMeasureUpdate.fromMap(Map<dynamic, dynamic> map) => HBandMeasureUpdate(
    type: map['type'] as String? ?? '',
    progress: (map['progress'] as num?)?.toInt(),
    value: map['value'],
    samples: (map['samples'] as List?)?.map((e) => (e as num).toInt()).toList(),
    leadOff: map['leadOff'] as bool?,
  );
}

/// What the connected watch supports (keys differ slightly per platform).
class HBandCapabilities {
  const HBandCapabilities(this.raw);

  final Map<String, dynamic> raw;

  bool supports(String key) => raw[key] == true;

  int get watchDays => (raw['watchDays'] as num?)?.toInt() ?? 0;

  /// [HBandMeasureType]s the watch can measure on demand.
  List<String> get measurements => [for (final t in (raw['measurements'] as List? ?? const [])) '$t'];

  bool canMeasure(String type) => measurements.contains(type);

  factory HBandCapabilities.fromMap(Map<dynamic, dynamic>? map) =>
      HBandCapabilities(map == null ? const {} : _castMap(map));
}

Map<String, dynamic> _castMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((k, v) => MapEntry(k.toString(), _castValue(v)));
}

Object? _castValue(Object? v) {
  if (v is Map) return _castMap(v);
  if (v is List) return v.map(_castValue).toList();
  return v;
}
