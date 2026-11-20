/// Data models shared by the Android and iOS implementations.
library;

/// A watch found while scanning.
class HBandDevice {
  const HBandDevice({required this.deviceId, required this.name, required this.rssi});

  /// Android: the BLE MAC address. iOS: the SDK's `deviceAddress`.
  /// Treat it as an opaque id and pass it back to [HBandSdk.connect].
  final String deviceId;
  final String name;
  final int rssi;

  factory HBandDevice.fromMap(Map<dynamic, dynamic> map) => HBandDevice(
    deviceId: map['deviceId'] as String? ?? '',
    name: map['name'] as String? ?? 'Unknown',
    rssi: (map['rssi'] as num?)?.toInt() ?? -100,
  );

  @override
  bool operator ==(Object other) => other is HBandDevice && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// Connection lifecycle of the paired watch.
enum HBandConnectionStatus {
  disconnected,
  connecting,

  /// BLE link is up, the password / protocol sync is running.
  verifying,

  /// Password accepted and synced — the watch is usable.
  ready,
  passwordFailed,
  failed;

  static HBandConnectionStatus parse(String? value) => HBandConnectionStatus.values.firstWhere(
    (e) => e.name == value,
    orElse: () => HBandConnectionStatus.disconnected,
  );
}

class HBandConnectionState {
  const HBandConnectionState({
    required this.status,
    this.deviceId,
    this.name,
    this.message,
    this.guardRunning = false,
  });

  final HBandConnectionStatus status;
  final String? deviceId;
  final String? name;
  final String? message;
  final bool guardRunning;

  bool get isReady => status == HBandConnectionStatus.ready;

  bool get isBusy => status == HBandConnectionStatus.connecting || status == HBandConnectionStatus.verifying;

  static const initial = HBandConnectionState(status: HBandConnectionStatus.disconnected);

  factory HBandConnectionState.fromMap(Map<dynamic, dynamic> map) => HBandConnectionState(
    status: HBandConnectionStatus.parse(map['state'] as String?),
    deviceId: map['deviceId'] as String?,
    name: map['name'] as String?,
    message: map['message'] as String?,
    guardRunning: map['guardRunning'] as bool? ?? false,
  );
}

/// Outcome of [HBandSdk.connect].
class HBandConnectResult {
  const HBandConnectResult({required this.success, required this.status, this.message});

  final bool success;
  final HBandConnectionStatus status;
  final String? message;

  factory HBandConnectResult.fromMap(Map<dynamic, dynamic> map) => HBandConnectResult(
    success: map['success'] as bool? ?? false,
    status: HBandConnectionStatus.parse(map['state'] as String?),
    message: map['message'] as String?,
  );
}

/// The saved (paired) watch. Survives app restarts until [HBandSdk.forgetWatch].
class HBandSession {
  const HBandSession({
    required this.deviceId,
    required this.name,
    this.deviceNumber,
    this.firmware,
    this.firmwareTest,
    this.guardEnabled = true,
    this.callSosDetection = true,
  });

  final String deviceId;
  final String name;

  /// Device number reported by the watch (used as "SN" in webhook payloads).
  final int? deviceNumber;
  final String? firmware;
  final String? firmwareTest;
  final bool guardEnabled;

  /// Android: outgoing calls through the watch count as SOS ([HBandSdk.setCallSosDetection]).
  final bool callSosDetection;

  String get serial => (deviceNumber ?? 0) > 0 ? '$deviceNumber' : 'unknown';

  static HBandSession? fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return null;
    final number = (map['deviceNumber'] as num?)?.toInt();
    return HBandSession(
      deviceId: map['deviceId'] as String? ?? '',
      name: map['name'] as String? ?? '',
      deviceNumber: number != null && number > 0 ? number : null,
      firmware: _nonEmpty(map['firmware']),
      firmwareTest: _nonEmpty(map['firmwareTest']),
      guardEnabled: map['guardEnabled'] as bool? ?? true,
      callSosDetection: map['callSosDetection'] as bool? ?? true,
    );
  }
}

class HBandBattery {
  const HBandBattery({
    required this.isPercent,
    required this.percent,
    required this.level,
    required this.isLow,
    required this.charging,
  });

  /// When false the watch only reports bars ([level], 0-4).
  final bool isPercent;
  final int percent;
  final int level;
  final bool isLow;
  final bool charging;

  /// Best-effort 0-100 value.
  int get displayPercent => isPercent ? percent : (level.clamp(0, 4) * 25);

  static HBandBattery? fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return null;
    return HBandBattery(
      isPercent: map['isPercent'] as bool? ?? false,
      percent: (map['percent'] as num?)?.toInt() ?? 0,
      level: (map['level'] as num?)?.toInt() ?? 0,
      isLow: map['isLow'] as bool? ?? false,
      charging: map['charging'] as bool? ?? false,
    );
  }
}

/// Event types produced by the guard.
abstract final class HBandEventType {
  /// SOS press or fall — the tested firmware sends the same frame for both.
  static const emergencyAlarm = 'EMERGENCY_ALARM';
  static const sosPressed = 'SOS_PRESSED';
  static const fallDetected = 'FALL_DETECTED';
  static const sedentary = 'SEDENTARY_REMIND';

  /// Informational log line (connection restored, monitoring started, ...).
  static const status = 'STATUS';
}

/// One entry of the guard's event feed.
class HBandEvent {
  const HBandEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.detail,
    this.webhookStatus,
    this.acknowledged = true,
    this.data = const {},
  });

  final String id;
  final String type;
  final DateTime timestamp;
  final String detail;
  final String? webhookStatus;

  /// False for emergencies the user has not dismissed yet.
  final bool acknowledged;

  /// Extra payload (detection channel, raw frame, watch info, ...).
  final Map<String, dynamic> data;

  bool get isEmergency =>
      type == HBandEventType.emergencyAlarm ||
      type == HBandEventType.sosPressed ||
      type == HBandEventType.fallDetected;

  bool get isStatus => type == HBandEventType.status;

  bool get isSimulated => data['simulated'] == true;

  String? get detection => data['detection'] as String?;

  factory HBandEvent.fromMap(Map<dynamic, dynamic> map) => HBandEvent(
    id: map['id'] as String? ?? '',
    type: map['type'] as String? ?? HBandEventType.status,
    timestamp: DateTime.fromMillisecondsSinceEpoch((map['timestamp'] as num?)?.toInt() ?? 0),
    detail: map['detail'] as String? ?? '',
    webhookStatus: map['webhookStatus'] as String?,
    acknowledged: map['acknowledged'] as bool? ?? true,
    data: _deepCast(map['data']),
  );
}

class HBandWebhookConfig {
  const HBandWebhookConfig({required this.url, required this.enabled});

  final String url;
  final bool enabled;

  factory HBandWebhookConfig.fromMap(Map<dynamic, dynamic>? map) =>
      HBandWebhookConfig(url: map?['url'] as String? ?? '', enabled: map?['enabled'] as bool? ?? false);
}

class HBandWebhookResult {
  const HBandWebhookResult({required this.success, required this.httpCode, required this.message});

  final bool success;
  final int httpCode;
  final String message;

  factory HBandWebhookResult.fromMap(Map<dynamic, dynamic>? map) => HBandWebhookResult(
    success: map?['success'] as bool? ?? false,
    httpCode: (map?['httpCode'] as num?)?.toInt() ?? -1,
    message: map?['message'] as String? ?? '',
  );
}

class HBandPermissionStatus {
  const HBandPermissionStatus({required this.bluetooth, required this.notification, this.phoneState = true});

  final bool bluetooth;
  final bool notification;

  /// Android: READ_PHONE_STATE for call-based SOS detection. Always true while
  /// that detection is off (see [HBandSdk.setCallSosDetection]).
  final bool phoneState;

  bool get allGranted => bluetooth && notification;

  factory HBandPermissionStatus.fromMap(Map<dynamic, dynamic>? map) => HBandPermissionStatus(
    bluetooth: map?['bluetooth'] as bool? ?? false,
    notification: map?['notification'] as bool? ?? false,
    phoneState: map?['phoneState'] as bool? ?? true,
  );
}

/// Result of [HBandSdk.initialize].
class HBandInitResult {
  const HBandInitResult({required this.platform, this.session, required this.connection});

  final String platform;
  final HBandSession? session;
  final HBandConnectionState connection;

  factory HBandInitResult.fromMap(Map<dynamic, dynamic>? map) => HBandInitResult(
    platform: map?['platform'] as String? ?? '',
    session: HBandSession.fromMap(map?['session'] as Map?),
    connection: map?['connection'] is Map
        ? HBandConnectionState.fromMap(map!['connection'] as Map)
        : HBandConnectionState.initial,
  );
}

String? _nonEmpty(Object? value) {
  final s = value as String?;
  return s == null || s.isEmpty ? null : s;
}

Map<String, dynamic> _deepCast(Object? value) {
  if (value is! Map) return const {};
  return value.map((k, v) => MapEntry(k.toString(), _castValue(v)));
}

Object? _castValue(Object? v) {
  if (v is Map) return _deepCast(v);
  if (v is List) return v.map(_castValue).toList();
  return v;
}
