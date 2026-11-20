/// Watch ↔ phone call features: contacts / SOS contacts and the watch's
/// call Bluetooth (Bluetooth Classic / HFP).
///
/// When SOS is pressed the watch itself dials its SOS contacts **through the
/// phone over call Bluetooth** — so that link must be paired and connected.
library;

/// A contact stored on the watch.
class HBandContact {
  const HBandContact({required this.id, required this.name, required this.phone, required this.sos});

  /// Id assigned by the watch (use it for delete / SOS toggling).
  final int id;
  final String name;
  final String phone;

  /// True when the watch calls this contact on SOS.
  final bool sos;

  factory HBandContact.fromMap(Map<dynamic, dynamic> map) => HBandContact(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    phone: map['phone'] as String? ?? '',
    sos: map['sos'] as bool? ?? false,
  );

  @override
  String toString() => 'HBandContact($id, $name, $phone${sos ? ', SOS' : ''})';
}

/// What the watch supports for contacts.
class HBandContactSupport {
  const HBandContactSupport({required this.contacts, required this.sosContacts});

  final bool contacts;

  /// The watch can call contacts marked as SOS when its SOS button is pressed.
  final bool sosContacts;

  factory HBandContactSupport.fromMap(Map<dynamic, dynamic>? map) => HBandContactSupport(
    contacts: map?['contacts'] as bool? ?? false,
    sosContacts: map?['sosContacts'] as bool? ?? false,
  );
}

/// How many times the watch redials SOS contacts.
class HBandSosCallTimes {
  const HBandSosCallTimes({required this.times, this.min, this.max});

  final int times;

  /// Allowed range (only returned by a read).
  final int? min;
  final int? max;

  factory HBandSosCallTimes.fromMap(Map<dynamic, dynamic>? map) => HBandSosCallTimes(
    times: (map?['times'] as num?)?.toInt() ?? 0,
    min: (map?['min'] as num?)?.toInt(),
    max: (map?['max'] as num?)?.toInt(),
  );
}

enum HBandCallBtStatus {
  /// Not reported yet (watch not connected, or older firmware).
  unknown,
  disconnected,
  connected,

  /// Call Bluetooth is on and waiting to be paired with a phone.
  broadcasting,
}

/// The watch's call Bluetooth (Classic / HFP) link with the phone.
class HBandCallBluetoothState {
  const HBandCallBluetoothState({
    required this.supported,
    required this.status,
    this.btOpen,
    this.audioOpen,
    this.hasPairInfo,
    this.link,
    this.manualPairing = false,
  });

  /// The watch has call Bluetooth.
  final bool supported;
  final HBandCallBtStatus status;

  /// Call Bluetooth switched on on the watch.
  final bool? btOpen;
  final bool? audioOpen;
  final bool? hasPairInfo;

  /// Last result of a connect / disconnect request: connecting · connected · disconnected · timeout.
  final String? link;

  /// iOS: the app cannot pair Bluetooth Classic itself — the user pairs the
  /// watch in Settings → Bluetooth (after [HBandSdk.connectCallBluetooth] turns it on).
  final bool manualPairing;

  bool get isConnected => status == HBandCallBtStatus.connected;

  /// SOS calls from the watch need this link.
  bool get canPlaceSosCalls => supported && isConnected;

  factory HBandCallBluetoothState.fromMap(Map<dynamic, dynamic>? map) => HBandCallBluetoothState(
    supported: map?['supported'] as bool? ?? false,
    status: HBandCallBtStatus.values.firstWhere(
      (s) => s.name == map?['status'],
      orElse: () => HBandCallBtStatus.unknown,
    ),
    btOpen: map?['btOpen'] as bool?,
    audioOpen: map?['audioOpen'] as bool?,
    hasPairInfo: map?['hasPairInfo'] as bool?,
    link: map?['link'] as String?,
    manualPairing: map?['manualPairing'] as bool? ?? false,
  );

  @override
  String toString() => 'HBandCallBluetoothState(${status.name}, supported: $supported, link: $link)';
}
