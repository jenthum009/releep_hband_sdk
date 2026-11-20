import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:releep_hband_sdk/releep_hband_sdk.dart';

/// App-wide state on top of [HBandSdk]: session, connection, battery, feed.
class GuardController extends ChangeNotifier {
  GuardController();

  String platform = '';
  HBandSession? session;
  HBandConnectionState connection = HBandConnectionState.initial;
  HBandBattery? battery;
  bool guardRunning = false;
  HBandWebhookConfig webhook = const HBandWebhookConfig(url: '', enabled: false);
  List<HBandEvent> events = const [];
  bool initialized = false;

  final _emergencies = StreamController<HBandEvent>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];

  /// Emergencies that need the full-screen alert.
  Stream<HBandEvent> get emergencies => _emergencies.stream;

  bool get isPaired => session != null;
  bool get isAndroid => platform == 'android';

  Future<void> init() async {
    _subscriptions
      ..add(HBandSdk.connectionState.listen(_onConnection))
      ..add(HBandSdk.events.listen(_onEvent))
      ..add(HBandSdk.emergencyNotificationTaps.listen(_openEmergencyById));

    final result = await HBandSdk.initialize();
    platform = result.platform;
    session = result.session;
    connection = result.connection;
    webhook = await HBandSdk.getWebhookConfig();
    events = await HBandSdk.getEvents();
    guardRunning = await HBandSdk.isGuardRunning();
    initialized = true;
    notifyListeners();

    // Opened from an emergency notification, or an alert the user never dismissed.
    final launchId = await HBandSdk.getLaunchEmergencyEventId();
    if (launchId != null) {
      _openEmergencyById(launchId);
    } else {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
      for (final e in events) {
        if (e.isEmergency && !e.acknowledged && e.timestamp.isAfter(cutoff)) {
          _emergencies.add(e);
          break;
        }
      }
    }
    if (connection.isReady) unawaited(refreshBattery());
  }

  void _onConnection(HBandConnectionState state) {
    final becameReady = state.isReady && !connection.isReady;
    connection = state;
    guardRunning = state.guardRunning;
    notifyListeners();
    if (becameReady) {
      unawaited(refreshSession());
      unawaited(refreshBattery());
    }
  }

  void _onEvent(HBandEvent event) {
    final list = [...events];
    final index = list.indexWhere((e) => e.id == event.id);
    if (index >= 0) {
      list[index] = event; // webhook status update
    } else {
      list.insert(0, event);
      if (event.isEmergency && !event.acknowledged) _emergencies.add(event);
    }
    events = list.take(100).toList();
    notifyListeners();
  }

  void _openEmergencyById(String id) {
    final match = events.where((e) => e.id == id);
    if (match.isNotEmpty) _emergencies.add(match.first);
  }

  Future<void> refreshSession() async {
    session = await HBandSdk.getSession();
    guardRunning = await HBandSdk.isGuardRunning();
    notifyListeners();
  }

  Future<void> refreshBattery() async {
    battery = await HBandSdk.readBattery();
    notifyListeners();
  }

  Future<void> refreshAll() async {
    connection = await HBandSdk.getConnectionState();
    events = await HBandSdk.getEvents();
    await refreshSession();
    if (connection.isReady) await refreshBattery();
  }

  Future<HBandConnectResult> connect(HBandDevice device, String password) async {
    final result = await HBandSdk.connect(device, password: password);
    if (result.success) await refreshSession();
    return result;
  }

  /// Returns false when the phone-state permission was not granted.
  Future<bool> setCallSos(bool enabled) async {
    final status = await HBandSdk.setCallSosDetection(enabled);
    await refreshSession();
    return status.phoneState;
  }

  Future<void> setGuard(bool enabled) async {
    if (enabled) {
      await HBandSdk.startGuard();
    } else {
      await HBandSdk.stopGuard();
    }
    await refreshSession();
  }

  Future<void> acknowledge(HBandEvent event) async {
    await HBandSdk.acknowledgeEvent(event.id);
    events = [
      for (final e in events)
        if (e.id == event.id)
          HBandEvent(
            id: e.id,
            type: e.type,
            timestamp: e.timestamp,
            detail: e.detail,
            webhookStatus: e.webhookStatus,
            acknowledged: true,
            data: e.data,
          )
        else
          e,
    ];
    notifyListeners();
  }

  Future<void> clearEvents() async {
    await HBandSdk.clearEvents();
    events = const [];
    notifyListeners();
  }

  Future<void> saveWebhook({String? url, bool? enabled}) async {
    webhook = await HBandSdk.setWebhookConfig(url: url, enabled: enabled);
    notifyListeners();
  }

  Future<void> forget() async {
    await HBandSdk.forgetWatch();
    session = null;
    battery = null;
    connection = HBandConnectionState.initial;
    events = const [];
    guardRunning = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _emergencies.close();
    super.dispose();
  }
}
